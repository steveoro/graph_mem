# frozen_string_literal: true

class ReviewRowClassifier
  # Finds the entity a review row is about, per kind, from the payload shapes the generators write
  # (some nest their fields under "payload"). Observation and relation kinds look up their owner or
  # endpoints; the lookups are cached for the classifier's lifetime.
  module Anchors
    SINGLE_ANCHOR_KINDS = %w[orphan_parent stale_memory entity_error embedding_backfill_failed lifecycle_corruption
                             delete_entity reparent_entity].freeze
    PAIR_KINDS = %w[entity_merge relationship_proposal relation_integrity contradiction].freeze
    OBSERVATION_KINDS = %w[delete_observation move_observation].freeze

    private

    # @return [Array(String, Integer|nil)] the group key and the anchor entity id
    def group_and_anchor(kind, payload, row_uuid)
      case kind
      when *SINGLE_ANCHOR_KINDS then single(kind, field(payload, :entity_id) || field(payload, :node_id))
      when "delete_relation" then relation_pair(kind, payload, row_uuid)
      when *OBSERVATION_KINDS then observation_owner(kind, payload, row_uuid)
      when "dismiss_compaction_review" then [ "#{kind}|#{field(payload, :review_item_id)}", nil ]
      when *PAIR_KINDS then pair(kind, pair_ids(kind, payload), row_uuid)
      else [ "#{kind}|row:#{row_uuid}", nil ]
      end
    end

    def pair_ids(kind, payload)
      case kind
      when "entity_merge"
        [ payload.dig("entity_a", "entity_id") || payload["source_id"], payload.dig("entity_b", "entity_id") || payload["target_id"] ]
      when "relationship_proposal"
        [ payload["from_entity_id"] || payload["from_id"], payload["to_entity_id"] || payload["to_id"] ]
      when "contradiction" then [ payload["entity_id_1"], payload["entity_id_2"] ]
      when "relation_integrity" then integrity_ids(payload["payload"].is_a?(Hash) ? payload["payload"] : payload)
      end
    end

    # same_direction: the edge's endpoints; reverse_pair: the kept edge's endpoints;
    # merge_collision: the child only (it has several parents, so no single pair).
    def integrity_ids(issue)
      return [ issue["child_entity_id"] ] if issue["child_entity_id"]

      keep = issue["keep"].is_a?(Hash) ? issue["keep"] : issue
      [ keep["from_entity_id"], keep["to_entity_id"] ]
    end

    def single(kind, entity_id)
      id = integer(entity_id)
      id ? [ "#{kind}|#{id}", id ] : [ "#{kind}|row:unknown", nil ]
    end

    def pair(kind, ids, row_uuid)
      ids = Array(ids).filter_map { |id| integer(id) }.uniq.sort
      return [ "#{kind}|row:#{row_uuid}", nil ] if ids.empty?
      return single(kind, ids.first) if ids.size == 1

      [ "#{kind}|#{ids.first}-#{ids.last}", ids.first ]
    end

    def relation_pair(kind, payload, row_uuid)
      endpoints = relation_endpoints(integer(field(payload, :relation_id)))
      endpoints ? pair(kind, endpoints, row_uuid) : [ "#{kind}|row:#{row_uuid}", nil ]
    end

    def observation_owner(kind, payload, row_uuid)
      owner = observation_owner_id(integer(field(payload, :observation_id)))
      owner ? [ "#{kind}|obs:#{owner}", owner ] : [ "#{kind}|row:#{row_uuid}", nil ]
    end

    def relation_endpoints(relation_id)
      return unless relation_id

      @relation_endpoints ||= {}
      return @relation_endpoints[relation_id] if @relation_endpoints.key?(relation_id)

      @relation_endpoints[relation_id] = MemoryRelation.where(id: relation_id).pick(:from_entity_id, :to_entity_id)
    end

    def observation_owner_id(observation_id)
      return unless observation_id

      @observation_owners ||= {}
      return @observation_owners[observation_id] if @observation_owners.key?(observation_id)

      @observation_owners[observation_id] = MemoryObservation.where(id: observation_id).pick(:memory_entity_id)
    end

    # Reads a field at the top level or under the nested "payload" some generators use.
    def field(payload, key)
      nested = payload["payload"]
      payload[key.to_s].presence || (nested.is_a?(Hash) ? nested[key.to_s].presence : nil)
    end

    def integer(value)
      value.to_s.match?(/\A\d+\z/) ? value.to_i : nil
    end
  end
end
