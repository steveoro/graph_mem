# frozen_string_literal: true

# Which MCP tools pause a running dream-state compaction: the mutation tools and the
# maintenance tools that read or rewrite large parts of the graph. `search` is not one of them
# (see docs/dream_state.md, Cooperative pause).
class ToolMutationPolicy
  COMPACTION_VALVE_TOOLS = %w[
    graph_write graph_edit graph_delete
    suggest_merges summarize detect_contradictions
    apply_maintenance_review dismiss_maintenance_review
  ].freeze

  class << self
    # Whether a call to the tool pauses a running dream-state compaction first.
    #
    # @param tool_name [String, Symbol] a registered MCP tool name
    # @return [Boolean]
    def compaction_valve?(tool_name)
      COMPACTION_VALVE_TOOLS.include?(tool_name.to_s)
    end
  end
end
