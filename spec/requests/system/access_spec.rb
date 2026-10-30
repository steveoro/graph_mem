# frozen_string_literal: true

require "rails_helper"

# UI-7 S6: System › Access. The status rows, the guest toggle, and (UI-2a A3) the MCP allowlists (operator only, validated, audited, applied without a restart).
# Synthetic values only: documentation IP ranges, *.test / *.localhost names.
RSpec.describe "System › Access", type: :request do
  env_keys = %w[GRAPH_MEM_MCP_ALLOWED_IPS GRAPH_MEM_MCP_ALLOWED_HOSTS GRAPH_MEM_MCP_ALLOWED_ORIGINS GRAPH_MEM_MCP_TOKEN]

  around do |example|
    saved = env_keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    env_keys.each { |key| ENV.delete(key) }
    GraphMem::OfficialMcp.reset!
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    GraphMem::OfficialMcp.reset!
  end

  def save(**settings)
    patch system_access_path, params: { tab: "access", settings: settings.transform_keys(&:to_s) }
  end

  def stored(key) = AppSettings.uncached_string(key)

  def audited_keys = AuditLog.where(auditable_type: "AppSettings").order(:id).map { |log| log.changed_fields.keys.sole }

  context "as the operator" do
    before { sign_in_operator }

    def access_row(key) = Nokogiri::HTML(response.body).at_css("[data-testid='access-#{key}']")

    it "shows the guest state for not configured, available, turned off and conflict" do
      get system_access_path
      expect(access_row(:guest).text).to include("not configured")

      enable_guest!
      get system_access_path
      expect(access_row(:guest)["data-status"]).to eq("ok")
      expect(access_row(:guest).text).to include("available")

      AppSettings.enable_guest_access = false
      get system_access_path
      expect(access_row(:guest).text).to include("turned off below")

      enable_guest!(username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME, password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD)
      get system_access_path
      expect(access_row(:guest)["data-status"]).to eq("danger")
      expect(access_row(:guest).text).to include("equals the operator's")
    ensure
      ENV.delete(GraphMem::GuestCredentials::PASSWORD_ENV)
      GraphMem::GuestCredentials.reset!
      AppSettings.where(var: "enable_guest_access").delete_all
    end

    it "shows credentials and the MCP token as configured or not, never their value" do
      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-mcp-token"
      GraphMem::OfficialMcp.reset!

      get system_access_path

      expect(access_row(:operator)["data-status"]).to eq("ok")
      expect(access_row(:operator).text).to include("configured")
      expect(access_row(:mcp_token).text).to include("needs the bearer token")
      expect(access_row(:sessions).text).to include("24 hours", "7 days", "2 hours")
      expect(response.body).not_to include("synthetic-mcp-token", OperatorAuthHelpers::TEST_OPERATOR_PASSWORD)
    end

    it "warns when the operator password is the default, and when production refuses it" do
      saved_password = ENV.delete("OPERATOR_PASSWORD")
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:operator, :password).and_return(nil)

      get system_access_path
      expect(access_row(:operator)["data-status"]).to eq("danger")
      expect(access_row(:operator).text).to include("the default password is in use")

      allow(Rails.env).to receive(:production?).and_return(true)
      get system_access_path
      expect(access_row(:operator)["data-status"]).to eq("danger")
      expect(access_row(:operator).text).to include("production refuses the default password")
      expect(response.body).not_to include(GraphMem::OperatorCredentials::FALLBACK_PASSWORD)
    ensure
      ENV["OPERATOR_PASSWORD"] = saved_password
    end

    it "saves the guest toggle, and keeps the old tab URLs working" do
      patch system_access_path, params: { tab: "access", settings: { enable_guest_access: "0" } }
      expect(response).to redirect_to(system_access_path)
      expect(AppSettings.guest_access_enabled?).to be(false)

      get system_settings_path(tab: "access")
      expect(response).to redirect_to(system_access_path)
    ensure
      AppSettings.where(var: "enable_guest_access").delete_all
    end

    it "saves each list normalized, with one audit row per changed key" do
      save(mcp_extra_allowed_ips: "192.168.0.21/24\n10.8.0.0/24", mcp_extra_allowed_hosts: "Synth-LAN.test, [fd00::1], localhost",
           mcp_extra_allowed_origins: "HTTP://Synth-UI.localhost:3002/")

      expect(response).to redirect_to(system_access_path)
      expect(stored("mcp_extra_allowed_ips")).to eq("192.168.0.0/24,10.8.0.0/24")
      expect(stored("mcp_extra_allowed_hosts")).to eq("synth-lan.test,fd00::1")
      expect(stored("mcp_extra_allowed_origins")).to eq("http://synth-ui.localhost:3002")
      expect(audited_keys).to contain_exactly("mcp_extra_allowed_ips", "mcp_extra_allowed_hosts", "mcp_extra_allowed_origins")
      expect(AuditLog.where(auditable_type: "AppSettings").map(&:actor)).to all(start_with("operator:"))
      expect(flash[:notice]).to include("host bits masked", "loopback names are always accepted", "trailing / removed")

      save(mcp_extra_allowed_ips: "192.168.0.0/24, 10.8.0.0/24", mcp_extra_allowed_hosts: "synth-lan.test,fd00::1",
           mcp_extra_allowed_origins: "http://synth-ui.localhost:3002")
      expect(audited_keys.size).to eq(3)
    end

    it "refuses every invalid entry with 422 and stores nothing" do
      [
        [ :mcp_extra_allowed_ips, "10.8.0.0/24, not-an-ip", "not-an-ip: isn't an IP address" ],
        [ :mcp_extra_allowed_hosts, "*.lan", "wildcards" ],
        [ :mcp_extra_allowed_hosts, "http://synth-lan.test", "without a scheme" ],
        [ :mcp_extra_allowed_hosts, "synth-lan.test/mcp", "may not contain a path" ],
        [ :mcp_extra_allowed_hosts, "synth-lan.test:70000", "optional :port" ],
        [ :mcp_extra_allowed_origins, "*", "isn't an origin" ],
        [ :mcp_extra_allowed_origins, "null", "isn't an origin" ],
        [ :mcp_extra_allowed_origins, "ftp://synth-ui.test", "only http and https" ],
        [ :mcp_extra_allowed_origins, "http://synth-ui.test/app", "no path" ],
        [ :mcp_extra_allowed_origins, "http://user@synth-ui.test", "user info" ]
      ].each do |key, input, message|
        save(**{ mcp_extra_allowed_hosts: "synth-lan.test" }, key => input)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(CGI.escapeHTML(message))
      end
      expect(GraphMem::McpAccessLists::SETTING_KEYS.values.map { |key| stored(key) }).to all(eq(""))
      expect(AuditLog.where(auditable_type: "AppSettings")).not_to exist
    end

    it "refuses any, all and * even with a token" do
      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"

      %w[any all *].each do |sentinel|
        save(mcp_extra_allowed_ips: sentinel)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("lifting the IP restriction is an ENV decision")
      end
      expect(stored("mcp_extra_allowed_ips")).to eq("")
    end

    it "refuses a public range without a token, and saves it with a warning with one" do
      save(mcp_extra_allowed_ips: "198.51.100.0/24")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("it needs GRAPH_MEM_MCP_TOKEN")
      expect(stored("mcp_extra_allowed_ips")).to eq("")

      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
      save(mcp_extra_allowed_ips: "198.51.100.0/24")

      expect(response).to redirect_to(system_access_path)
      expect(stored("mcp_extra_allowed_ips")).to eq("198.51.100.0/24")
      expect(flash[:notice]).to include("public range: reachable from outside your network")
      follow_redirect!
      expect(response.body).to include("198.51.100.0/24: public (token required).")
      expect(response.body).not_to include("Inactive: no token")
    end

    it "shows a stored public range as inactive once the token is removed" do
      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
      save(mcp_extra_allowed_ips: "198.51.100.0/24")
      ENV.delete("GRAPH_MEM_MCP_TOKEN")
      GraphMem::OfficialMcp.refresh_access!(transports: false)

      get system_access_path

      body = Nokogiri::HTML(response.body)
      expect(body.at_css("[data-testid='mcp-access-note-ips']").text).to include("Inactive: no token")
      expect(body.at_css("[data-testid='mcp-effective-ips']").text).not_to include("198.51.100.0/24")
    end

    it "shows the ENV value as read-only text that is never submitted, and drops ENV duplicates" do
      ENV["GRAPH_MEM_MCP_ALLOWED_HOSTS"] = "env-host.test"
      ENV["GRAPH_MEM_MCP_ALLOWED_ORIGINS"] = "http://env-ui.test/"

      get system_access_path

      body = Nokogiri::HTML(response.body)
      expect(body.at_css("[data-testid='mcp-env-hosts']").text).to include("env-host.test")
      expect(body.at_css("[data-testid='mcp-env-ips']").text).to include("unset (default: loopback + private ranges)")
      form = body.at_css("form[action='#{system_access_path}']")
      expect(form.css("input, textarea").filter_map { |input| input["name"] } - %w[_method authenticity_token commit tab])
        .to contain_exactly("settings[enable_guest_access]", "settings[enable_guest_access]", "settings[mcp_extra_allowed_ips]",
                            "settings[mcp_extra_allowed_hosts]", "settings[mcp_extra_allowed_origins]")
      expect(body.at_css("[data-testid='mcp-effective-hosts']").text).to include("env-host.test")
      expect(response.body).to include("ENV value never matches: http://env-ui.test/")
      expect(body.at_css("[data-testid='mcp-access-sessions-notice']").text).to include("closes every open MCP session")

      save(mcp_extra_allowed_hosts: "ENV-Host.test, synth-lan.test")

      expect(stored("mcp_extra_allowed_hosts")).to eq("synth-lan.test")
      expect(flash[:notice]).to include("env-host.test: already set in ENV")
      expect(GraphMem::OfficialMcp::Transports.allowed_hosts).to eq(%w[env-host.test synth-lan.test])
    end

    it "disables the IP additions when ENV allows any IP" do
      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
      ENV["GRAPH_MEM_MCP_ALLOWED_IPS"] = "any"
      GraphMem::OfficialMcp.refresh_access!(transports: false)

      get system_access_path

      expect(Nokogiri::HTML(response.body).at_css("input[name='settings[mcp_extra_allowed_ips]']")["disabled"]).to be_present
      expect(response.body).to include("additions have no effect")
    end

    it "rebuilds the transports only when hosts or origins change" do
      allow(GraphMem::OfficialMcp).to receive(:refresh_access!).and_call_original

      save(mcp_extra_allowed_ips: "10.8.0.0/24")
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).with(transports: false).once

      save(mcp_extra_allowed_ips: "10.8.0.0/24", mcp_extra_allowed_hosts: "synth-lan.test")
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).with(transports: true).once

      save(mcp_extra_allowed_origins: "http://synth-ui.localhost:3002")
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).with(transports: true).twice

      save(mcp_extra_allowed_origins: "http://synth-ui.localhost:3002")
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).exactly(3).times
    end
  end

  it "answers a guest with 403 and changes nothing" do
    enable_guest!
    sign_in_guest

    get system_access_path
    expect(response).to have_http_status(:forbidden)
    save(mcp_extra_allowed_hosts: "synth-lan.test", enable_guest_access: "0")
    expect(response).to have_http_status(:forbidden)
    expect(stored("mcp_extra_allowed_hosts")).to eq("")
    expect(AppSettings.guest_access_enabled?).to be(true)
  end

  it "sends a signed-out visitor to the sign-in page" do
    get system_access_path

    expect(response).to redirect_to(operator_login_path)
  end
end
