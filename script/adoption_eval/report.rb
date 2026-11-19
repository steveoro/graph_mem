# frozen_string_literal: true

# Writes report.md and summary.csv for one run of script/adoption_eval/run_eval.sh: the run's facts
# (run.json), the summarize table over its logs, and the decision rules of
# docs/plans/auto-adoption-tests.md §3 applied to whatever arms the run has. Counts only: the report
# never quotes a prompt, a tool input or a result, so it is safe to share.
#
#   ruby script/adoption_eval/report.rb ~/adoption-eval/runs/<run-id>
#
# Plain Ruby (stdlib only), read-only except for the two files it writes into the run directory.
require "json"
require_relative "summarize"

module AdoptionEval
  # One run directory's report.
  class RunReport
    LEVERS = { "R" => "the user rule", "S" => "the skill trigger", "H" => "the SessionStart hook" }.freeze
    # Still loaded in I0, which removes only the user-level skill copy. Sessions run in <projects-dir>.
    I0_LOADS = [ [ "<projects-dir>/.claude/skills/graph-mem-mcp-toolset", "exists" ],
                 [ "<projects-dir>/CLAUDE.md", "mentions_graph_mem" ],
                 [ "~/.claude/CLAUDE.md", "mentions_graph_mem" ] ].freeze
    # Draft efficiency rule (tests doc §3 Q-L, not yet adopted): extra median turns or tokens, in %,
    # that make a lever worth keeping when adoption ties; T1 screening needs the larger bar.
    EFFICIENCY_BAR = 15
    EFFICIENCY_SCREEN_BAR = 25

    # @param dir [String] a run directory holding run.json and logs/
    def initialize(dir)
      @dir = dir
      @run = File.exist?(path("run.json")) ? JSON.parse(File.read(path("run.json"))) : {}
      @logs = Dir[path("logs/*.jsonl")]
      @sessions = @logs.filter_map { |log| Session.from_file(log) }
    end

    # Writes report.md and summary.csv into the run directory.
    #
    # @return [String] the report's path
    def write
      File.write(path("summary.csv"), "#{AdoptionEval.summarize(@logs, csv: true)}\n") if @logs.any?
      File.write(path("report.md"), markdown)
      path("report.md")
    end

    # @return [String] the report
    def markdown
      [ header, baseline, results, decisions, not_run ].compact.join("\n")
    end

    private

    def path(name) = File.join(@dir, name)

    def header
      facts = { "Suite" => @run["suite"], "Arms" => Array(@run["arms"]).join(", "), "Tasks" => Array(@run["tasks"]).join(", "),
                "Runs per arm and task" => @run["n"], "Max turns" => @run["max_turns"], "graph_mem" => @run["graph_mem_version"],
                "Claude Code" => @run["claude_version"], "Model" => @run["model"], "Cursor CLI" => @run["cursor_version"],
                "Auth" => @run["auth"], "Clones" => @run["clones"]&.map { |name, sha| "#{name} @ #{sha.to_s[0, 7]}" }&.join(", "),
                "Settings" => settings, "Started" => @run["started_at"], "Finished" => @run["finished_at"] }
      lines = facts.reject { |_, value| value.nil? || value.to_s.empty? }.map { |key, value| "- **#{key}:** #{value}" }
      "# Adoption eval #{@run['id'] || File.basename(@dir)}\n\n#{lines.join("\n")}\n"
    end

    def settings
      changes = Array(@run["settings"])
      return "unchanged" if changes.empty?

      changes.map { |change| "#{change['key']} #{change['before']} → #{change['after']} (restored)" }.join("; ")
    end

    def baseline
      rows = Array(@run["baseline"])
      return if rows.empty?

      table = rows.map { |row| "| `#{row['path']}` | #{row['exists'] ? 'yes' : 'no'} | #{row['mentions_graph_mem'] ? 'yes' : 'no'} |" }
      "## Baseline state (before the run)\n\n| Path | Exists | Mentions graph_mem |\n|---|---|---|\n#{table.join("\n")}\n"
    end

    def results
      return "## Results\n\nNo session logs in this run.\n" if @logs.empty?

      "## Results\n\n```text\n#{AdoptionEval.summarize(@logs)}\n```\n"
    end

    def decisions
      [ "## Decisions (docs/plans/auto-adoption-tests.md §3)\n", lever_decisions, q1, q2, q4, q3 ].join("\n")
    end

    def not_run
      "## Not run on this server\n\nB0 on the 1.89.0 instructions and ALL−I need a 1.89.0 server: compare with the 1.89.0 logs.\n"
    end

    # --- rates ---------------------------------------------------------------------------------

    def sessions_for(arm, task = nil) = @sessions.select { |s| s.arm == arm && (task.nil? || s.task == task) }

    def rate(arm, task = nil)
      list = sessions_for(arm, task)
      list.empty? ? nil : list.count { |s| s.metrics[:adopted] }.fdiv(list.size) * 100
    end

    def tasks_of(*arms) = arms.map { |arm| sessions_for(arm).map(&:task).uniq }.reduce(:&).sort

    def points(value) = "#{value.round}%"

    def median(values)
      sorted = values.compact.sort
      return if sorted.empty?

      sorted.size.odd? ? sorted[sorted.size / 2] : (sorted[(sorted.size / 2) - 1] + sorted[sorted.size / 2]).fdiv(2)
    end

    # Pooled difference a − b and whether it is real: ≥ bar points and the same direction on ≥ 2 tasks
    # (screening on T1 alone needs ≥ 40 points).
    def compare(arm_a, arm_b, bar)
      tasks = tasks_of(arm_a, arm_b)
      return unless tasks.any?

      delta = rate(arm_a) - rate(arm_b)
      same = tasks.count { |task| (rate(arm_a, task) - rate(arm_b, task)).positive? == delta.positive? && rate(arm_a, task) != rate(arm_b, task) }
      screening = tasks == [ "T1" ]
      real = screening ? delta.abs >= 40 : delta.abs >= bar && same >= 2
      { delta: delta, real: real, screening: screening, tasks: tasks, same: same }
    end

    def describe(cmp)
      scope = cmp[:screening] ? "T1 screening, bar 40 points" : "#{cmp[:same]} of #{cmp[:tasks].size} tasks the same way"
      "#{cmp[:delta].positive? ? '+' : ''}#{cmp[:delta].round} points (#{scope})"
    end

    # --- decisions -----------------------------------------------------------------------------

    def lever_decisions
      lines = LEVERS.map do |lever, label|
        drop = compare("ALL", "ALL-#{lever}", 15)
        alone = compare(lever, "I", 20)
        next "- **#{lever}** (#{label}): needs ALL and ALL-#{lever}, or #{lever} and I." unless drop || alone

        kept = (drop && drop[:real] && drop[:delta].positive?) || (alone && alone[:real] && alone[:delta].positive?)
        found = [ (drop && "dropping it: #{describe(drop)}"), (alone && "over I: #{describe(alone)}") ].compact.join("; ")
        verdict = if kept then "keep it on by default"
        elsif lever == "S" then "a tie: keep it (free at runtime)"
        else "a tie: drop it from the default install (it costs a #{lever == 'R' ? 'file' : 'hook'})"
        end
        draft = kept ? "" : efficiency_line("ALL", "ALL-#{lever}", "dropping it")
        "- **#{lever}** (#{label}): #{found} → #{verdict}.#{draft}"
      end
      all = rate("ALL")
      stop = all && all >= 85 ? "\n- ALL adopts in #{points(all)} of sessions (≥ 85%): stop adding levers." : ""
      "### Q-L: which levers stay on by default\n\n#{lines.join("\n")}#{stop}\n#{group_lines}"
    end

    # The levers together (I vs ALL), the 1.89.0 skill copy (I vs I0) and, when S was run, the current copy (S vs I0).
    # The draft-rule line is only on an adoption tie, same as the lever lines.
    def group_lines
      groups = [ [ "All levers together", "ALL", "I", "without them (I)" ],
                 [ "The 1.89.0 skill copy", "I", "I0", "without it (I0)" ],
                 [ "The current skill copy", "S", "I0", "without it (I0)" ] ]
      saw_i0 = false
      lines = groups.filter_map do |label, with, without, missing|
        cmp = compare(with, without, 20)
        next unless cmp

        saw_i0 = true if without == "I0"
        draft = cmp[:real] ? "" : efficiency_line(with, without, missing)
        "- **#{label}** (#{with} vs #{without}): adoption #{describe(cmp)}.#{draft}"
      end
      return "" if lines.empty?

      "\n#{lines.join("\n")}#{i0_caveat if saw_i0}\n"
    end

    # I0 is the instructions alone only when none of these baseline rows is yes.
    def i0_caveat
      hits = I0_LOADS.filter_map do |path, key|
        row = Array(@run["baseline"]).find { |item| item["path"] == path }
        "`#{path}`" if row&.[](key)
      end
      return "" if hits.empty?

      list = hits.size == 1 ? hits[0] : "#{hits[0..-2].join(', ')} and #{hits[-1]}"
      "\n  - Caveat: I0 still loads #{list}, so it is not the instructions alone."
    end

    # A draft-rule line: how much costlier `other` is than `base` in median turns and tokens.
    # Printed on adoption ties (a decided lever already has its verdict) and phrased as what the draft rule would do.
    def efficiency_line(base, other, what)
      eff = efficiency(base, other)
      return "" unless eff

      worse = eff[:found].select { |found| found[:real] }
      verdict = if worse.any?
        "costs #{worse.map { |found| found[:metric] }.join(' and ')} beyond the bar: the draft rule would keep it"
      else
        "no cost beyond the bar"
      end
      "\n  - Efficiency (draft rule): #{what}: #{describe_efficiency(eff)} → #{verdict}."
    end

    # Extra median turns or tokens of `other` over `base`, in %, pooled or on one task.
    def extra(base, other, metric, task = nil)
      a = median(sessions_for(base, task).map { |s| s.metrics[metric] })
      b = median(sessions_for(other, task).map { |s| s.metrics[metric] })
      a && b && a.positive? ? (b.fdiv(a) - 1) * 100 : nil
    end

    def efficiency(base, other)
      tasks = tasks_of(base, other)
      return if tasks.empty?

      screening = tasks == [ "T1" ]
      bar = screening ? EFFICIENCY_SCREEN_BAR : EFFICIENCY_BAR
      found = %i[turns tokens].filter_map do |metric|
        pooled = extra(base, other, metric) or next
        agree = tasks.count { |task| (value = extra(base, other, metric, task)) && value >= bar }
        { metric: metric, pooled: pooled, agree: agree, real: pooled >= bar && (screening || agree >= 2) }
      end
      return if found.empty?

      base_capped = capped_notes(base)
      other_capped = capped_notes(other)
      { found: found, bar: bar, screening: screening, tasks: tasks,
        capped: base_capped + other_capped, bound: efficiency_bound(base_capped, other_capped) }
    end

    # A capped median is held down at the cap. Only the compared arm: the extra is too low (a lower
    # bound). Only the base: the extra is too high (an upper bound). Both: the direction is unknown.
    def efficiency_bound(base_capped, other_capped)
      return "inexact" if base_capped.any? && other_capped.any?
      return "lower bound" if other_capped.any?
      return "upper bound" if base_capped.any?

      nil
    end

    # Sessions whose result subtype is error_max_turns: their turns (and tokens) stopped at the cap.
    def capped_notes(*arms)
      arms.filter_map do |arm|
        list = sessions_for(arm)
        count = list.count { |session| session.metrics[:capped] }
        "#{arm} hit the turn cap in #{count}/#{list.size}" if count.positive?
      end
    end

    def describe_efficiency(eff)
      parts = eff[:found].map do |found|
        count = eff[:screening] ? "" : " (#{found[:agree]} of #{eff[:tasks].size} tasks)"
        "#{found[:metric]} #{format('%+d', found[:pooled].round)}%#{count}"
      end
      scope = eff[:screening] ? ", T1 screening" : ""
      bound = eff[:bound] ? ", #{eff[:bound]}: #{eff[:capped].join('; ')}" : ""
      "#{parts.join(', ')} (bar #{eff[:bar]}%#{scope}#{bound})"
    end

    def q1
      cmp = compare("ALL+A", "ALL", 15)
      return "### Q1: per-tool alwaysLoad\n\nNeeds ALL and ALL+A (suite q1, N=10 per task).\n" unless cmp

      tokens = [ "ALL+A", "ALL" ].map { |arm| median(sessions_for(arm).map { |s| s.metrics[:tokens] }) }
      ratio = tokens.all? ? tokens[0].fdiv(tokens[1]) * 100 : nil
      enough = cmp[:tasks].all? { |task| [ "ALL", "ALL+A" ].all? { |arm| sessions_for(arm, task).size >= 10 } }
      met = cmp[:real] && cmp[:delta] >= 15 && ratio && ratio <= 115
      verdict = if !enough then "not decided: needs N=10 per task (suite q1)"
      elsif met then "(b) and (c) hold; (a) needs the 1.89.0 B0 logs before proposing the per-tool _meta"
      else "keep alwaysLoad a documented user-side option"
      end
      "### Q1: per-tool alwaysLoad\n\n- ALL+A over ALL: #{describe(cmp)}; median tokens #{ratio ? "#{ratio.round}% of ALL" : 'n/a'} → #{verdict}.\n"
    end

    def q2
      full = sessions_for("RO-full")
      lite = sessions_for("RO-lite")
      return "### Q2: a readonly skill variant\n\nNeeds RO-full and RO-lite (suite q2).\n" if full.empty? || lite.empty?

      failed = full.count { |s| s.metrics[:write_search] || s.metrics[:persist_attempts].positive? }.fdiv(full.size) * 100
      turns = [ full, lite ].map { |list| median(list.map { |s| s.metrics[:turns] }) }
      extra = turns.all? ? turns[0] - turns[1] : nil
      variant = failed >= 40 || (extra && extra >= 2)
      "### Q2: a readonly skill variant\n\n- RO-full: a failed write attempt in #{points(failed)} of sessions; median turns " \
        "#{turns[0] || 'n/a'} vs #{turns[1] || 'n/a'} for RO-lite → #{variant ? 'serve a readonly variant on /mcp/readonly' : 'serve the same skill on all three profiles'}.\n"
    end

    def q4
      return "### Q4: Cursor, hook or User Rule first\n\nNeeds K1 and K2 (suite cursor).\n" unless rate("K1") && rate("K2")

      hooks = csv("cursor-hooks.csv")
      fired = hooks.select { |row| row["arm"] == "K2" }.count { |row| row["fired"] == "1" }
      notes = []
      notes << "the CLI never ran the user hook, so K2 doesn't measure the hook" if hooks.any? && fired.zero?
      notes << "K1 equals K0, so the CLI may ignore User Rules" if rate("K0") && rate("K1") == rate("K0")
      delta = rate("K2") - rate("K1")
      verdict = if delta >= 30 then "lead with the hook"
      elsif delta <= -30 then "lead with the User Rule"
      else "list both, rule first"
      end
      text = "- K0 #{points(rate('K0') || 0)}, K1 #{points(rate('K1'))}, K2 #{points(rate('K2'))} (hook fired in #{fired} K2 runs) → #{verdict}."
      text += "\n- Caveat: #{notes.join('; ')}." if notes.any?
      "### Q4: Cursor, hook or User Rule first\n\n#{text}\n#{calibration}"
    end

    def calibration
      ide = csv("cursor-ide.csv")
      return "" if ide.empty?

      rows = %w[K0 K2].filter_map do |arm|
        runs = ide.select { |row| row["arm"] == arm }
        next if runs.empty? || rate(arm, "T1").nil?

        ide_rate = runs.count { |row| row["gm_before_edit"] == "y" }.fdiv(runs.size) * 100
        [ arm, ide_rate, rate(arm, "T1") ]
      end
      matches = rows.all? { |(_, ide_rate, cli)| (ide_rate - cli).abs < 20 }
      lines = rows.map { |(arm, ide_rate, cli)| "#{arm}: IDE #{points(ide_rate)}, CLI #{points(cli)}" }
      "- IDE calibration on T1: #{lines.join('; ')} → #{matches && rows.size == 2 ? 'the CLI numbers count' : 'use the IDE numbers'}.\n"
    end

    def q3
      rows = csv("q3.csv")
      return "### Q3: installer write mode\n\nNeeds the timed install test (suite q3).\n" if rows.empty?

      slow = rows.any? { |row| row["minutes"].to_f > 10 }
      mistakes = rows.sum { |row| row["mistakes"].to_i }
      lines = rows.map { |row| "#{row['host']} #{row['minutes']} min, #{row['mistakes']} mistakes" }
      "### Q3: installer write mode\n\n- #{lines.join('; ')} → " \
        "#{slow || mistakes.positive? ? 'add a write mode (--apply, merge with backup)' : 'stay print-only'}.\n"
    end

    # The runner's own CSVs: a header line, then plain comma-separated values (no quoting).
    def csv(name)
      return [] unless File.exist?(path(name))

      header, *rows = File.readlines(path(name), chomp: true).reject(&:empty?)
      keys = header.to_s.split(",")
      rows.map { |line| keys.zip(line.split(",", -1)).to_h }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort("Usage: ruby script/adoption_eval/report.rb RUN_DIR") unless ARGV.size == 1 && File.directory?(ARGV[0])
  puts AdoptionEval::RunReport.new(ARGV[0]).write
end
