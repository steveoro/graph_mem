# frozen_string_literal: true

require "rails_helper"

# CSP is enforced since UI-1 (1.56.0): the header is Content-Security-Policy, never
# -Report-Only, and every <script> carries the request nonce.
RSpec.describe "Content Security Policy", type: :request do
  def required_directives
    [
      "script-src 'self' 'nonce-", "object-src 'none'", "frame-ancestors 'none'",
      "base-uri 'self'", "form-action 'self'", "report-uri /csp-reports"
    ]
  end

  def expect_enforced_policy
    policy = response.headers["Content-Security-Policy"]
    expect(policy).to be_present
    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_nil
    required_directives.each { |directive| expect(policy).to include(directive) }
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

    [ "/", "/search?q=SynthWidget", "/explore", "/projects", "/projects/scans/new", "/projects/imports/new", "/projects/exports",
      "/projects/jobs", "/operator/settings", "/operator/telemetry", "/review" ].each do |path|
      it "enforces the policy and nonces every script on #{path}" do
        get path

        expect(response).to have_http_status(:ok)
        expect_scripts_nonced(expect_enforced_policy)
      end
    end

    it "enforces the policy and nonces every script through the import review and report" do
      export = { version: "1.0", root_nodes: [ { name: "Alpha Service", entity_type: "Project", observations: [], children: [] } ] }
      upload = Rack::Test::UploadedFile.new(StringIO.new(export.to_json), "application/json", original_filename: "synthetic.json")
      post projects_imports_path, params: { file: upload }
      review = response.location

      get review
      expect(response).to have_http_status(:ok)
      expect_scripts_nonced(expect_enforced_policy)

      post "#{review}/execute", params: { decisions: { "0" => { node_path: "0", action: "create", target_id: "", parent_id: "" } } }
      get response.location
      expect(response).to have_http_status(:ok)
      expect_scripts_nonced(expect_enforced_policy)
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
