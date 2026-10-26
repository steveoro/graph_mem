# frozen_string_literal: true

require "rails_helper"

# CSP is enforced since UI-1 (1.56.0): the header is Content-Security-Policy, never
# -Report-Only, and every <script> carries the request nonce.
RSpec.describe "Content Security Policy", type: :request do
  REQUIRED_DIRECTIVES = [
    "script-src 'self' 'nonce-", "object-src 'none'", "frame-ancestors 'none'",
    "base-uri 'self'", "form-action 'self'", "report-uri /csp-reports"
  ].freeze

  def expect_enforced_policy
    policy = response.headers["Content-Security-Policy"]
    expect(policy).to be_present
    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_nil
    REQUIRED_DIRECTIVES.each { |directive| expect(policy).to include(directive) }
    policy
  end

  def expect_scripts_nonced(policy)
    nonce = policy[/'nonce-([^']+)'/, 1]
    scripts = Nokogiri::HTML(response.body).css("script")
    expect(scripts).not_to be_empty
    expect(scripts.map { |script| script["nonce"] }.uniq).to eq([ nonce ])
  end

  context "when signed in as operator" do
    before { sign_in_operator }

    [ "/", "/search?q=SynthWidget", "/graph", "/maintenance", "/operator/settings",
      "/operator/telemetry", "/data_exchange/compaction_review" ].each do |path|
      it "enforces the policy and nonces every script on #{path}" do
        get path

        expect(response).to have_http_status(:ok)
        expect_scripts_nonced(expect_enforced_policy)
      end
    end

    it "leaves rswag's own policy on /api-docs untouched" do
      get "/api-docs/index.html"

      expect(response).to have_http_status(:ok)
      policy = response.headers["Content-Security-Policy"]
      script_src = policy.split(";").map(&:strip).find { |d| d.start_with?("script-src") }
      expect(script_src).to include("'unsafe-inline'")
      # Only rswag's header: the app's nonce policy would block Swagger UI's inline scripts.
      expect(policy).not_to include("nonce-")
    end
  end

  it "enforces the policy on the sign-in page" do
    get operator_login_path

    expect(response).to have_http_status(:ok)
    expect_scripts_nonced(expect_enforced_policy)
  end
end
