# frozen_string_literal: true

class CompactionReviewApplier
  # A `relation_retype` row whose child already has another `part_of` parent (RelationRetype): the
  # plain retype would give it a second parent, so the operator chooses, through the row's existing
  # options hash (`action_params`, which the Review page posts and `apply_maintenance_review`
  # forwards as it is):
  #
  # - `parent_choice: "move"`: the child moves under the row's target. The variant is deleted and
  #   NodeOperationsStrategy#move_to_parent does the move (cycle check, the old parent edge deleted,
  #   the new one created through the validating path, ProjectMembership.sync! of the child and its
  #   subtree), in one savepoint: a refusal (cycle, name collision) leaves everything as it was. The
  #   new edge keeps the variant's weight, confidence and properties.
  # - `parent_choice: "keep"`: the child keeps its parent and the variant becomes `relates_to` (a plain
  #   update; into a `relates_to` twin on the same endpoints it is merged with the sweep's rule,
  #   RelationTypeSweep.merge_into_twin!). No membership change.
  #
  # Both are one change set (the review apply's), undone by the generic undo. Without a choice the
  # apply answers a "choice required" error naming both.
  #
  #   RelationRetypeChoice.apply(relation, parent_id, { parent_choice: "keep" })
  #   # => { success: true, message: "Relation #41 'child_of' kept as relates_to; 'SynthWidget' stays part_of 'Alpha Service'" }
  module RelationRetypeChoice
    KEY = "parent_choice"
    CHOICES = %w[move keep].freeze
    KEEP_TYPE = "relates_to"
    MOVE_REASON = "relation type canonicalized: the child moved under the variant's target"
    KEEP_REASON = "relation type canonicalized: kept as relates_to"

    module_function

    # @param relation [MemoryRelation] the row's variant edge
    # @return [Integer, nil] the child's current part_of parent other than the row's target
    def current_parent_id(relation)
      MemoryRelation.where(from_entity_id: relation.from_entity_id, relation_type: RelationTypeSweep::PART_OF)
                    .where.not(to_entity_id: relation.to_entity_id).pick(:to_entity_id)
    end

    # @param relation [MemoryRelation]
    # @param parent_id [Integer] see #current_parent_id
    # @param action_params [Hash] `parent_choice` ("move" or "keep")
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(relation, parent_id, action_params)
      case choice(action_params)
      when "move" then move!(relation, parent_id)
      when "keep" then keep!(relation, parent_id)
      else { success: false, error: choice_problem(relation, parent_id, action_params) }
      end
    end

    # @return [Hash] `{ ok:, effects:, warnings:, undo: }` (see Preview)
    def preview(relation, parent_id, action_params)
      case choice(action_params)
      when "move" then preview_move(relation, parent_id)
      when "keep" then preview_keep(relation, parent_id)
      else Preview.result(false, warnings: [ choice_problem(relation, parent_id, action_params) ])
      end
    end

    def choice(action_params)
      params = action_params.respond_to?(:to_unsafe_h) ? action_params.to_unsafe_h : action_params.to_h
      params.with_indifferent_access[KEY].to_s.presence
    end

    def choice_problem(relation, parent_id, action_params)
      names = names_for(relation, parent_id)
      given = choice(action_params)
      lead = given ? "Invalid #{KEY} '#{given}'" : "A choice is required"
      "#{lead}: '#{names[:child]}' is already part_of '#{names[:parent]}'. Pass action_params.#{KEY} \"move\" (move it " \
        "under '#{names[:target]}', replacing that parent) or \"keep\" (keep its parent; the variant becomes #{KEEP_TYPE}); " \
        "Review & Fix offers both"
    end

    def move!(relation, parent_id)
      names = names_for(relation, parent_id)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        Current.set(deletion_reason: MOVE_REASON) do
          relation.destroy!
          result = NodeOperationsStrategy.new.move_to_parent(relation.from_entity_id, relation.to_entity_id)
        end
        raise ActiveRecord::Rollback unless result[:success]

        carry_attributes!(relation)
      end
      return { success: false, error: "Cannot retype relation ##{relation.id}: #{result[:error]}" } unless result[:success]

      { success: true, message: "Relation ##{relation.id} '#{relation.relation_type}' replaced: '#{names[:child]}' moved from " \
                                "'#{names[:parent]}' under '#{names[:target]}'" }
    end

    # The new parent edge keeps what the variant carried (move_to_parent creates a bare edge).
    def carry_attributes!(relation)
      edge = MemoryRelation.find_by!(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                     relation_type: RelationTypeSweep::PART_OF)
      edge.assign_attributes(weight: relation.weight, confidence: relation.confidence,
                             properties: relation.properties.is_a?(Hash) ? relation.properties : {})
      edge.save! if edge.changed?
    end

    def keep!(relation, parent_id)
      names = names_for(relation, parent_id)
      twin = MemoryRelation.lock.where(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                       relation_type: KEEP_TYPE).where.not(id: relation.id).first
      old_type = relation.relation_type
      if twin
        RelationTypeSweep.merge_into_twin!(relation, twin, reason: "#{KEEP_REASON}: merged into ##{twin.id}")
        done = "merged into #{KEEP_TYPE} ##{twin.id}"
      else
        relation.update!(relation_type: KEEP_TYPE)
        done = "kept as #{KEEP_TYPE}"
      end
      { success: true, message: "Relation ##{relation.id} '#{old_type}' #{done}; '#{names[:child]}' stays part_of '#{names[:parent]}'" }
    end

    def preview_move(relation, parent_id)
      names = names_for(relation, parent_id)
      child = MemoryEntity.find(relation.from_entity_id)
      target = MemoryEntity.find(relation.to_entity_id)
      if RelationSemantics.would_create_cycle?(child.id, target.id)
        return Preview.result(false, warnings: [ "Cannot move '#{names[:child]}' under '#{names[:target]}': it would create a part_of cycle" ])
      end

      from_project = child.project_id
      to_project = ProjectMembership.project_id_for_parent(target)
      clash = from_project == to_project ? nil : ProjectMembership.collision_name(child, to_project)
      if clash
        return Preview.result(false, warnings: [ "Cannot move '#{names[:child]}' to #{Preview.project_label(to_project)}: " \
                                                 "'#{clash}' already exists there" ])
      end

      Preview.result(true, effects: [
        "Moves '#{names[:child]}' from '#{names[:parent]}' under '#{names[:target]}' (the variant ##{relation.id} " \
        "'#{relation.relation_type}' becomes that part_of edge)",
        project_effect(child, from_project, to_project)
      ])
    end

    def project_effect(child, from_project, to_project)
      return "Stays in #{Preview.project_label(from_project)}" if from_project == to_project

      size = 1 + ProjectMembership.member_ids(child.id).size
      "Moves #{size} entit#{size == 1 ? 'y' : 'ies'} from #{Preview.project_label(from_project)} to #{Preview.project_label(to_project)}"
    end

    def preview_keep(relation, parent_id)
      names = names_for(relation, parent_id)
      twin_id = MemoryRelation.where(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                     relation_type: KEEP_TYPE).where.not(id: relation.id).pick(:id)
      change = twin_id ? "Merges the variant ##{relation.id} into #{KEEP_TYPE} ##{twin_id}" :
                         "Retypes the variant ##{relation.id} from '#{relation.relation_type}' to #{KEEP_TYPE}"
      Preview.result(true, effects: [ "Keeps '#{names[:child]}' part_of '#{names[:parent]}'", change, "No membership change" ])
    end

    def names_for(relation, parent_id)
      names = MemoryEntity.where(id: [ relation.from_entity_id, relation.to_entity_id, parent_id ]).pluck(:id, :name).to_h
      { child: names[relation.from_entity_id], target: names[relation.to_entity_id], parent: names[parent_id] }
    end
  end
end
