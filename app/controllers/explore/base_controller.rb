# frozen_string_literal: true

module Explore
  # Explore's write controllers (UI-4b): operator only (no allow_guest, so a guest gets 403 from
  # every action), CSRF-protected like every ApplicationController form, each edit in its own
  # `explore.*` change set with Current.actor (operator:<user>@<ip>).
  class BaseController < ApplicationController
    include ExploreResponses

    layout -> { turbo_frame_request? ? false : "application" }

    private

    def edits
      @edits ||= ExploreEdits.new
    end

    # @return [MemoryEntity] raises RecordNotFound (404) for anything but a known id
    def find_entity(raw)
      id = EntityIdList.id(raw.to_s)
      raise ActiveRecord::RecordNotFound, "Entity not found" unless id

      MemoryEntity.find(id)
    end
  end
end
