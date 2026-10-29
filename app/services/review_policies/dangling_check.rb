# frozen_string_literal: true

module ReviewPolicies
  # Why a review row no longer applies, per kind (nil = it still does). Reads the payload shapes
  # the generators write, nested "payload" included.
  module DanglingCheck
    extend self

    # @param row [MaintenanceReportRow]
    # @return [String, nil] e.g. "entity #12 gone", "relation already exists"
    def reason(row)
      payload = row.effective_payload.to_h.deep_stringify_keys
      nested = payload["payload"].is_a?(Hash) ? payload["payload"] : {}
      field = ->(key) { payload[key].presence || nested[key].presence }
      send(:"#{row.kind}_reason", payload, field) if respond_to?(:"#{row.kind}_reason")
    end

    def entity_merge_reason(payload, _field)
      gone_entity(payload.dig("entity_a", "entity_id") || payload["source_id"], payload.dig("entity_b", "entity_id") || payload["target_id"])
    end

    def relationship_proposal_reason(_payload, field)
      from = field.call("from_entity_id") || field.call("from_id")
      to = field.call("to_entity_id") || field.call("to_id")
      type = MemoryRelation.canonical_relation_type(field.call("relation_type").to_s)
      gone_entity(from, to) ||
        ("relation already exists" if MemoryRelation.exists?(from_entity_id: from, to_entity_id: to, relation_type: type))
    end

    def orphan_parent_reason(_payload, field)
      entity_id = field.call("entity_id")
      gone_entity(entity_id) ||
        ("entity already has a parent" if MemoryRelation.exists?(from_entity_id: entity_id, relation_type: "part_of"))
    end

    def reparent_entity_reason(_payload, field)
      entity_id = field.call("entity_id") || field.call("node_id")
      parent_id = field.call("parent_id")
      gone_entity(entity_id, parent_id) ||
        ("entity already under the parent" if MemoryRelation.exists?(from_entity_id: entity_id, to_entity_id: parent_id, relation_type: "part_of"))
    end

    %w[delete_entity entity_error embedding_backfill_failed].each do |kind|
      define_method(:"#{kind}_reason") { |_payload, field| gone_entity(field.call("entity_id")) }
    end

    def delete_relation_reason(_payload, field)
      relation_id = field.call("relation_id")
      "relation ##{relation_id} gone" unless MemoryRelation.exists?(id: relation_id)
    end

    def relation_integrity_reason(_payload, field)
      keep_id = field.call("keep_id")
      delete_ids = Array(field.call("delete_ids") || field.call("delete_id"))
      return "relation ##{keep_id} gone" unless MemoryRelation.exists?(id: keep_id)

      "duplicates already removed" unless MemoryRelation.exists?(id: delete_ids)
    end

    def delete_observation_reason(_payload, field)
      inactive_observation([ field.call("observation_id") ], any: true)
    end

    def lifecycle_corruption_reason(_payload, field)
      "observation ##{field.call('observation_id')} gone" unless MemoryObservation.exists?(id: field.call("observation_id"))
    end

    def move_observation_reason(_payload, field)
      observation_id = field.call("observation_id")
      target_id = field.call("target_entity_id") || field.call("target_id")
      inactive_observation([ observation_id ], any: true) || gone_entity(target_id) ||
        ("observation already on the target" if MemoryObservation.exists?(id: observation_id, memory_entity_id: target_id))
    end

    def stale_memory_reason(payload, field)
      gone_entity(field.call("entity_id")) || inactive_observation(Array(payload["observation_ids"]), any: false)
    end

    def contradiction_reason(payload, _field)
      inactive_observation([ payload["observation_id_1"], payload["observation_id_2"] ], any: true)
    end

    # The fact or the observation is gone or inactive, or the fact lost its tag.
    def fact_supersede_reason(payload, _field)
      inactive_observation([ payload["fact_observation_id"], payload["observation_id"] ], any: true) ||
        ("observation ##{payload['fact_observation_id']} is no longer a source fact" unless
          MemoryObservation.fact_tagged.exists?(id: payload["fact_observation_id"].to_i))
    end

    # @return [String, nil] the first referenced entity that no longer exists
    def gone_entity(*ids)
      ids = ids.compact.map(&:to_i)
      missing = ids - MemoryEntity.where(id: ids).pluck(:id)
      "entity ##{missing.first} gone" if missing.any?
    end

    # any: true -> a reason when any observation is gone or inactive; false -> only when all are.
    def inactive_observation(ids, any:)
      ids = ids.compact.map(&:to_i)
      return nil if ids.empty?

      active = MemoryObservation.active.where(id: ids).pluck(:id)
      inactive = ids - active
      return nil if inactive.empty? || (!any && active.any?)

      any ? "observation ##{inactive.first} gone or no longer active" : "observations no longer active"
    end
  end
end
