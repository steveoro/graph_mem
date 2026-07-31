# frozen_string_literal: true

# Central policy for compaction valve coverage and heavy read tools.
class ToolMutationPolicy
    COMPACTION_VALVE_TOOLS = %w[
    bulk_update create_entity create_observation create_relation
    delete_entity delete_observation delete_relation update_entity update_observation
    merge_entities search_entities search_subgraph suggest_merges summarize
    detect_contradictions apply_maintenance_review dismiss_maintenance_review
  ].freeze

  class << self
    def compaction_valve?(tool_name)
      COMPACTION_VALVE_TOOLS.include?(tool_name.to_s)
    end
  end
end
