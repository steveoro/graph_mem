# frozen_string_literal: true

# Labels for the Review page (UI-5b).
module ReviewHelper
  # Kinds whose targets can be edited before applying (the detail pane shows entity pickers).
  EDITABLE_KINDS = %w[entity_merge relationship_proposal orphan_parent reparent_entity move_observation].freeze
  # Kinds whose humanized name doesn't read well (Decision 3 of the fact supersede plan).
  KIND_LABELS = { "fact_supersede" => "Outdated by a fact" }.freeze

  # Kinds whose Apply button reads otherwise (an i18n key).
  APPLY_LABELS = { "lifecycle_corruption" => "ui.review.lifecycle_corruption.repair" }.freeze

  # One side of a contradiction with the tokens that differ from the other side in <mark> (1.92.0).
  # The text is escaped piece by piece (safe_join); a token past the 300-character cut isn't marked.
  #
  #   review_diff_text("Port: 3000", [ span ]) # => "Port: <mark>3000</mark>"
  #
  # @param text [String, nil] the side's text
  # @param spans [Array<FactKeywords::TokenDiff::Span>] its differing tokens (offsets in `text`)
  # @return [ActiveSupport::SafeBuffer]
  def review_diff_text(text, spans)
    text = text.to_s
    shown = text.truncate(ContradictionDetector::REVIEW_CONTENT_LIMIT)
    cut = shown == text ? text.length : ContradictionDetector::REVIEW_CONTENT_LIMIT - 3
    position = 0
    pieces = spans.sort_by(&:offset).each_with_object([]) do |span, parts|
      next if span.offset < position || span.offset + span.length > cut

      parts << shown[position...span.offset] << tag.mark(shown[span.offset, span.length])
      position = span.offset + span.length
    end
    safe_join(pieces << shown[position..])
  end

  # The differing tokens of each contradiction side, when few enough to highlight: at most
  # TokenDiff::HIGHLIGHT_MAX per side, and at least one.
  #
  # @param pair [Array<MemoryObservation, nil>] the two sides, live
  # @return [Array<Array<FactKeywords::TokenDiff::Span>>, nil] [first side's, second side's], or nil
  def review_diff_spans(pair)
    return nil unless pair.all?

    found = FactKeywords::TokenDiff.diff(pair.first.content, pair.last.content).values_at(:left, :right)
    found if found.sum(&:size).positive? && found.all? { |spans| spans.size <= FactKeywords::TokenDiff::HIGHLIGHT_MAX }
  end

  # @param kind [String] a review row kind
  # @return [String] the label of its Apply button ("Repair" for a lifecycle_corruption row)
  def review_apply_label(kind)
    APPLY_LABELS.key?(kind.to_s) ? t(APPLY_LABELS[kind.to_s]) : "Apply"
  end

  # @param row [MaintenanceReportRow]
  # @param preview [Hash] CompactionReviewApplier.preview of the row
  # @return [Boolean] the detail pane offers Apply…: not for a choice kind, nor for a lifecycle row
  #   Repair refuses (a cross-entity superseded_by: Dismiss only), nor for a relation_retype row
  #   whose child already has a parent (its card offers Move and Keep)
  def review_offers_apply?(row, preview)
    return false if ReviewRowClassifier::CHOICE_KINDS.include?(row.kind)
    # A relation_retype row whose child already has a parent offers Move / Keep on its card instead.
    return false if row.kind == "relation_retype" && CompactionReviewApplier::RelationRetype.choice_parent_id(row.effective_payload)

    row.kind != "lifecycle_corruption" || preview[:ok]
  end

  # @param observation [MemoryObservation] the observation of a lifecycle_corruption row
  # @param other [MemoryObservation, nil] its superseded_by or outdated_by
  # @return [String] e.g. "#12 (active, same entity)", or "none"
  def review_lifecycle_link(observation, other)
    scope = "ui.review.lifecycle_corruption"
    return t("#{scope}.none") unless other

    entity = other.memory_entity_id == observation.memory_entity_id ? t("#{scope}.same_entity") : t("#{scope}.other_entity", id: other.memory_entity_id)
    t("#{scope}.link", id: other.id, status: other.status, entity: entity)
  end

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
    when "relation_retype" then relation_retype_title(payload)
    when "lifecycle_corruption" then "Observation ##{payload['observation_id']}: #{payload['issue']}"
    else payload["entity_name"].presence || payload["reason"].presence || row.group_key.to_s
    end.to_s.truncate(140)
  end

  private

  # "SynthLib part_of → depends_on SynthApp" (retype); R1b: "swap: SynthApp depends_on SynthLib
  # (was part_of)" and "add: SynthApp depends_on SynthLib".
  def relation_retype_title(payload)
    from = payload["from_name"] || "##{payload['from_entity_id']}"
    to = payload["to_name"] || "##{payload['to_entity_id']}"
    case payload["operation"]
    when CompactionReviewApplier::RelationRetypeDependency::SWAP then "swap: #{to} #{payload['new_type']} #{from} (was #{payload['old_type']})"
    when CompactionReviewApplier::RelationRetypeDependency::ADD then "add: #{from} #{payload['new_type']} #{to}"
    else "#{from} #{payload['old_type']} → #{payload['new_type']} #{to}"
    end
  end
end
