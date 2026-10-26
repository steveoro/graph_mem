# frozen_string_literal: true

class CompactionReviewApplier
  # What applying a review row would do (UI-5b C1): the same lookups as CompactionReviewApplier.apply,
  # no writes. Feeds the Review page's confirm card, group previews and apply_maintenance_review's
  # dry_run.
  #
  #   CompactionReviewApplier.preview(row, keep_observation_id: 12)
  #   # => { ok: true, effects: ["#15 marked obsolete", "#12 kept"], warnings: [], undo: "30 days" }
  module Preview
    UNDO_MERGE = "7 days"
    UNDO_AUDIT = "30 days"
    UNDO_NONE = "not undoable: hard delete"

    module_function

    # @param row [MaintenanceReportRow]
    # @param action_params [Hash] the same overrides apply takes
    # @return [Hash] `{ ok:, effects: [String], warnings: [String], undo: String }`
    def call(row, action_params = {})
      params = action_params.respond_to?(:to_unsafe_h) ? action_params.to_unsafe_h : action_params.to_h
      params = params.with_indifferent_access
      effective = row.effective_payload.with_indifferent_access
      method = :"preview_#{row.kind}"
      return result(false, warnings: [ "Unknown review kind: #{row.kind}" ]) unless respond_to?(method)

      send(method, effective, params)
    end

    def preview_entity_merge(effective, params)
      source = entity(pick(params, :source_id, effective, [ :source_id, [ :entity_a, :entity_id ] ]))
      target = entity(pick(params, :target_id, effective, [ :target_id, [ :entity_b, :entity_id ] ]))
      return result(false, warnings: [ "Source or target entity is gone" ]) unless source && target
      return result(false, warnings: [ "Cannot merge entities of different types" ]) if source.entity_type != target.entity_type
      if [ source, target ].any? { |e| e.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE }
        return result(false, warnings: [ NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR ])
      end

      repointed, dropped = merge_relation_counts(source.id, target.id)
      children = MemoryRelation.where(to_entity_id: source.id, relation_type: "part_of").count
      result(true, undo: UNDO_MERGE, effects: [
        "'#{source.name}' (##{source.id}) merges into '#{target.name}' (##{target.id})",
        "#{source.memory_observations.count} observation(s) move to the target",
        "#{repointed} relation(s) re-pointed, #{dropped} dropped as duplicates",
        "#{children} child entit#{children == 1 ? 'y' : 'ies'} reparented"
      ])
    end

    def preview_relationship_proposal(effective, params)
      from = entity(pick(params, :from_id, effective, [ :from_id, :from_entity_id ]))
      to = entity(pick(params, :to_id, effective, [ :to_id, :to_entity_id ]))
      type = MemoryRelation.canonical_relation_type((params[:relation_type].presence || effective[:relation_type]).to_s)
      return result(false, warnings: [ "An endpoint is gone" ]) unless from && to
      if MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id, relation_type: type)
        return result(false, warnings: [ "The relation already exists" ])
      end

      effects = [ "Creates '#{from.name}' #{type} '#{to.name}'" ]
      effects << "'#{from.name}' joins #{project_label(ProjectMembership.project_id_for_parent(to))}" if type == "part_of"
      result(true, effects: effects)
    end

    def preview_orphan_parent(effective, params)
      move_preview(pick(params, :node_id, effective, [ :node_id, :entity_id ]), pick(params, :parent_id, effective, [ :parent_id ]))
    end

    def preview_reparent_entity(effective, params)
      move_preview(pick(params, :entity_id, effective, [ :entity_id, :node_id, [ :payload, :entity_id ] ]),
                   pick(params, :parent_id, effective, [ :parent_id, [ :payload, :parent_id ] ]))
    end

    def preview_delete_relation(effective, _params)
      relation = MemoryRelation.find_by(id: effective[:relation_id] || effective.dig(:payload, :relation_id))
      return result(false, warnings: [ "Relation not found" ]) unless relation

      result(true, effects: [ "Deletes #{relation_label(relation)}" ])
    end

    def preview_delete_observation(effective, _params)
      observation = MemoryObservation.find_by(id: effective[:observation_id] || effective.dig(:payload, :observation_id))
      return result(false, warnings: [ "Observation not found" ]) unless observation

      warnings = observation.active? ? [] : [ "Observation ##{observation.id} is already #{observation.status}" ]
      result(true, effects: [ "Observation ##{observation.id} marked obsolete" ], warnings: warnings)
    end

    def preview_delete_entity(effective, _params)
      entity = entity(effective[:entity_id] || effective.dig(:payload, :entity_id))
      return result(false, warnings: [ "Entity not found" ]) unless entity
      if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
        return result(false, warnings: [ NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR ])
      end

      relations = MemoryRelation.where(from_entity_id: entity.id).or(MemoryRelation.where(to_entity_id: entity.id)).count
      children = MemoryRelation.where(to_entity_id: entity.id, relation_type: "part_of").count
      result(true, undo: UNDO_NONE, effects: [
        "Deletes '#{entity.name}' (##{entity.id}) with #{entity.memory_observations.count} observation(s) and #{relations} relation(s)",
        "#{children} child entit#{children == 1 ? 'y is' : 'ies are'} left without a parent"
      ], warnings: [ "Can't be undone" ])
    end

    def preview_stale_memory(effective, _params)
      ids = Array(effective[:observation_ids]).map(&:to_i)
      flagged = StaleMemoryScanner.still_flagged_ids(entity_id: effective[:entity_id].to_i, signal: effective[:signal], observation_ids: ids)
      active = MemoryObservation.active.where(id: flagged).count
      warnings = active < ids.size ? [ "#{ids.size - active} observation(s) are no longer flagged or already inactive" ] : []
      result(true, effects: [ "#{active} observation(s) marked obsolete" ], warnings: warnings)
    end

    def preview_relation_integrity(effective, _params)
      issue = effective[:payload].presence || effective
      ids = (Array(issue[:delete_ids]).presence || [ issue[:delete_id] ]).compact.map(&:to_i) - [ issue[:keep_id].to_i ]
      present = MemoryRelation.where(id: ids).count
      result(present.positive?, effects: [ "Deletes #{present} duplicate relation(s), keeps ##{issue[:keep_id]}" ],
             warnings: present < ids.size ? [ "#{ids.size - present} duplicate(s) already gone" ] : [])
    end

    def preview_move_observation(effective, params)
      observation = MemoryObservation.find_by(id: pick(params, :observation_id, effective, [ :observation_id, [ :payload, :observation_id ] ]))
      target = entity(pick(params, :target_entity_id, effective, [ :target_entity_id, :target_id, [ :payload, :target_entity_id ] ]))
      return result(false, warnings: [ "Observation or target entity not found" ]) unless observation && target
      return result(true, effects: [ "Nothing to do: the observation already belongs to '#{target.name}'" ]) if observation.memory_entity_id == target.id

      result(true, effects: [ "Copies observation ##{observation.id} to '#{target.name}'", "Marks ##{observation.id} obsolete" ])
    end

    def preview_dismiss_compaction_review(effective, _params)
      result(true, effects: [ "Dismisses compaction review item #{effective[:review_item_id] || effective.dig(:payload, :review_item_id)}" ])
    end

    # With keep_observation_id: the outcome; without: both outcomes, so the operator can choose.
    def preview_contradiction(effective, params)
      pair = [ effective[:observation_id_1], effective[:observation_id_2] ].map(&:to_i).sort
      observations = MemoryObservation.where(id: pair).index_by(&:id)
      warnings = pair.filter_map do |id|
        observation = observations[id]
        "Observation ##{id} is #{observation ? "no longer active (#{observation.status})" : 'gone'}" unless observation&.active?
      end
      keep = params[:keep_observation_id].to_i
      sides = pair.include?(keep) ? [ keep ] : pair
      effects = sides.map { |kept| "Keep ##{kept}: ##{(pair - [ kept ]).first} marked obsolete" }
      result(pair.size == 2 && observations[sides.first]&.active?, effects: effects, warnings: warnings)
    end

    def move_preview(node_id, parent_id)
      node = entity(node_id)
      parent = entity(parent_id)
      return result(false, warnings: [ "Entity or parent not found" ]) unless node && parent
      return result(false, warnings: [ "Would create a part_of cycle" ]) if RelationSemantics.would_create_cycle?(node.id, parent.id)

      size = 1 + ProjectMembership.member_ids(node.id).size
      result(true, effects: [ "Moves '#{node.name}' (#{size} entit#{size == 1 ? 'y' : 'ies'}) under '#{parent.name}'",
                              "Scope becomes #{project_label(ProjectMembership.project_id_for_parent(parent))}" ])
    end

    def merge_relation_counts(source_id, target_id)
      relations = MemoryRelation.where(from_entity_id: source_id).or(MemoryRelation.where(to_entity_id: source_id))
                                .where.not(from_entity_id: target_id).where.not(to_entity_id: target_id).to_a
      dropped = relations.count do |relation|
        from = relation.from_entity_id == source_id ? target_id : relation.from_entity_id
        to = relation.to_entity_id == source_id ? target_id : relation.to_entity_id
        MemoryRelation.exists?(from_entity_id: from, to_entity_id: to, relation_type: relation.relation_type)
      end
      [ relations.size - dropped, dropped ]
    end

    def result(ok, effects: [], warnings: [], undo: UNDO_AUDIT)
      { ok: ok ? true : false, effects: effects, warnings: warnings, undo: ok ? undo : nil }
    end

    def entity(id) = id.to_i.positive? ? MemoryEntity.find_by(id: id.to_i) : nil

    def pick(params, key, effective, fallbacks)
      CompactionReviewApplier.send(:pick_id, params, key, effective, fallbacks)
    end

    def project_label(project_id)
      project_id ? "project '#{MemoryEntity.where(id: project_id).pick(:name)}'" : "the global scope"
    end

    def relation_label(relation)
      names = MemoryEntity.where(id: [ relation.from_entity_id, relation.to_entity_id ]).pluck(:id, :name).to_h
      "'#{names[relation.from_entity_id]}' #{relation.relation_type} '#{names[relation.to_entity_id]}' (##{relation.id})"
    end
  end
end
