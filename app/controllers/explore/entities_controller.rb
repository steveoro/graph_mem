# frozen_string_literal: true

module Explore
  # PATCH /explore/entities/:id (the panel's edit form) and POST .../propose_deletion (W7).
  class EntitiesController < BaseController
    def update
      entity = find_entity(params[:id])
      values = entity_params.to_h
      result = edits.update_entity(entity, values)
      respond_with_explore(result, entity: entity, panel_state: { form: "entity", values: values })
    end

    # POST /explore/entities/:id/propose_deletion (reason optional)
    def propose_deletion
      entity = find_entity(params[:id])
      result = edits.propose_deletion(entity, reason: params[:reason])
      flash_link = result[:review_row_uuid] && { "href" => review_row_path(result[:review_row_uuid]), "label" => t("explore.panel.open_review_row") }
      respond_with_explore(result, entity: entity, link: flash_link)
    end

    private

    def entity_params
      params.fetch(:entity, {}).permit(:name, :entity_type, :aliases, :description)
    end
  end
end
