# frozen_string_literal: true

module System
  # System › Access (UI-7 S6): who can get in. Status rows (operator credentials, the guest, the
  # MCP token, the session lifetimes) as configured / not configured, never a value; then the
  # guest toggle and the three MCP allowlists (SettingsSchema's access group). `update` runs the
  # MCP checks and applies them without a restart (SettingsGroupUpdate).
  class AccessController < BaseController
    include SettingsGroupUpdate

    self.nav_section = :access

    # GET /system/access
    def show
      AppSettings.clear_cache
      load_page
    end

    # PATCH /system/access
    def update
      load_page
      return redirect_to(system_access_path) if save_settings_group(@group)

      render :show, status: :unprocessable_content
    end

    private

    def load_page
      @group = SettingsSchema.group(:access)
      @rows = access_rows
    end

    # @return [Array<Hash>] `{ key:, status:, value: }` per row (status as in HomeSnapshot::Health)
    def access_rows
      operator = GraphMem::OperatorCredentials.status
      guest = GraphMem::GuestCredentials.current.status
      token = GraphMem::OfficialMcp.access_policy.token_required?
      [
        { key: :operator, status: operator == :configured ? :ok : :danger, value: t("system.access.operator.#{operator}") },
        { key: :guest, status: { available: :ok, conflict: :danger }.fetch(guest, :neutral), value: t("system.access.guest.#{guest}") },
        { key: :mcp_token, status: token ? :ok : :neutral, value: t("system.access.mcp_token.#{token ? 'required' : 'not_required'}") },
        { key: :sessions, status: :neutral, value: session_lifetimes }
      ]
    end

    def session_lifetimes
      t("system.access.sessions_value", operator_idle: SessionAuthentication::OPERATOR_IDLE_TIMEOUT.inspect,
                                        operator_absolute: SessionAuthentication::OPERATOR_ABSOLUTE_TIMEOUT.inspect,
                                        guest_idle: SessionAuthentication::GUEST_IDLE_TIMEOUT.inspect,
                                        guest_absolute: SessionAuthentication::GUEST_ABSOLUTE_TIMEOUT.inspect)
    end
  end
end
