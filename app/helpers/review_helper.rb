# frozen_string_literal: true

# Labels for the Review page (UI-5b).
module ReviewHelper
  # Kinds whose targets can be edited before applying (the detail pane shows entity pickers).
  EDITABLE_KINDS = %w[entity_merge relationship_proposal orphan_parent reparent_entity move_observation].freeze

  # @param row [MaintenanceReportRow]
  # @return [String] a one-line description of the suggestion
  def review_row_title(row)
    payload = row.effective_payload
    case row.kind
    when "entity_merge" then "#{payload.dig('entity_a', 'name') || "##{payload.dig('entity_a', 'entity_id')}"} ↔ #{payload.dig('entity_b', 'name') || "##{payload.dig('entity_b', 'entity_id')}"}"
    when "relationship_proposal" then "#{payload['from_name'] || "##{payload['from_entity_id']}"} #{payload['relation_type']} #{payload['to_name'] || "##{payload['to_entity_id']}"}"
    when "contradiction" then "#{payload['entity_name_1']} ↔ #{payload['entity_name_2']}: ##{payload['observation_id_1']} vs ##{payload['observation_id_2']}"
    when "stale_memory" then "#{payload['entity_name'] || "##{payload['entity_id']}"}: #{Array(payload['observation_ids']).size} stale observation(s)"
    else payload["entity_name"].presence || payload["reason"].presence || row.group_key.to_s
    end.to_s.truncate(140)
  end
end
