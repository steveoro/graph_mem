# frozen_string_literal: true

# The read-only entity panel (UI-3 P4): Search's side frame, and a plain page outside a frame.
# Operators and guests; no write action or form for anyone. UI-4b reuses it.
class EntitiesController < ApplicationController
  allow_guest :panel

  layout -> { turbo_frame_request? ? false : "application" }

  # GET /entities/:id/panel(?obsolete=1&page=N)
  def panel
    entity = MemoryEntity.find_by(id: params[:id])
    return render(:missing, status: :not_found) unless entity

    @panel = EntityPanel.new(entity, include_obsolete: params[:obsolete] == "1", page: params[:page])
  end
end
