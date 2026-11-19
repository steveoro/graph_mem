# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# script/adoption_eval/report.rb over synthetic run directories: the decision rules of
# docs/plans/auto-adoption-tests.md §3, each decided or naming what it still needs. Sessions are
# hand-built stream-json events with synth-* values.
RSpec.describe "script/adoption_eval/report.rb" do
  let(:script) { File.expand_path("../../script/adoption_eval/report.rb", __dir__) }

  around do |example|
    Dir.mktmpdir("adoption-report") do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, "logs"))
      example.run
    end
  end

  def tool(name, input = {}) = { type: "assistant", message: { id: "m-#{name}", content: [ { type: "tool_use", name: name, input: input } ] } }

  # One session log: adopted (a graph_mem call before the edit) or not, with turns and tokens.
  # `capped` is a result that stopped at --max-turns (subtype error_max_turns).
  def session(arm, task, run, adopted:, turns: 6, tokens: 1000, write_search: false, capped: false)
    events = []
    events << tool("ToolSearch", { query: "select:mcp__graph_mem__graph_write" }) if write_search
    events << tool("mcp__graph_mem__get_context") if adopted
    events << tool("Edit", { file_path: "synth-app/CHANGELOG.md" })
    result = { type: "result", num_turns: turns, usage: { input_tokens: tokens }, total_cost_usd: 0.1 }
    result[:subtype] = "error_max_turns" if capped
    events << result
    File.write(File.join(@dir, "logs", "#{arm}-#{task}-#{run}.jsonl"), events.map(&:to_json).join("\n"))
  end

  # n sessions of arm on task, the first `adopted` of them adopting.
  def sessions(arm, task, n:, adopted:, **options)
    (1..n).each { |run| session(arm, task, run, adopted: run <= adopted, **options) }
  end

  def report
    out, err, status = Bundler.with_unbundled_env { Open3.capture3("ruby", script, @dir) }
    expect([ err, status.exitstatus ]).to eq([ "", 0 ])
    expect(out.strip).to eq(File.join(@dir, "report.md"))
    File.read(out.strip)
  end

  def write_run(**facts) = File.write(File.join(@dir, "run.json"), JSON.generate({ id: "20261119T104500Z", suite: "screen" }.merge(facts)))

  it "writes the header, the baseline, the table and summary.csv, counts only" do
    write_run(graph_mem_version: "1.91.0", claude_version: "synth-cc", model: "synth-model", clones: { "goggles_admin2-eval" => "abcdef123456" },
              baseline: [ { path: "~/.claude/rules/*", exists: false, mentions_graph_mem: false } ],
              settings: [ { key: "mcp_skills_enabled", before: false, after: true } ])
    sessions("I", "T1", n: 2, adopted: 1)
    text = report

    expect(text).to start_with("# Adoption eval 20261119T104500Z\n")
    expect(text).to include("- **graph_mem:** 1.91.0", "goggles_admin2-eval @ abcdef1", "mcp_skills_enabled false → true (restored)",
                            "| `~/.claude/rules/*` | no | no |", "I    all   2  1/2", "## Not run on this server")
    expect(File.read(File.join(@dir, "summary.csv"))).to start_with("arm,task,n,adopted,")
    expect(text).not_to include("synth-app", "CHANGELOG")
  end

  it "Q-L on T1 screening: a 40-point drop keeps a lever, ties keep the free skill and drop the hook" do
    write_run
    sessions("ALL", "T1", n: 5, adopted: 5)
    sessions("ALL-R", "T1", n: 5, adopted: 1)
    sessions("ALL-S", "T1", n: 5, adopted: 5)
    sessions("ALL-H", "T1", n: 5, adopted: 4)
    text = report

    expect(text).to include("**R** (the user rule): dropping it: +80 points (T1 screening, bar 40 points) → keep it on by default.")
    expect(text).to include("**S** (the skill trigger): dropping it: 0 points (T1 screening, bar 40 points) → a tie: keep it (free at runtime).")
    expect(text).to include("**H** (the SessionStart hook): dropping it: +20 points (T1 screening, bar 40 points) → a tie: drop it from the default install (it costs a hook).")
    expect(text).to include("ALL adopts in 100% of sessions (≥ 85%): stop adding levers.")
  end

  it "Q-L on the full round: 15 points pooled count only when at least 2 tasks agree" do
    write_run
    %w[T1 T2 T3].each { |task| sessions("ALL", task, n: 5, adopted: 4) }
    { "T1" => 3, "T2" => 3, "T3" => 4 }.each { |task, adopted| sessions("ALL-R", task, n: 5, adopted: adopted) }
    { "T1" => 1, "T2" => 4, "T3" => 4 }.each { |task, adopted| sessions("ALL-H", task, n: 5, adopted: adopted) }

    expect(report).to include("**R** (the user rule): dropping it: +13 points (2 of 3 tasks the same way) → a tie",
                              "**H** (the SessionStart hook): dropping it: +20 points (1 of 3 tasks the same way) → a tie",
                              "**S** (the skill trigger): needs ALL and ALL-S, or S and I.")
  end

  it "Q-L's draft efficiency rule: a tie that costs turns or tokens beyond the bar, on at least 2 tasks" do
    write_run
    %w[T1 T2 T3].each do |task|
      sessions("ALL", task, n: 5, adopted: 5, turns: 20, tokens: 1000)
      sessions("ALL-R", task, n: 5, adopted: 5, turns: task == "T3" ? 20 : 25, tokens: 1000)
      sessions("ALL-H", task, n: 5, adopted: 5, turns: 21, tokens: 1050)
      sessions("I", task, n: 5, adopted: 5, turns: 24, tokens: 1200)
      sessions("I0", task, n: 5, adopted: 4, turns: 26, tokens: 1300)
    end
    text = report

    expect(text).to include("**R** (the user rule): dropping it: 0 points (0 of 3 tasks the same way) → a tie: drop it",
                            "  - Efficiency (draft rule): dropping it: turns +25% (2 of 3 tasks), tokens +0% (0 of 3 tasks) (bar 15%) → costs turns beyond the bar: the draft rule would keep it.",
                            "  - Efficiency (draft rule): dropping it: turns +5% (0 of 3 tasks), tokens +5% (0 of 3 tasks) (bar 15%) → no cost beyond the bar.",
                            "- **All levers together** (ALL vs I): adoption 0 points (0 of 3 tasks the same way).",
                            "  - Efficiency (draft rule): without them (I): turns +20% (3 of 3 tasks), tokens +20% (3 of 3 tasks) (bar 15%) → costs turns and tokens beyond the bar: the draft rule would keep it.",
                            "- **The 1.89.0 skill copy** (I vs I0): adoption +20 points (3 of 3 tasks the same way).",
                            "  - Efficiency (draft rule): without it (I0): turns +8% (0 of 3 tasks), tokens +8% (0 of 3 tasks) (bar 15%) → no cost beyond the bar.")
    expect(text).not_to include("The current skill copy")
  end

  it "Q-L's draft efficiency rule on T1 screening needs 25%, and 25% fires it" do
    write_run
    sessions("ALL", "T1", n: 5, adopted: 5, turns: 20)
    sessions("I", "T1", n: 5, adopted: 5, turns: 24)

    expect(report).to include("without them (I): turns +20%, tokens +0% (bar 25%, T1 screening) → no cost beyond the bar.")

    sessions("I", "T1", n: 5, adopted: 5, turns: 25)
    expect(report).to include("without them (I): turns +25%, tokens +0% (bar 25%, T1 screening) → costs turns beyond the bar: the draft rule would keep it.")
  end

  it "marks an efficiency difference as a lower bound when a session hit the turn cap" do
    write_run(max_turns: 25)
    sessions("ALL", "T1", n: 5, adopted: 5, turns: 21)
    sessions("I", "T1", n: 5, adopted: 5, turns: 25, capped: true)

    text = report
    expect(text).to include("- **Max turns:** 25")
    expect(text).to include("without them (I): turns +19%, tokens +0% (bar 25%, T1 screening, lower bound: I hit the turn cap in 5/5) → no cost beyond the bar.")
  end

  it "prints the draft efficiency line only on an adoption tie" do
    write_run
    sessions("ALL", "T1", n: 5, adopted: 5, turns: 20)
    sessions("ALL-R", "T1", n: 5, adopted: 0, turns: 30)

    text = report
    expect(text).to include("**R** (the user rule): dropping it: +100 points (T1 screening, bar 40 points) → keep it on by default.")
    expect(text).not_to include("Efficiency (draft rule): dropping it")
  end

  it "compares the current skill copy when S and I0 were both run" do
    write_run
    %w[T1 T2 T3].each do |task|
      sessions("S", task, n: 5, adopted: 5, turns: 20, tokens: 1000)
      sessions("I0", task, n: 5, adopted: 5, turns: 24, tokens: 1000)
    end

    expect(report).to include("- **The current skill copy** (S vs I0): adoption 0 points (0 of 3 tasks the same way).",
                              "  - Efficiency (draft rule): without it (I0): turns +20% (3 of 3 tasks), tokens +0% (0 of 3 tasks) (bar 15%) → costs turns beyond the bar: the draft rule would keep it.")
    expect(report).not_to include("The 1.89.0 skill copy")
  end

  it "warns when I0 still loads a project skill copy or a CLAUDE.md that mentions graph_mem" do
    write_run(baseline: [
                { "path" => "<projects-dir>/.claude/skills/graph-mem-mcp-toolset", "exists" => true, "mentions_graph_mem" => true },
                { "path" => "<projects-dir>/CLAUDE.md", "exists" => true, "mentions_graph_mem" => false },
                { "path" => "~/.claude/CLAUDE.md", "exists" => true, "mentions_graph_mem" => true }
              ])
    sessions("I", "T1", n: 1, adopted: 1)
    sessions("I0", "T1", n: 1, adopted: 1)

    text = report
    expect(text).to include("| `<projects-dir>/CLAUDE.md` | yes | no |")
    expect(text).to include("Caveat: I0 still loads `<projects-dir>/.claude/skills/graph-mem-mcp-toolset` and `~/.claude/CLAUDE.md`, so it is not the instructions alone.")
    expect(text).not_to include("loads `<projects-dir>/CLAUDE.md`")
  end

  it "Q1 needs N=10 per task, and then weighs adoption against tokens" do
    write_run
    sessions("ALL", "T1", n: 5, adopted: 2)
    sessions("ALL+A", "T1", n: 5, adopted: 5, tokens: 1100)
    expect(report).to include("not decided: needs N=10 per task (suite q1)")

    %w[T1 T2].each do |task|
      sessions("ALL", task, n: 10, adopted: 5)
      sessions("ALL+A", task, n: 10, adopted: 8, tokens: 1100)
    end
    expect(report).to include("ALL+A over ALL: +30 points (2 of 2 tasks the same way); median tokens 110% of ALL → (b) and (c) hold")
  end

  it "Q2 serves a readonly variant when RO-full tries to write in at least 40% of sessions" do
    write_run
    (1..5).each { |run| session("RO-full", "T4", run, adopted: true, write_search: run <= 2, turns: 8) }
    sessions("RO-lite", "T4", n: 5, adopted: 5, turns: 7)

    expect(report).to include("RO-full: a failed write attempt in 40% of sessions; median turns 8 vs 7 for RO-lite → serve a readonly variant")
  end

  it "Q4 picks the lead from K1 and K2, with the caveats the CLI may need, and the IDE calibration" do
    write_run
    sessions("K0", "T1", n: 5, adopted: 1)
    sessions("K1", "T1", n: 5, adopted: 1)
    sessions("K2", "T1", n: 5, adopted: 4)
    File.write(File.join(@dir, "cursor-hooks.csv"), "arm,task,run,fired\n" + (1..5).map { |run| "K2,T1,#{run},0" }.join("\n"))
    File.write(File.join(@dir, "cursor-ide.csv"), "arm,task,run,first_gm,gm_before_edit,gm_calls,hook_fired\n" \
                                                  "K0,T1,1,n,n,0,n\nK0,T1,2,n,n,0,n\nK2,T1,1,y,y,2,y\nK2,T1,2,y,y,1,y\n")

    expect(report).to include("K0 20%, K1 20%, K2 80% (hook fired in 0 K2 runs) → lead with the hook.",
                              "Caveat: the CLI never ran the user hook, so K2 doesn't measure the hook; K1 equals K0, so the CLI may ignore User Rules.",
                              "IDE calibration on T1: K0: IDE 0%, CLI 20%; K2: IDE 100%, CLI 80% → use the IDE numbers.")

    File.write(File.join(@dir, "cursor-ide.csv"), "arm,task,run,first_gm,gm_before_edit,gm_calls,hook_fired
" \
                                                  "K0,T1,1,n,n,0,n\nK0,T1,2,n,n,0,n\nK0,T1,3,n,n,0,n\nK0,T1,4,n,n,0,n\nK0,T1,5,y,y,1,n\n" \
                                                  "K2,T1,1,y,y,2,y\nK2,T1,2,y,y,1,y\nK2,T1,3,y,y,1,y\nK2,T1,4,y,y,1,y\nK2,T1,5,n,n,0,y\n")
    expect(report).to include("IDE calibration on T1: K0: IDE 20%, CLI 20%; K2: IDE 80%, CLI 80% → the CLI numbers count.")
  end

  it "Q3 proposes a write mode after a slow or mistaken install, and every decision names what it needs" do
    write_run
    File.write(File.join(@dir, "q3.csv"), "host,minutes,mistakes\nclaude,4.5,0\ncursor,12.0,1\n")
    text = report

    expect(text).to include("claude 4.5 min, 0 mistakes; cursor 12.0 min, 1 mistakes → add a write mode")
    expect(text).to include("No session logs in this run.", "Needs ALL and ALL+A (suite q1, N=10 per task).",
                            "Needs RO-full and RO-lite (suite q2).", "Needs K1 and K2 (suite cursor).")
  end

  it "is stdlib only" do
    source = File.readlines(script).grep_v(/^\s*#/).join

    expect(source.scan(/^require(?:_relative)? "([^"]+)"/).flatten).to contain_exactly("json", "summarize")
  end
end
