# frozen_string_literal: true

class CompactionReviewApplier
  # Repairs a `lifecycle_corruption` review row (1.86.0), queued by the integrity sweep
  # (GraphIntegrityService#detect_observation_lifecycle_corruption). The row's `issue` is only what
  # the sweep saw: the live observation is re-read, and the issue it still has is repaired with one
  # audited update inside the review.apply change set, so Undo restores the previous state
  # (ChangeSetUndo::AuditInverse, which may write back an inconsistent lifecycle on purpose).
  #
  # - superseded without superseded_by: points it at its `outdated_by` when that is active and on the
  #   same entity (what a fact supersede with the fact's own text meant), else marks it obsolete,
  #   keeping obsoleted_at, its reason and outdated_by;
  # - active with obsoleted_at: clears obsoleted_at and the stale obsolescence_reason (and any
  #   superseded_by or outdated_by, which an active row can't have either);
  # - superseded_by on another entity: refused, the operator dismisses the row.
  #
  #   LifecycleCorruption.apply({ observation_id: 4217 }, {})
  #   # => { success: true, message: "Observation #4217 now superseded by #4227 (its outdated_by)" }
  module LifecycleCorruption
    ACTIVE_WITH_OBSOLETED_AT = "active observation has obsoleted_at set"
    SUPERSEDED_WITHOUT_LINK = "superseded observation has no superseded_by reference"
    CROSS_ENTITY_LINK = "superseded_by references a different entity"
    ALREADY_CONSISTENT = "already consistent"

    # @!attribute observation [MemoryObservation, nil]
    # @!attribute issue [String, nil] the issue the live observation still has (one of the constants)
    # @!attribute changes [Hash] the attributes Repair writes ({} when there's nothing to write)
    # @!attribute effect [String] what Repair does, for messages and the preview
    # @!attribute error [String, nil] why it can't be repaired
    Plan = Struct.new(:observation, :issue, :changes, :effect, :error, keyword_init: true)

    module_function

    # @param effective [Hash] the row's effective payload (indifferent access): observation_id
    # @param _action_params [Hash] unused (Repair takes no choice)
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective, _action_params = {})
      observation = MemoryObservation.find_by(id: effective[:observation_id].to_i)
      return { success: false, error: "Observation ##{effective[:observation_id]} is gone; dismiss this row" } unless observation

      # Re-planned under the lock, so a write that landed after the preview is never overwritten.
      observation.lock!
      plan = plan_for(observation)
      return { success: false, error: plan.error } if plan.error
      return { success: true, message: plan.effect } if plan.changes.empty?

      observation.update!(plan.changes)
      { success: true, message: plan.effect }
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "Failed to repair observation ##{observation&.id}: #{e.message}" }
    end

    # @return [Hash] `{ ok:, effects:, warnings:, undo: }` (see Preview)
    def preview(effective, _action_params = {})
      observation = MemoryObservation.find_by(id: effective[:observation_id].to_i)
      return Preview.result(false, warnings: [ "Observation ##{effective[:observation_id]} is gone" ]) unless observation

      plan = plan_for(observation)
      return Preview.result(false, warnings: [ plan.error ]) if plan.error

      Preview.result(true, effects: [ plan.effect ])
    end

    # @param observation [MemoryObservation]
    # @return [String, nil] the lifecycle issue the observation has now, nil when it is consistent
    def live_issue(observation)
      return ACTIVE_WITH_OBSOLETED_AT if observation.active? && observation.obsoleted_at.present?
      return SUPERSEDED_WITHOUT_LINK if observation.superseded? && observation.superseded_by_id.nil?
      return CROSS_ENTITY_LINK if observation.superseded_by_id && observation.superseded_by&.memory_entity_id != observation.memory_entity_id

      nil
    end

    # @param observation [MemoryObservation]
    # @return [Plan]
    def plan_for(observation)
      plan = Plan.new(observation: observation, issue: live_issue(observation), changes: {})
      case plan.issue
      when ACTIVE_WITH_OBSOLETED_AT then plan_active(plan)
      when SUPERSEDED_WITHOUT_LINK then plan_unlinked(plan)
      when CROSS_ENTITY_LINK
        target = observation.superseded_by
        plan.error = "Observation ##{observation.id} is superseded by ##{target&.id} on another entity " \
                     "(##{target&.memory_entity_id}); there's no automatic repair. Dismiss this row, or fix it by hand"
      else
        plan.effect = "Observation ##{observation.id} is #{ALREADY_CONSISTENT}; nothing to repair"
      end
      plan
    end

    def plan_active(plan)
      observation = plan.observation
      plan.changes = { obsoleted_at: nil, obsolescence_reason: nil }
      plan.changes[:superseded_by_id] = nil if observation.superseded_by_id
      plan.changes[:outdated_by_id] = nil if observation.outdated_by_id
      plan.effect = "Clears obsoleted_at#{' and the obsolete reason' if observation.obsolescence_reason} " \
                    "of active observation ##{observation.id}"
      plan.effect += " (and its superseded_by/outdated_by link)" if plan.changes.key?(:superseded_by_id) || plan.changes.key?(:outdated_by_id)
    end

    def plan_unlinked(plan)
      observation = plan.observation
      fact = observation.outdated_by
      # An inactive row needs obsoleted_at: a row that lost it too gets it now.
      plan.changes[:obsoleted_at] = Time.current if observation.obsoleted_at.blank?
      if fact&.active? && fact.memory_entity_id == observation.memory_entity_id && fact.id != observation.id
        plan.changes[:superseded_by_id] = fact.id
        plan.effect = "Sets superseded_by of ##{observation.id} to ##{fact.id} (its outdated_by, active on the same entity)"
      else
        plan.changes[:status] = MemoryObservation::OBSOLETE_STATUS
        plan.effect = "Marks ##{observation.id} obsolete (no active same-entity outdated_by to point superseded_by at); " \
                      "keeps obsoleted_at, its reason and outdated_by"
      end
    end
  end
end
