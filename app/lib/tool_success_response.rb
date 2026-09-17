# frozen_string_literal: true

# Adds GraphMem workflow guidance to successful MCP tool results.
class ToolSuccessResponse
  CONTEXT_EXEMPT_TOOLS = %w[get_context set_context clear_context get_version].freeze
  DEFAULT_HINTS = {
    "search" => "Call `get_entities` with selected ids when full detail is needed.",
    "get_entities" => "Call `traverse_graph` when neighboring entities or edges are needed.",
    "traverse_graph" => "Call `get_entities` to inspect relevant entity details.",
    "find_shortest_path" => "Call `get_entities` with ids from the returned path.",
    "summarize" => "Use the returned source ids with `get_entities` to verify important claims.",
    "rank_observations" => "Use `graph_write` to append facts or `graph_edit` to correct one.",
    "graph_write" => "Call `get_entities` to verify persisted graph changes.",
    "graph_edit" => "Call `get_entities` to verify edited graph records.",
    "graph_delete" => "Call `search` or `get_entities` to verify the resulting graph.",
    "get_current_time" => "Use this timestamp for observation validity or provenance when needed.",
    "scan_project" => "Call `scan_project_status` with the returned scan id.",
    "scan_project_status" => "Continue the scan workflow or inspect its maintenance review items.",
    "suggest_merges" => "Inspect candidates, then use `graph_delete` with a merge_entities operation.",
    "list_maintenance_review" => "Use `apply_maintenance_review` or `dismiss_maintenance_review` on a reviewed item.",
    "get_maintenance_reports" => "Inspect actionable rows with `list_maintenance_review` when applicable.",
    "dream_state_status" => "Resume, pause, or inspect maintenance reports as needed.",
    "detect_contradictions" => "Review candidates before correcting facts with `graph_edit`.",
    "apply_maintenance_review" => "Call `get_entities` or `traverse_graph` to verify the applied change.",
    "dismiss_maintenance_review" => "Call `list_maintenance_review` to continue reviewing the queue.",
    "get_graph_stats" => "Use `search` or maintenance reports to investigate unexpected counts."
  }.freeze

  # Enhances one successful result and returns MCP body plus response metadata.
  #
  # @param tool_name [String] protocol tool name
  # @param result [Object] raw tool result
  # @param context [GraphMemContext] current client's context store
  # @return [Array(Hash, Hash)] enhanced result and FastMCP `_meta`
  def self.call(tool_name:, result:, context:)
    payload = result.is_a?(Hash) ? result.dup : { result: result }
    context_active = context.active?

    payload[:version] ||= GraphMem::VERSION.to_s
    payload[:next_move] ||= next_move_for(tool_name, payload)
    if !context_active && !tool_name.in?(CONTEXT_EXEMPT_TOOLS)
      payload[:context] ||= {
        status: "none",
        next_move: "Call `search` for a Project, then `set_context` with its entity id."
      }
    end

    metadata = {
      graphMemVersion: GraphMem::VERSION.to_s,
      contextStatus: context_active ? "active" : "none"
    }
    [ payload, metadata ]
  end

  # Resolves a status-aware or default next-step hint.
  #
  # @param tool_name [String]
  # @param payload [Hash]
  # @return [String, nil]
  def self.next_move_for(tool_name, payload)
    case tool_name
    when "get_context"
      if payload[:status] == "no_context"
        "Call `search` for a Project, then `set_context` with its entity id."
      else
        "Call `search` or `get_entities` to recall project knowledge."
      end
    when "set_context"
      payload[:status] == "context_cleared" ?
        "Call `search` globally or `set_context` again to rescope." :
        "Call `search` to recall knowledge in the active project."
    else
      DEFAULT_HINTS[tool_name]
    end
  end

  private_class_method :next_move_for
end
