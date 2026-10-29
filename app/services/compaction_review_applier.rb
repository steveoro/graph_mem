# frozen_string_literal: true

# Executes the write half of a review row for CompactionReviewService. Kept
# separate so the queue/listing service stays under the file-size rule.
class CompactionReviewApplier
  class << self
    # What apply would do, without writing (see Preview).
    # @return [Hash] `{ ok:, effects:, warnings:, undo: }`
    def preview(row, action_params = {})
      Preview.call(row, action_params)
    end

    def apply(row, action_params)
      effective = row.effective_payload.with_indifferent_access

      case row.kind
      when "entity_merge"
        merge_entities(row, effective, action_params)
      when "relationship_proposal"
        create_relation(row, effective, action_params)
      when "orphan_parent"
        move_to_parent(row, effective, action_params)
      when "relation_integrity"
        apply_relation_integrity(effective)
      when "move_observation"
        move_observation(effective, action_params)
      when "reparent_entity"
        reparent_entity(effective, action_params)
      when "delete_relation"
        delete_relation(effective)
      when "delete_observation"
        delete_observation(effective)
      when "delete_entity"
        delete_entity(effective)
      when "dismiss_compaction_review"
        dismiss_compaction_review(effective)
      when "stale_memory"
        apply_stale_memory(effective)
      when "contradiction"
        Contradiction.apply(effective, action_params)
      when "fact_supersede"
        FactSupersede.apply(effective, action_params)
      else
        { success: false, error: "Unknown review kind: #{row.kind}" }
      end
    end

    private

    def apply_stale_memory(effective)
      obs_ids = Array(effective[:observation_ids]).compact.map(&:to_i)
      return { success: false, error: "No observation ids provided" } if obs_ids.empty?

      flagged_ids = StaleMemoryScanner.still_flagged_ids(
        entity_id: effective[:entity_id].to_i,
        signal: effective[:signal],
        observation_ids: obs_ids
      )

      reason = "Stale memory scan: #{effective[:signal] || 'flagged'} — #{effective[:reason]}".truncate(500)
      marked = 0
      skipped_inactive = 0
      skipped_resolved = 0
      found = 0
      MemoryObservation.where(id: obs_ids).find_each do |obs|
        found += 1
        if obs.status != MemoryObservation::ACTIVE_STATUS
          skipped_inactive += 1
        elsif flagged_ids.include?(obs.id)
          obs.mark_obsolete!(reason: reason)
          marked += 1
        else
          skipped_resolved += 1
        end
      end
      missing = obs_ids.size - found

      message = "Marked #{marked} observation(s) obsolete"
      message += "; skipped #{skipped_inactive} already-inactive" if skipped_inactive.positive?
      message += "; skipped #{skipped_resolved} no-longer-flagged" if skipped_resolved.positive?
      message += "; skipped #{missing} not-found" if missing.positive?
      { success: true, message: message }
    end

    def merge_entities(row, effective, action_params)
      source_id = pick_id(action_params, :source_id, effective, [ :source_id, [ :entity_a, :entity_id ] ])
      target_id = pick_id(action_params, :target_id, effective, [ :target_id, [ :entity_b, :entity_id ] ])

      return { success: false, error: "Source and target entities are required" } if source_id.zero? || target_id.zero?
      return { success: false, error: "Cannot merge an entity into itself" } if source_id == target_id

      NodeOperationsStrategy.new.merge_into(source_id, target_id)
    end

    def create_relation(row, effective, action_params)
      from_id = pick_id(action_params, :from_id, effective, [ :from_id, :from_entity_id ])
      to_id = pick_id(action_params, :to_id, effective, [ :to_id, :to_entity_id ])
      relation_type = action_params[:relation_type].presence || effective[:relation_type]

      return { success: false, error: "Invalid relation" } if from_id.zero? || to_id.zero? || relation_type.blank?
      return { success: false, error: "Invalid relation type" } unless GraphVocabulary::RELATION_TYPES.include?(relation_type.to_s)

      canonical_type = MemoryRelation.canonical_relation_type(relation_type)
      if canonical_type == "part_of"
        # Savepoint (requires_new): apply runs inside the row's with_lock
        # transaction — a sync! failure must roll back ONLY the edge write
        # so the row can still record the failure reason.
        ProjectMembership.with_membership_lock do
          ActiveRecord::Base.transaction(requires_new: true) do
            MemoryRelation.create!(
              from_entity_id: from_id,
              to_entity_id: to_id,
              relation_type: canonical_type
            )
            ProjectMembership.sync!(MemoryEntity.find(from_id))
          end
        end
      else
        MemoryRelation.create!(
          from_entity_id: from_id,
          to_entity_id: to_id,
          relation_type: canonical_type
        )
      end
      { success: true, message: "Relation created" }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      { success: false, error: "Failed to create relation: #{e.message}" }
    rescue ProjectMembership::Collision, ProjectMembership::LockTimeout => e
      { success: false, error: "Failed to create relation: #{e.message}" }
    end

    def move_to_parent(row, effective, action_params)
      node_id = pick_id(action_params, :node_id, effective, [ :node_id, :entity_id ])
      parent_id = pick_id(action_params, :parent_id, effective, [ :parent_id ])

      return { success: false, error: "Node and parent are required" } if node_id.zero? || parent_id.zero?

      NodeOperationsStrategy.new.move_to_parent(node_id, parent_id)
    end

    def apply_relation_integrity(effective)
      issue = effective[:payload].presence || effective
      keep_id = issue[:keep_id].to_i
      delete_ids = Array(issue[:delete_ids]).presence || [ issue[:delete_id] ]
      delete_ids = delete_ids.compact.map(&:to_i).reject(&:zero?).uniq - [ keep_id ]
      return { success: false, error: "No relations are selected for deletion" } if delete_ids.empty?

      deleted_ids = []
      missing_ids = []

      ActiveRecord::Base.transaction(requires_new: true) do
        begin
          Current.deletion_reason = "duplicate"
          delete_ids.each do |relation_id|
            relation = MemoryRelation.find_by(id: relation_id)
            if relation
              relation.destroy!
              deleted_ids << relation_id
            else
              missing_ids << relation_id
            end
          end
        ensure
          Current.deletion_reason = nil
        end
      end

      message = "Deleted #{deleted_ids.size} duplicate relation(s)"
      message += "; #{missing_ids.size} relation(s) were already absent" if missing_ids.any?
      { success: true, message: message, deleted_relation_ids: deleted_ids, missing_relation_ids: missing_ids }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
      { success: false, error: "Failed to apply relation integrity repair: #{e.message}" }
    end

    def delete_relation(effective)
      relation_id = effective[:relation_id] || effective.dig("payload", "relation_id")
      relation = MemoryRelation.find_by(id: relation_id)
      return { success: false, error: "Relation not found" } unless relation

      Current.deletion_reason = effective[:reason] || "scan_review"
      ProjectMembership.with_membership_lock do
        # Savepoint — see create_relation: a sync! failure inside apply's
        # row-lock transaction must roll back ONLY this delete.
        ActiveRecord::Base.transaction(requires_new: true) do
          from_entity = relation.from_entity
          part_of = relation.relation_type == "part_of"
          relation.destroy!
          ProjectMembership.sync!(from_entity) if part_of && from_entity
        end
      end
      { success: true, message: "Relation #{relation_id} deleted" }
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid,
           ProjectMembership::Collision, ProjectMembership::LockTimeout => e
      { success: false, error: "Failed to delete relation: #{e.message}" }
    ensure
      Current.deletion_reason = nil
    end

    def delete_entity(effective)
      entity_id = effective[:entity_id] || effective.dig("payload", "entity_id")
      entity = MemoryEntity.find_by(id: entity_id)
      return { success: false, error: "Entity not found" } unless entity

      if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
        members = MemoryEntity.where(project_id: entity.id).count
        return { success: false,
                 error: "#{NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR} (#{members} members still scoped to it)" }
      end

      Current.deletion_reason = effective[:reason] || "scan_review"
      entity.destroy!
      { success: true, message: "Entity #{entity_id} deleted" }
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid => e
      { success: false, error: "Failed to delete entity: #{e.message}" }
    ensure
      Current.deletion_reason = nil
    end

    def dismiss_compaction_review(effective)
      review_item_id = effective[:review_item_id] || effective.dig("payload", "review_item_id")
      reason = effective[:reason] || effective.dig("payload", "reason") || "contradicted by project scan"
      result = CompactionReviewService.dismiss(review_item_id, reason: reason, report_type: "compaction_review")
      result[:message] = "Compaction review item dismissed" if result[:success]
      result
    end

    def delete_observation(effective)
      observation_id = effective[:observation_id] || effective.dig("payload", "observation_id")
      return { success: false, error: "Observation not found" } if observation_id.blank?

      observation = MemoryObservation.find_by(id: observation_id.to_i)
      return { success: false, error: "Observation not found" } unless observation

      observation.mark_obsolete!(reason: effective[:reason] || "Removed via scan review")
      observation.update!(confidence: 1.0)
      { success: true, message: "Observation marked obsolete" }
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "Failed to delete observation: #{e.message}" }
    end

    def move_observation(effective, action_params)
      observation_id = pick_id(action_params, :observation_id, effective, [ :observation_id, [ "payload", "observation_id" ] ])
      target_entity_id = pick_id(action_params, :target_entity_id, effective, [ :target_entity_id, :target_id, [ "payload", "target_entity_id" ] ])

      return { success: false, error: "Observation and target entity are required" } if observation_id.zero? || target_entity_id.zero?

      observation = MemoryObservation.find_by(id: observation_id)
      return { success: false, error: "Observation not found" } unless observation

      target_entity = MemoryEntity.find_by(id: target_entity_id)
      return { success: false, error: "Target entity not found" } unless target_entity

      return { success: true, message: "Observation already belongs to target entity" } if observation.memory_entity_id == target_entity.id

      ActiveRecord::Base.transaction(requires_new: true) do
        MemoryObservation.create!(
          memory_entity: target_entity,
          content: observation.content,
          source: "project_scan:review_move:from_observation:#{observation.id}",
          confidence: 1.0
        )
        observation.mark_obsolete!(reason: "Moved to entity #{target_entity.name} (#{target_entity.id}) via scan review")
        observation.update!(confidence: 1.0)
      end

      { success: true, message: "Observation moved to #{target_entity.name}" }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      { success: false, error: "Failed to move observation: #{e.message}" }
    end

    def reparent_entity(effective, action_params)
      entity_id = pick_id(action_params, :entity_id, effective, [ :entity_id, :node_id, [ "payload", "entity_id" ] ])
      parent_id = pick_id(action_params, :parent_id, effective, [ :parent_id, [ "payload", "parent_id" ] ])

      return { success: false, error: "Entity and parent are required" } if entity_id.zero? || parent_id.zero?

      NodeOperationsStrategy.new.move_to_parent(entity_id, parent_id)
    end

    def pick_id(action_params, key, effective, fallback_keys)
      value = action_params[key].presence || action_params[key.to_s].presence
      return value.to_i if value.present?

      fallback_keys.each do |fk|
        value = if fk.is_a?(Array)
                  effective.dig(*fk.map(&:to_s))
        else
                  effective[fk.to_s]
        end
        return value.to_i if value.present?
      end

      0
    end
  end
end
