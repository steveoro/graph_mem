# frozen_string_literal: true

class CompactionReviewApplier
  # Applies a `contradiction` review row (UI-5a): the operator (or an agent) keeps one of the two
  # observations and the other is marked obsolete. Nothing is created, moved or merged, and the
  # kept observation isn't touched, so the apply is one audited update, undone by the existing
  # review.apply change set (ChangeSetUndo::AuditInverse re-activates the observation).
  #
  #   Contradiction.apply(effective_payload, { keep_observation_id: 12 })
  #   # => { success: true, message: "Kept observation #12; marked #15 obsolete" }
  module Contradiction
    module_function

    # @param effective [Hash] the row's effective payload (indifferent access)
    # @param action_params [Hash, ActionController::Parameters] must carry keep_observation_id
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective, action_params)
      pair = [ effective[:observation_id_1], effective[:observation_id_2] ].map(&:to_i).sort
      keep_id = keep_id(action_params)
      return { success: false, error: "Choose which observation to keep (##{pair.first} or ##{pair.last})" } unless pair.include?(keep_id)

      kept, retired = MemoryObservation.where(id: pair).index_by(&:id).values_at(keep_id, (pair - [ keep_id ]).first)
      unless kept&.active?
        return { success: false, error: "Observation ##{keep_id} is no longer active; dismiss this row or restore it first" }
      end
      return { success: true, message: "Observation ##{pair.find { |id| id != keep_id }} is already inactive" } unless retired&.active?

      retired.mark_obsolete!(reason: "Contradicted by observation ##{keep_id} (contradiction review)")
      { success: true, message: "Kept observation ##{keep_id}; marked ##{retired.id} obsolete" }
    end

    def keep_id(action_params)
      params = action_params.respond_to?(:to_unsafe_h) ? action_params.to_unsafe_h : action_params.to_h
      params.with_indifferent_access[:keep_observation_id].to_i
    end
  end
end
