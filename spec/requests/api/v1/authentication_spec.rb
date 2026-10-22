# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 authentication (UI-0, F2)", type: :request do
  # A simple read endpoint that was previously unauthenticated.
  let(:path) { "/api/v1/memory_entities" }

  describe "no credentials" do
    it "returns 401 with WWW-Authenticate header" do
      get path
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to match(/Bearer/)
    end
  end

  describe "operator browser session" do
    it "allows access" do
      sign_in_operator
      get path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "Bearer token" do
    let(:token) { "test-api-token-#{SecureRandom.hex(8)}" }

    before { ENV["GRAPH_MEM_MCP_TOKEN"] = token }
    after  { ENV.delete("GRAPH_MEM_MCP_TOKEN") }

    context "with a private-range source IP (allowed by McpAccessPolicy default)" do
      it "allows access" do
        get path, headers: { "Authorization" => "Bearer #{token}", "REMOTE_ADDR" => "127.0.0.1" }
        expect(response).to have_http_status(:ok)
      end
    end

    context "with a public IP and no GRAPH_MEM_MCP_ALLOWED_IPS set" do
      before { ENV.delete("GRAPH_MEM_MCP_ALLOWED_IPS") }

      it "returns 401 (IP not in allowlist)" do
        get path, headers: { "Authorization" => "Bearer #{token}", "REMOTE_ADDR" => "1.2.3.4" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a wrong token" do
      it "returns 401" do
        get path, headers: { "Authorization" => "Bearer wrong-token", "REMOTE_ADDR" => "127.0.0.1" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "no token configured and a private-range IP and no session" do
    before  { ENV.delete("GRAPH_MEM_MCP_TOKEN") }

    it "returns 401 (no bearer path available)" do
      get path, headers: { "REMOTE_ADDR" => "127.0.0.1" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
