# frozen_string_literal: true

require "rails_helper"

# Test env disables forgery protection globally; turn it on so the matrix
# exercises the real CSRF check in Api::V1::BaseController.
RSpec.describe "API V1 CSRF protection (UI-0)", type: :request do
  let(:path)   { "/api/v1/memory_entities" }
  let(:params) { { memory_entity: { name: "CsrfProbe-#{SecureRandom.hex(4)}", entity_type: "Concept" } } }
  let(:token)  { "csrf-spec-token-#{SecureRandom.hex(8)}" }
  let(:bearer_headers) { { "Authorization" => "Bearer #{token}", "REMOTE_ADDR" => "127.0.0.1" } }

  before { ENV["GRAPH_MEM_MCP_TOKEN"] = token }

  after do
    ActionController::Base.allow_forgery_protection = false
    ENV.delete("GRAPH_MEM_MCP_TOKEN")
  end

  # Enabled only after sign-in: the login POST itself needs no CSRF token here.
  def enable_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  def csrf_token_from_session
    get root_path
    response.body[/name="csrf-token" content="([^"]+)"/, 1].tap { |t| expect(t).to be_present }
  end

  context "with an operator session" do
    before do
      sign_in_operator
      enable_forgery_protection
    end

    it "rejects a write without a CSRF token" do
      post path, params: params
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "accepts a write carrying a valid CSRF token" do
      post path, params: params, headers: { "X-CSRF-Token" => csrf_token_from_session }
      expect(response).to have_http_status(:created)
    end

    it "rejects a write with a junk Bearer header and no CSRF token" do
      post path, params: params, headers: { "Authorization" => "Bearer junk" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  context "with a valid Bearer token and no session" do
    before do
      reset!                      # drop the global auto sign-in
      enable_forgery_protection
    end

    it "accepts a write without a CSRF token" do
      post path, params: params, headers: bearer_headers
      expect(response).to have_http_status(:created)
    end
  end

  # mcp plan PR-2 §2.20 item 1: a refused bearer write with no session gets the auth answer
  # (401/403), not a CSRF 422 (fix in bbda8b9).
  context "with a refused Bearer token and no session" do
    before do
      reset!
      enable_forgery_protection
    end

    it "answers a junk Bearer write with 401 and WWW-Authenticate" do
      post path, params: params, headers: { "Authorization" => "Bearer junk-#{SecureRandom.hex(4)}", "REMOTE_ADDR" => "127.0.0.1" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")
    end

    it "answers a valid token from a public IP with 403" do
      post path, params: params, headers: bearer_headers.merge("REMOTE_ADDR" => "203.0.113.7")

      expect(response).to have_http_status(:forbidden)
    end
  end
end
