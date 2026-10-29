# frozen_string_literal: true

module System
  # System › Health (UI-7 S5): one row per check, and the raw snapshots collapsed (§2.7
  # "Diagnostics"). GET /system/health.json is the same checks as words, with no path, URL or
  # host name; operator only like the page (uptime monitors use /up).
  class HealthController < BaseController
    self.nav_section = :health

    # GET /system/health(.json)
    def show
      @health = SystemHealth.new
      respond_to do |format|
        format.html
        format.json { render json: @health.as_json }
      end
    end
  end
end
