# frozen_string_literal: true

class CompactionReviewApplier
  # Applies a `fact_supersede` review row ("Outdated by a fact", fact supersede F4) inside the
  # review.apply change set: the observation is superseded by a replacement text, or retired,
  # and records the fact in `outdated_by` (undone by ChangeSetUndo::AuditInverse).
  #
  # Re-checked at apply, whatever the row says: the fact is still an active source fact, the
  # observation is still active and in the fact's project (or an entity without a project
  # related to the fact's entity: applied by hand only, without outdated_by, since that link is
  # same-project only), and the legacy guard still doesn't say "keep".
  #
  #   FactSupersede.apply(effective, { fact_action: "supersede", replacement: "The MCP server uses the mcp gem." })
  #   # => { success: true, message: "Superseded observation #15 (outdated by source fact #12)" }
  #
  # Without `fact_action`, a row with a replacement is superseded and one without is retired;
  # `fact_action: "supersede"` without any replacement uses the fact's text.
  module FactSupersede
    ACTIONS = %w[supersede retire].freeze

    # @!attribute fact [MemoryObservation, nil]
    # @!attribute observation [MemoryObservation, nil]
    # @!attribute action [String] "supersede" or "retire"
    # @!attribute replacement [String, nil]
    # @!attribute scoped [Boolean] the observation is in the fact's project
    # @!attribute error [String, nil] why it can't be applied
    # @!attribute warnings [Array<String>]
    Plan = Struct.new(:fact, :observation, :action, :replacement, :scoped, :error, :warnings, keyword_init: true)

    module_function

    # @param effective [Hash] the row's effective payload (indifferent access)
    # @param action_params [Hash, ActionController::Parameters] optional fact_action, replacement
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective, action_params)
      plan = plan(effective, action_params)
      return { success: false, error: plan.error } if plan.error

      reason = "Outdated by source fact ##{plan.fact.id}#{' (entity outside the project)' unless plan.scoped}"
      outdated_by = plan.scoped ? plan.fact : nil
      if plan.action == "supersede"
        replacement = plan.observation.supersede!({ content: plan.replacement }, reason: reason, outdated_by: outdated_by)
        { success: true, message: "Superseded observation ##{plan.observation.id} with ##{replacement.id} (outdated by source fact ##{plan.fact.id})" }
      else
        plan.observation.mark_obsolete!(reason: reason, outdated_by: outdated_by)
        { success: true, message: "Retired observation ##{plan.observation.id} (outdated by source fact ##{plan.fact.id})" }
      end
    end

    # @return [Hash] `{ ok:, effects:, warnings:, undo: }` (see Preview)
    def preview(effective, action_params)
      plan = plan(effective, action_params)
      return Preview.result(false, warnings: [ plan.error, *plan.warnings ]) if plan.error

      effect = plan.action == "supersede" ? "Supersedes ##{plan.observation.id} with: “#{plan.replacement.truncate(200)}”" : "Retires ##{plan.observation.id}"
      Preview.result(true, effects: [ effect, "Records source fact ##{plan.fact.id} as what outdated it" ], warnings: plan.warnings)
    end

    # @return [Plan]
    def plan(effective, action_params)
      params = action_params.respond_to?(:to_unsafe_h) ? action_params.to_unsafe_h : action_params.to_h
      params = params.with_indifferent_access
      fact = MemoryObservation.find_by(id: effective[:fact_observation_id].to_i)
      observation = MemoryObservation.includes(:memory_entity).find_by(id: effective[:observation_id].to_i)
      replacement = (params[:replacement].presence || effective[:replacement]).to_s.strip.presence
      action = params[:fact_action].presence || (replacement ? "supersede" : "retire")
      # Asked to supersede without a text: the fact's own text is the replacement.
      replacement ||= fact&.content if action == "supersede"
      plan = Plan.new(fact: fact, observation: observation, action: action, replacement: replacement, warnings: [])
      plan.error = refusal(plan)
      plan
    end

    def refusal(plan)
      fact = plan.fact
      observation = plan.observation
      return "Choose supersede or retire" unless ACTIONS.include?(plan.action)
      return "Source fact ##{fact&.id || '?'} is no longer an active source fact; dismiss this row" unless fact&.source_fact?
      return "Observation is no longer active; dismiss this row or restore it first" unless observation&.active?

      plan.scoped = observation.fact_project_id == fact.fact_project_id
      return "The observation is in another project; a fact never outdates another project" unless plan.scoped || unscoped_neighbour?(fact, observation)
      return "Give the replacement text, or retire instead" if plan.action == "supersede" && plan.replacement.blank?
      if plan.replacement.to_s.length > ExploreEdits::Observations::MAX_OBSERVATION_LENGTH
        return "The replacement is too long (at most #{ExploreEdits::Observations::MAX_OBSERVATION_LENGTH} characters)"
      end

      guard, why = ::FactSupersede::LegacyGuard.new(fact).check(observation)
      return "Kept: the observation #{why}" if guard == ::FactSupersede::LegacyGuard::KEEP

      plan.warnings << "Check the context: the observation #{why}" if guard
      plan.warnings << "The entity has no project: the fact isn't authoritative for it" unless plan.scoped
      nil
    end

    def unscoped_neighbour?(fact, observation)
      entity = observation.memory_entity
      return false if entity.project_id || entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      MemoryRelation.where(from_entity_id: fact.memory_entity_id, to_entity_id: entity.id)
                    .or(MemoryRelation.where(from_entity_id: entity.id, to_entity_id: fact.memory_entity_id)).exists?
    end
  end
end
