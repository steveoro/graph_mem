# frozen_string_literal: true

# Labels for the Review page (UI-5b).
module ReviewHelper
  # Kinds whose targets can be edited before applying (the detail pane shows entity pickers).
  EDITABLE_KINDS = %w[entity_merge relationship_proposal orphan_parent reparent_entity move_observation].freeze
  # Kinds whose humanized name doesn't read well (Decision 3 of the fact supersede plan).
  KIND_LABELS = { "fact_supersede" => "Outdated by a fact" }.freeze

  # @param kind [String] a review row kind
  # @return [String] its label in badges and filters
  def review_kind_label(kind)
    KIND_LABELS.fetch(kind.to_s) { kind.to_s.humanize }
  end

  # The DOM id of a group's card on /review, so other pages can link straight to it (Home's digest).
  #
  # @param key [String] a ReviewDigest::Group key
  # @return [String]
  def review_group_dom_id(key)
    "group-#{Digest::SHA256.hexdigest(key.to_s).first(12)}"
  end

  # @param row [MaintenanceReportRow]
  # @return [String] a one-line description of the suggestion
  def review_row_title(row)
    payload = row.effective_payload
    case row.kind
    when "entity_merge" then "#{payload.dig('entity_a', 'name') || "##{payload.dig('entity_a', 'entity_id')}"} ↔ #{payload.dig('entity_b', 'name') || "##{payload.dig('entity_b', 'entity_id')}"}"
    when "relationship_proposal" then "#{payload['from_name'] || "##{payload['from_entity_id']}"} #{payload['relation_type']} #{payload['to_name'] || "##{payload['to_entity_id']}"}"
    when "contradiction" then "#{payload['entity_name_1']} ↔ #{payload['entity_name_2']}: ##{payload['observation_id_1']} vs ##{payload['observation_id_2']}"
    when "fact_supersede" then "#{payload['entity_name'] || "##{payload['observation_id']}"}: ##{payload['observation_id']} outdated by fact ##{payload['fact_observation_id']}"
    when "stale_memory" then "#{payload['entity_name'] || "##{payload['entity_id']}"}: #{Array(payload['observation_ids']).size} stale observation(s)"
    when "delete_entity" then "Delete #{payload['entity_name'].presence || "entity ##{payload['entity_id']}"}"
    when "delete_relation" then "Delete relation ##{payload['relation_id']}"
    else payload["entity_name"].presence || payload["reason"].presence || row.group_key.to_s
    end.to_s.truncate(140)
  end
end
