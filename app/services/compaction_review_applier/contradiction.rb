# frozen_string_literal: true

class CompactionReviewApplier
  # Applies a `contradiction` review row (UI-5a): the operator (or an agent) keeps one of the two
  # observations and the other is marked obsolete. Nothing is created, moved or merged, and the
  # kept observation isn't touched, so the apply is one audited update, undone by the existing
  # review.apply change set (ChangeSetUndo::AuditInverse re-activates the observation).
  #
  #   Contradiction.apply(effective_payload, { keep_observation_id: 12 })
  #   # => { success: true, message: "Kept observation #12; marked #15 obsolete" }
  #
  # With `resolution: :supersede` (1.92.0, the AutoApplyContradiction policy only: a Ruby keyword,
  # never read from action_params) the other side is marked superseded by the kept one instead,
  # with the link set; both must be on one entity.
  #
  #   Contradiction.apply(effective_payload, { keep_observation_id: 15 }, resolution: :supersede)
  #   # => { success: true, message: "Kept observation #15; #12 superseded by it" }
  module Contradiction
    module_function

    # @param effective [Hash] the row's effective payload (indifferent access)
    # @param action_params [Hash, ActionController::Parameters] must carry keep_observation_id
    # @param resolution [Symbol] :obsolete (default) or :supersede
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective, action_params, resolution: :obsolete)
      pair = [ effective[:observation_id_1], effective[:observation_id_2] ].map(&:to_i).sort
      keep_id = keep_id(action_params)
      return { success: false, error: "Choose which observation to keep (##{pair.first} or ##{pair.last})" } unless pair.include?(keep_id)

      kept, retired = MemoryObservation.where(id: pair).index_by(&:id).values_at(keep_id, (pair - [ keep_id ]).first)
      unless kept&.active?
        return { success: false, error: "Observation ##{keep_id} is no longer active; dismiss this row or restore it first" }
      end
      return { success: true, message: "Observation ##{pair.find { |id| id != keep_id }} is already inactive" } unless retired&.active?

      return supersede(kept, retired) if resolution == :supersede

      retired.mark_obsolete!(reason: "Contradicted by observation ##{keep_id} (contradiction review)")
      { success: true, message: "Kept observation ##{keep_id}; marked ##{retired.id} obsolete" }
    end

    # The older fact is superseded by the newer one, with the changed value in the reason.
    def supersede(kept, retired)
      unless kept.memory_entity_id == retired.memory_entity_id
        return { success: false, error: "Observations ##{kept.id} and ##{retired.id} are on two entities; one can't supersede the other" }
      end

      change = ContradictionDetector.value_change(retired, kept)
      detail = change ? "value change: #{change[:from]} → #{change[:to]}" : "contradiction review"
      retired.supersede_with!(kept, reason: "Superseded by observation ##{kept.id} (#{detail})")
      { success: true, message: "Kept observation ##{kept.id}; ##{retired.id} superseded by it" }
    end

    def keep_id(action_params)
      params = action_params.respond_to?(:to_unsafe_h) ? action_params.to_unsafe_h : action_params.to_h
      params.with_indifferent_access[:keep_observation_id].to_i
    end
  end
end
