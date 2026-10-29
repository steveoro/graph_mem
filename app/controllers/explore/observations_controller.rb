# frozen_string_literal: true

module Explore
  # The panel's observation forms: add (with the duplicate and similarity checks), edit
  # (supersede, history kept), retire (mark obsolete) and mark / unmark as source fact.
  class ObservationsController < BaseController
    # POST /explore/entities/:entity_id/observations(?force=1)
    def create
      entity = find_entity(params[:entity_id])
      values = observation_params.to_h
      result = edits.add_observation(entity, content: values["content"], perspective: values["perspective"], force: params[:force] == "1")
      respond_with_explore(result, entity: entity, panel_state: { form: "observation_new", values: values })
    end

    # PATCH /explore/observations/:id
    def update
      observation = find_observation
      values = observation_params.to_h
      result = edits.update_observation(observation, content: values["content"], perspective: values["perspective"])
      respond_with_explore(result, entity: observation.memory_entity, panel_state: { form: "observation_#{observation.id}", values: values })
    end

    # POST /explore/observations/:id/retire
    def retire
      observation = find_observation
      result = edits.retire_observation(observation, reason: params[:reason])
      respond_with_explore(result, entity: observation.memory_entity)
    end

    # POST /explore/observations/:id/fact (mark=1 marks the source fact, mark=0 unmarks it)
    def fact
      observation = find_observation
      result = edits.mark_fact(observation, mark: params[:mark] == "1")
      respond_with_explore(result, entity: observation.memory_entity)
    end

    private

    def find_observation
      id = EntityIdList.id(params[:id].to_s)
      raise ActiveRecord::RecordNotFound, "Observation not found" unless id

      MemoryObservation.find(id)
    end

    def observation_params
      params.fetch(:observation, {}).permit(:content, :perspective)
    end
  end
end
