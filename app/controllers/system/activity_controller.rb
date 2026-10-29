# frozen_string_literal: true

module System
  # System › Activity (UI-7 S6): every recorded change set, newest first, with Undo while it is
  # undoable (ChangesController#undo). The row-level history is the Audit log.
  class ActivityController < BaseController
    self.nav_section = :activity

    PER_PAGE = 50

    # GET /system/activity
    def index
      @change_sets = ChangeSet.order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end
  end
end
