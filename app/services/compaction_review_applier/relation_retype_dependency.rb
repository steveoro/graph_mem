# frozen_string_literal: true

class CompactionReviewApplier
  # The `swap` and `add` operations of a `relation_retype` row (Dream State R1b), next to R1a's
  # `retype` (RelationRetype). The payload keys are R1a's plus `evidence`:
  #
  # - `swap`: `relation_id` and the endpoints are the stored `part_of` edge (library → Project),
  #   `old_type` is `part_of`, `new_type` is `depends_on`. Apply, under the membership lock
  #   (CompactionReviewService.apply takes it before the row's transaction; taken again here,
  #   reentrant) in one savepoint: the `part_of` is deleted, `Project depends_on library` is created
  #   through the validating path (MemoryRelation.create!, kept when it exists already), then
  #   ProjectMembership.sync! moves the library and its own `part_of` subtree to the global scope
  #   (project_id NULL); the subtree stays attached to the library. A global entity that holds the
  #   library's name already refuses the row and queues an `entity_merge` suggestion for the two
  #   (same type only: a merge needs it; see #queue_merge for its direction); a child's name taken
  #   globally refuses it, naming the child, and queues nothing.
  # - `add`: `relation_id` and `old_type` are null, the endpoints are the edge to create
  #   (Project → entity). Apply creates `Project depends_on entity`. No membership change: the
  #   entity is an orphan (phase `orphans`), so it is global already.
  #
  # A row whose edge is gone, already swapped or already added answers like R1a's stale rows: done
  # → success with nothing written; gone → an error asking to dismiss it. Undo is the generic audit
  # undo (the depends_on removed, the part_of re-inserted, membership synced back).
  #
  #   RelationRetypeDependency.apply({ operation: "swap", relation_id: 41, … })
  #   # => { success: true, message: "Relation #41 'SynthLib' part_of 'SynthApp' swapped for 'SynthApp' depends_on 'SynthLib' (#57); …" }
  module RelationRetypeDependency
    SWAP = "swap"
    ADD = "add"
    OPERATIONS = [ SWAP, ADD ].freeze
    NEW_TYPE = "depends_on"
    DELETION_REASON = "dependency-like part_of swapped for the project's depends_on through review"
    MERGE_SOURCE = "relation_retype"

    module_function

    # The review item dream state queues for a library `part_of` a Project.
    # @param relation [MemoryRelation] the part_of edge (library → Project)
    # @param names [Hash{Integer => String}] entity names by id
    # @param evidence [Hash] see DependencyEvidence
    # @return [Hash] the item for CompactionReviewService.seed_report
    def swap_item(relation, names, evidence:)
      library = names[relation.from_entity_id]
      project = names[relation.to_entity_id]
      { id: SecureRandom.uuid, kind: RelationTypeSweep::REVIEW_KIND, operation: SWAP, relation_id: relation.id,
        from_entity_id: relation.from_entity_id, from_name: library, to_entity_id: relation.to_entity_id, to_name: project,
        old_type: RelationTypeSweep::PART_OF, new_type: NEW_TYPE, evidence: evidence,
        reason: "'#{library}' is a #{evidence[:entity_type]}, so '#{project}' uses it rather than owns it: its part_of " \
                "becomes '#{project}' depends_on '#{library}', and it leaves the project's scope" }
    end

    # The review item phase 1 queues for a dependency-like orphan.
    # @param project [MemoryEntity] the best-matching Project
    # @param entity [MemoryEntity] the orphan
    # @param evidence [Hash] the entity type, the match's score and matched tokens
    # @return [Hash]
    def add_item(project, entity, evidence:)
      { id: SecureRandom.uuid, kind: RelationTypeSweep::REVIEW_KIND, operation: ADD, relation_id: nil,
        from_entity_id: project.id, from_name: project.name, to_entity_id: entity.id, to_name: entity.name,
        old_type: nil, new_type: NEW_TYPE, evidence: evidence,
        reason: "'#{entity.name}' is a #{entity.entity_type} with no parent: '#{project.name}' best matches it, so it " \
                "is proposed as a dependency of that project (no membership change) instead of a part of it" }
    end

    # @param effective [Hash] the row's effective payload (indifferent access)
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective)
      effective[:operation].to_s == SWAP ? apply_swap(effective) : apply_add(effective)
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "#{label(effective)}: #{e.record.errors.full_messages.to_sentence}" }
    rescue ActiveRecord::RecordNotUnique, ProjectMembership::Collision => e
      { success: false, error: "#{label(effective)}: #{e.message}" }
    end

    # @return [Hash] `{ ok:, effects:, warnings:, undo: }` (see Preview)
    def preview(effective)
      plan = effective[:operation].to_s == SWAP ? swap_plan(effective, lock: false) : add_plan(effective)
      if plan.key?(:success)
        return plan[:success] ? Preview.result(true, effects: [ plan[:message] ]) : Preview.result(false, warnings: [ plan[:error] ])
      end
      return Preview.result(false, warnings: [ plan[:refusal] ]) if plan[:refusal]

      Preview.result(true, effects: plan[:effects])
    end

    # What a swap does to scope, for the preview, the apply's message and the Review card.
    # @param library [MemoryEntity]
    # @param project_id [Integer, nil] the project the library is in before the swap
    # @return [String] e.g. "SynthLib and its 2 children leave SynthApp's scope (they become global)"
    def scope_effect(library, project_id)
      children = ProjectMembership.member_ids(library.id).size
      who = children.zero? ? library.name : "#{library.name} and its #{children} child#{children == 1 ? '' : 'ren'}"
      project = project_id && MemoryEntity.where(id: project_id).pick(:name)
      return "#{who} #{children.zero? ? 'is' : 'are'} global already" unless project

      "#{who} #{children.zero? ? 'leaves' : 'leave'} #{project}'s scope (#{children.zero? ? 'it becomes' : 'they become'} global)"
    end

    # --- swap ------------------------------------------------------------------------------------

    def apply_swap(effective)
      plan = swap_plan(effective, lock: true)
      return plan if plan.key?(:success)

      if plan[:refusal]
        queue_merge(plan[:merge]) if plan[:merge]
        return { success: false, error: plan[:refusal] }
      end

      swap!(plan[:relation], plan[:library], plan[:project])
    end

    # @return [Hash] a stale answer (`success:` key), a `refusal:` (with the `merge:` pair to queue),
    #   or the plan: `relation:`, `library:`, `project:`, `effects:`
    def swap_plan(effective, lock:)
      relation = (lock ? MemoryRelation.lock : MemoryRelation).find_by(id: effective[:relation_id].to_i)
      stale = swap_stale(relation, effective)
      return stale if stale

      library = relation.from_entity
      project = relation.to_entity
      refusal = swap_refusal(library)
      return refusal if refusal

      existing = MemoryRelation.exists?(from_entity_id: project.id, to_entity_id: library.id, relation_type: NEW_TYPE)
      { relation: relation, library: library, project: project, effects: [
        "Deletes '#{library.name}' part_of '#{project.name}' (##{relation.id})",
        existing ? "Keeps the existing '#{project.name}' depends_on '#{library.name}'" : "Creates '#{project.name}' depends_on '#{library.name}'",
        scope_effect(library, library.project_id)
      ] }
    end

    def swap_stale(relation, effective)
      id = effective[:relation_id]
      unless relation
        return { success: true, message: "Nothing to do: relation ##{id} is already swapped for a depends_on" } if swapped?(effective)

        return { success: false, error: "Cannot swap relation ##{id}: it no longer exists; dismiss this row" }
      end
      unless MemoryRelation.reads_as_part_of?(relation.relation_type)
        return { success: false, error: "Cannot swap relation ##{id}: it is #{relation.relation_type} now, no longer part_of; dismiss this row" }
      end
      return nil if relation.to_entity&.project_root?

      { success: false, error: "Cannot swap relation ##{id}: its parent is no longer a Project root; dismiss this row" }
    end

    # The part_of is gone, the payload's Project depends_on the payload's library, and the library has
    # no part_of to that Project again.
    def swapped?(effective)
      from = effective[:from_entity_id].to_i
      to = effective[:to_entity_id].to_i
      MemoryRelation.exists?(from_entity_id: to, to_entity_id: from, relation_type: NEW_TYPE) &&
        !MemoryRelation.exists?(from_entity_id: from, to_entity_id: to, relation_type: RelationTypeSweep::PART_OF)
    end

    # A name the library's subtree would take in the global scope, read before anything is written.
    def swap_refusal(library)
      subtree_ids = [ library.id ] + ProjectMembership.member_ids(library.id).to_a
      namesake = MemoryEntity.where(project_id: nil, name: library.name).where.not(id: subtree_ids).first
      return library_collision(library, namesake) if namesake

      child = ProjectMembership.collision_name(library, nil, subtree_ids: subtree_ids)
      return nil unless child

      { refusal: "Cannot swap '#{library.name}' out of its project: its child '#{child}' has a name already taken in the " \
                 "global scope. Rename or move that child first, then apply this row again" }
    end

    def library_collision(library, namesake)
      if namesake.entity_type == library.entity_type
        return { refusal: "Cannot swap '#{library.name}' out of its project: a global #{namesake.entity_type} '#{namesake.name}' " \
                          "(##{namesake.id}) already has its name. An entity_merge suggestion (the global one into this one) " \
                          "is queued: merge them, then apply this row again", merge: [ namesake, library ] }
      end

      { refusal: "Cannot swap '#{library.name}' out of its project: a global #{namesake.entity_type} '#{namesake.name}' " \
                 "(##{namesake.id}) already has its name, and a merge needs one type. Rename or retype one of them first" }
    end

    def swap!(relation, library, project)
      created = nil
      ProjectMembership.with_membership_lock do
        ActiveRecord::Base.transaction(requires_new: true) do
          Current.set(deletion_reason: DELETION_REASON) { relation.destroy! }
          created = MemoryRelation.find_by(from_entity_id: project.id, to_entity_id: library.id, relation_type: NEW_TYPE) ||
                    MemoryRelation.create!(from_entity_id: project.id, to_entity_id: library.id, relation_type: NEW_TYPE)
          ProjectMembership.sync!(library)
        end
      end
      effect = scope_effect(library, project.id)
      { success: true, message: "Relation ##{relation.id} '#{library.name}' part_of '#{project.name}' swapped for " \
                                "'#{project.name}' depends_on '#{library.name}' (##{created.id}); #{effect}" }
    end

    # Seeds the entity_merge suggestion unless it is pending or was dismissed (seed_report checks
    # both). The global namesake merges into the project's library, not the other way round: the
    # survivor keeps the library's part_of (this row's edge) and takes the namesake's edges (the
    # other projects' depends_on) and children, so the swap applies next with no name left to
    # collide. The other way, the global target would take the library's parent and move into the
    # project while the library still holds the name there, which the merge refuses.
    #
    # R1b-2: the namesake's children would move into the project with it, so a same-named,
    # same-type pair across the two part_of subtrees (an imported copy of a library and its
    # children, for one) would refuse that merge. Each such pair gets its own entity_merge, the
    # namesake's child into the library's, to apply first: then the library merge and the swap.
    def queue_merge(pair)
      source, target = pair
      items = [ merge_item(source, target, "Same name: '#{target.name}' can't leave its project for the global scope " \
                                           "(relation_retype swap) while the global '#{source.name}' (##{source.id}) exists. Merging " \
                                           "the global one into it, then applying the swap, leaves one global node that every project depends_on") ]
      items += child_pairs(source, target).map do |theirs, ours|
        merge_item(theirs, ours, "Same name under two same-named libraries: '#{theirs.name}' under the global '#{source.name}' " \
                                 "(##{source.id}) and under '#{target.name}' (##{target.id}). Merge it first: the merge of the two " \
                                 "libraries moves the global one's children into the project, where this name is taken")
      end
      CompactionReviewService.seed_report(report_type: RelationTypeSweep::REVIEW_REPORT_TYPE, source: MERGE_SOURCE, items: items)
    end

    def merge_item(source, target, reason)
      { id: SecureRandom.uuid, kind: "entity_merge",
        entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
        entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type },
        recommendation: "review_manually", reason: reason }
    end

    # @return [Array<Array(MemoryEntity, MemoryEntity)>] [namesake's member, library's member] pairs
    #   with one name (case-insensitively) and one type, across the two part_of subtrees
    def child_pairs(namesake, library)
      ours = MemoryEntity.where(id: ProjectMembership.member_ids(library.id).to_a).index_by { |entity| [ entity.name.downcase, entity.entity_type ] }
      MemoryEntity.where(id: ProjectMembership.member_ids(namesake.id).to_a).order(:id).filter_map do |theirs|
        match = ours[[ theirs.name.downcase, theirs.entity_type ]]
        [ theirs, match ] if match
      end
    end

    # --- add -------------------------------------------------------------------------------------

    def apply_add(effective)
      plan = add_plan(effective)
      return plan if plan.key?(:success)
      return { success: false, error: plan[:refusal] } if plan[:refusal]

      edge = MemoryRelation.create!(from_entity_id: plan[:project].id, to_entity_id: plan[:entity].id, relation_type: NEW_TYPE)
      { success: true, message: "Created '#{plan[:project].name}' depends_on '#{plan[:entity].name}' (##{edge.id}); no membership change" }
    end

    def add_plan(effective)
      ids = [ effective[:from_entity_id].to_i, effective[:to_entity_id].to_i ]
      found = MemoryEntity.where(id: ids).index_by(&:id)
      project, entity = found.values_at(*ids)
      gone = ids.find { |id| !found.key?(id) }
      return { success: false, error: "Cannot add the depends_on: entity ##{gone} no longer exists; dismiss this row" } if gone
      return { success: false, error: "Cannot add the depends_on: '#{project.name}' is no longer a Project root; dismiss this row" } unless project.project_root?
      if MemoryRelation.exists?(from_entity_id: project.id, to_entity_id: entity.id, relation_type: NEW_TYPE)
        return { success: true, message: "Nothing to do: '#{project.name}' depends_on '#{entity.name}' exists" }
      end

      { project: project, entity: entity, effects: [ "Creates '#{project.name}' depends_on '#{entity.name}'",
                                                     "No membership change: '#{entity.name}' keeps #{Preview.project_label(entity.project_id)}" ] }
    end

    def label(effective)
      effective[:operation].to_s == SWAP ? "Cannot swap relation ##{effective[:relation_id]}" : "Cannot add the depends_on"
    end
  end
end
