# frozen_string_literal: true

module System
  # Host-app base controller for MissionControl::Jobs::Engine, mounted at /system/queue
  # (config.mission_control.jobs.base_controller_class). Operator only, like the rest of System.
  class QueueDashboardController < BaseController
    self.nav_section = :queue
  end
end
