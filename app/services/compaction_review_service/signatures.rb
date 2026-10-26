# frozen_string_literal: true

class CompactionReviewService
  # One signature per suggestion: seeding skips signatures already pending or suppressed, and a
  # dismissal suppresses its signature. Extended into CompactionReviewService.
  module Signatures
    # @param kind [String] the row kind
    # @param payload [Hash] the row payload (string or symbol keys)
    # @return [String, nil] nil when the payload lacks what the kind needs
    def signature_for(kind, payload)
      payload = payload.to_h.deep_stringify_keys.with_indifferent_access if payload.respond_to?(:to_h)

      case kind.to_s
      when "entity_merge"
        ids = [ payload.dig("entity_a", "entity_id"), payload.dig("entity_b", "entity_id") ].compact
        ids += [ payload[:source_id], payload[:target_id] ].compact if payload[:source_id] && payload[:target_id]
        ids = ids.uniq.sort
        return nil if ids.size < 2

        [ "entity_merge", ids.join("-") ].join("|")
      when "relationship_proposal"
        from_id = payload[:from_entity_id] || payload[:from_id]
        to_id = payload[:to_entity_id] || payload[:to_id]
        relation_type = payload[:relation_type]
        return nil if from_id.blank? || to_id.blank? || relation_type.blank?

        # A symmetric relation reads the same both ways: A→B and B→A are one suggestion.
        from_id, to_id = [ from_id, to_id ].sort_by(&:to_i) if RelationSemantics.symmetric?(relation_type)
        [ "relationship_proposal", from_id, to_id, relation_type ].join("|")
      when "orphan_parent"
        entity_id = payload[:entity_id]
        return nil if entity_id.blank?

        [ "orphan_parent", entity_id ].join("|")
      when "entity_error"
        entity_id = payload[:entity_id]
        phase = payload[:phase]
        return nil if entity_id.blank?

        [ "entity_error", entity_id, phase ].compact.join("|")
      when "embedding_backfill_failed"
        entity_id = payload[:entity_id]
        return nil if entity_id.blank?

        [ "embedding_backfill_failed", entity_id ].join("|")
      when "lifecycle_corruption"
        observation_id = payload[:observation_id]
        return nil if observation_id.blank?

        [ "lifecycle_corruption", observation_id ].join("|")
      when "relation_integrity"
        issue_kind = payload[:issue_kind] || payload.dig("payload", "kind")
        keep_id = payload.dig(:payload, :keep_id) || payload[:keep_id]
        delete_ids = payload.dig(:payload, :delete_ids) || payload[:delete_ids]
        delete_ids ||= [ payload.dig(:payload, :delete_id) || payload[:delete_id] ]
        delete_ids = Array(delete_ids).compact.map(&:to_i).sort
        return nil if issue_kind.blank? || keep_id.blank? || delete_ids.empty?

        [ "relation_integrity", issue_kind, keep_id, delete_ids.join("-") ].join("|")
      when "delete_relation"
        relation_id = payload[:relation_id] || payload.dig("payload", "relation_id")
        return nil if relation_id.blank?

        [ "delete_relation", relation_id.to_i ].join("|")
      when "delete_observation"
        observation_id = payload[:observation_id] || payload.dig("payload", "observation_id")
        return nil if observation_id.blank?

        [ "delete_observation", observation_id.to_i ].join("|")
      when "delete_entity"
        entity_id = payload[:entity_id] || payload.dig("payload", "entity_id")
        return nil if entity_id.blank?

        [ "delete_entity", entity_id.to_i ].join("|")
      when "dismiss_compaction_review"
        review_item_id = payload[:review_item_id] || payload.dig("payload", "review_item_id")
        return nil if review_item_id.blank?

        [ "dismiss_compaction_review", review_item_id.to_s ].join("|")
      when "move_observation"
        observation_id = payload[:observation_id] || payload.dig("payload", "observation_id")
        target_entity_id = payload[:target_entity_id] || payload[:target_id] || payload.dig("payload", "target_entity_id")
        return nil if observation_id.blank? || target_entity_id.blank?

        [ "move_observation", observation_id.to_i, target_entity_id.to_i ].join("|")
      when "reparent_entity"
        entity_id = payload[:entity_id] || payload[:node_id] || payload.dig("payload", "entity_id")
        parent_id = payload[:parent_id] || payload.dig("payload", "parent_id")
        return nil if entity_id.blank? || parent_id.blank?

        [ "reparent_entity", entity_id.to_i, parent_id.to_i ].join("|")
      when "stale_memory"
        # Dedupe on entity + observation set + SIGNAL: distinct diagnoses over
        # the same obs (expiry vs addressed-edge) are different items — a
        # dismissal must only suppress the signal it was taken on.
        entity_id = payload[:entity_id]
        obs_ids = Array(payload[:observation_ids]).compact.map(&:to_i).sort
        return nil if entity_id.blank? || obs_ids.empty?

        [ "stale_memory", entity_id.to_i, obs_ids.join("-"), payload[:signal] ].join("|")
      when "contradiction"
        # Order-independent: (a, b) and (b, a) are one pair, and a dismissal suppresses both.
        ids = [ payload[:observation_id_1], payload[:observation_id_2] ].compact.map(&:to_i).uniq.sort
        return nil unless ids.size == 2

        [ "contradiction", ids.join("-") ].join("|")
      else
        nil
      end
    end
  end
end
