# frozen_string_literal: true

# Summarizes auto-adoption eval logs into counts (docs/plans/auto-adoption-tests.md §1 and §5).
#
#   ruby script/adoption_eval/summarize.rb ~/adoption-eval/logs/*.jsonl [--csv]
#
# Each log is one headless session named <arm>-<task>-<run>.jsonl: Claude Code stream-json
# (`claude -p --output-format stream-json --verbose`) or, best effort, the Cursor CLI stream.
# Prints one row per arm (task "all") and per arm and task. Read-only: it writes nothing, makes no
# network call and needs no Rails. It never prints prompts, tool inputs or results: only counts.
# Plain Ruby (stdlib only).
require "json"
require "optparse"

module AdoptionEval
  GRAPH_MEM = /\Amcp__graph_mem__/
  EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze
  WRITE_TOOLS = %w[graph_write graph_edit graph_delete].freeze
  # graph_mem tool names a ToolSearch query may mention ("search" and "summarize" alone are too common).
  GM_WORDS = /graph[_-]mem|\b(get_context|set_context|get_entities|traverse_graph|find_shortest_path|rank_observations|graph_write|graph_edit|graph_delete)\b/
  COLUMNS = %w[arm task n adopted ctx_before_edit median_first_gm_turn mean_gm_calls skill_used toolsearch_gm
               persist_attempts hook_fired median_turns median_tokens median_cost].freeze

  # One session's metrics, from its JSONL events in order.
  class Session
    attr_reader :arm, :task, :malformed

    # @param arm [String]
    # @param task [String]
    # @param lines [Enumerable<String>] the log's lines
    def initialize(arm, task, lines)
      @arm = arm
      @task = task
      @malformed = 0
      @calls = [] # [message index, tool name] in stream order, graph_mem and edits only
      @messages = []
      @denied = {}
      @flags = Hash.new(false)
      lines.each { |line| read(line) }
    end

    # @return [Hash{Symbol=>Object}] the per-session metrics (nil for n/a)
    def metrics
      edit_at = @calls.index { |(_, kind)| kind == :edit }
      before = edit_at ? @calls.first(edit_at) : @calls
      first_gm = @calls.find { |(_, kind)| kind.is_a?(String) }
      { adopted: before.any? { |(_, kind)| kind.is_a?(String) },
        ctx_before_edit: before.any? { |(_, kind)| kind == "get_context" },
        first_gm_turn: first_gm && (first_gm[0] + 1),
        gm_calls: @calls.count { |(_, kind)| kind.is_a?(String) },
        skill_used: @flags[:skill], toolsearch_gm: @flags[:toolsearch], hook_fired: @flags[:hook],
        persist_attempts: @denied.values.count { |name| WRITE_TOOLS.include?(name.sub(GRAPH_MEM, "")) },
        turns: @result&.dig("num_turns"), tokens: tokens, cost: @result&.dig("total_cost_usd") }
    end

    private

    def read(line)
      return if line.strip.empty?

      event = JSON.parse(line)
      raise JSON::ParserError, "not an object" unless event.is_a?(Hash)

      dispatch(event)
    rescue JSON::ParserError
      @malformed += 1
    end

    def dispatch(event)
      case event["type"]
      when "assistant" then assistant(event)
      when "tool_call" then cursor_call(event) if event["subtype"] == "started"
      when "result" then result(event)
      end
      hook(event) if event["type"] == "system" && event["subtype"].to_s.start_with?("hook")
      deny(event["tool_use_id"], event["tool_name"]) if [ event["type"], event["subtype"] ].include?("permission_denied")
    end

    # Claude Code splits one message across events with the same message id.
    def message_index(id)
      @messages << (id || "event-#{@messages.size}") unless id && @messages.include?(id)
      @messages.index(id) || (@messages.size - 1)
    end

    def assistant(event)
      message = event["message"] || {}
      index = message_index(message["id"])
      Array(message["content"]).each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_use"

        tool(index, block["name"].to_s, block["input"].is_a?(Hash) ? block["input"] : {})
      end
    end

    def tool(index, name, input)
      if name.match?(GRAPH_MEM) then @calls << [ index, name.sub(GRAPH_MEM, "") ]
      elsif EDIT_TOOLS.include?(name) then @calls << [ index, :edit ]
      elsif name == "Skill" then @flags[:skill] ||= input.values.grep(String).any? { |value| value.include?("graph-mem-mcp-toolset") }
      elsif name == "ToolSearch" then @flags[:toolsearch] ||= input.values.grep(String).any? { |value| value.match?(GM_WORDS) }
      end
    end

    # Cursor CLI: tool_call.<kind>ToolCall, an MCP call's name under args; matched by name only.
    def cursor_call(event)
      kind, call = (event["tool_call"] || {}).first
      return unless kind

      names = [ call.is_a?(Hash) && call.dig("args", "name"), call.is_a?(Hash) && call.dig("args", "toolName") ].grep(String)
      index = @messages.size.zero? ? message_index(nil) : @messages.size - 1
      if (gm = names.find { |name| name.include?("graph_mem") })
        @calls << [ index, gm.split(/__|[-:]/).last ]
      elsif kind.match?(/edit|write/i)
        @calls << [ index, :edit ]
      end
    end

    def hook(event)
      return unless "#{event['hook_event']} #{event['hook_name']}".include?("SessionStart")

      @flags[:hook] ||= %w[hook_name command stdout output].any? { |key| event[key].to_s.include?("graph_mem") }
    end

    def deny(id, name)
      @denied[id || "denial-#{@denied.size}"] = name.to_s if name
    end

    def result(event)
      @result = event
      Array(event["permission_denials"]).each { |denial| deny(denial["tool_use_id"], denial["tool_name"]) if denial.is_a?(Hash) }
    end

    def tokens
      usage = @result&.dig("usage")
      return unless usage.is_a?(Hash)

      %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].sum { |key| usage[key].to_i }
    end
  end

  # The table: one row per arm (task "all"), then one per arm and task.
  class Report
    # @param sessions [Array<Session>]
    def initialize(sessions)
      @sessions = sessions
    end

    # @return [Array<Array<String>>] the rows, COLUMNS first
    def rows(csv: false)
      groups = @sessions.group_by(&:arm).sort.flat_map do |arm, list|
        [ [ arm, "all", list ] ] + list.group_by(&:task).sort.map { |task, part| [ arm, task, part ] }
      end
      [ COLUMNS ] + groups.map { |arm, task, list| row(arm, task, list.map(&:metrics), csv) }
    end

    private

    def row(arm, task, metrics, csv)
      n = metrics.size
      rate = ->(key) { count = metrics.count { |m| m[key] }; csv ? count.to_s : "#{count}/#{n}" }
      [ arm, task, n.to_s, rate.(:adopted), rate.(:ctx_before_edit), median(metrics.map { |m| m[:first_gm_turn] }),
        format("%.1f", metrics.sum { |m| m[:gm_calls] }.fdiv(n)), rate.(:skill_used), rate.(:toolsearch_gm),
        metrics.sum { |m| m[:persist_attempts] }.to_s, rate.(:hook_fired), median(metrics.map { |m| m[:turns] }),
        median(metrics.map { |m| m[:tokens] }), median(metrics.map { |m| m[:cost] }, "%.4f") ]
    end

    def median(values, pattern = "%g")
      sorted = values.compact.sort
      return "n/a" if sorted.empty?

      middle = sorted.size / 2
      format(pattern, sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]).fdiv(2))
    end
  end

  NAME = /\A(?<arm>.+)-(?<task>[^-]+)-(?<run>[^-]+)\.jsonl\z/

  # @param paths [Array<String>] the log files
  # @param csv [Boolean]
  # @return [String] the table and a counts-only footer
  def self.summarize(paths, csv: false)
    named = paths.map { |path| [ path, File.basename(path).match(NAME) ] }
    sessions = named.select(&:last).map { |path, match| Session.new(match[:arm], match[:task], File.foreach(path)) }
    rows = Report.new(sessions).rows(csv: csv)
    table = csv ? rows.map { |row| row.join(",") } : align(rows)
    footer = "#{sessions.size} sessions, #{sessions.sum(&:malformed)} malformed lines skipped, " \
             "#{named.count { |_, match| match.nil? }} files skipped (not <arm>-<task>-<run>.jsonl)"
    (table + [ (csv ? "# " : "") + footer ]).join("\n")
  end

  def self.align(rows)
    widths = rows.transpose.map { |column| column.map(&:length).max }
    rows.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
  end
end

if $PROGRAM_NAME == __FILE__
  csv = false
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby script/adoption_eval/summarize.rb LOG.jsonl... [--csv]"
    opts.on("--csv", "Comma-separated output") { csv = true }
  end
  parser.parse!(ARGV)
  abort(parser.to_s) if ARGV.empty?
  puts AdoptionEval.summarize(ARGV, csv: csv)
end
