# frozen_string_literal: true

module Projects
  # Background jobs (UI-6 Decision 1): the dream-state compactor, garbage collector and
  # relation-repair controls that sat on the Maintenance hub, as they were. UI-7 may move the page
  # under System. The buttons post to Operator::MaintenanceController, which redirects back here.
  class JobsController < BaseController
    self.nav_section = :jobs

    # GET /projects/jobs
    def index
      @snapshot = MaintenanceDashboardSnapshot.call
    end
  end
end
