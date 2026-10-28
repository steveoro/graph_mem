# frozen_string_literal: true

require "rails_helper"

# Guests share one search budget per IP across the HTML and API search actions (UI-1b).
RSpec.describe "Guest search throttle", type: :request do
  let(:limit) { GuestSearchThrottle::LIMIT }
  let(:json) { { "Accept" => "application/json" } }

  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  context "as a guest" do
    before do
      enable_guest!
      sign_in_guest
    end

    it "allows the limit, then answers the HTML search with 429" do
      limit.times do
        get search_path, params: { q: "SynthWidget" }
        expect(response).to have_http_status(:ok)
      end

      get search_path, params: { q: "SynthWidget" }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include('data-testid="guest-search-throttled"')
      expect(response.headers["Retry-After"]).to eq(GuestSearchThrottle::PERIOD.to_i.to_s)
    end

    it "counts a Search page view once, with filters, and not its panel or Show as graph data" do
      (limit - 1).times { get search_path, params: { q: "SynthWidget" } }
      get search_path, params: { q: "SynthWidget", types: [ "Component" ], match: [ "", "name" ] }
      expect(response).to have_http_status(:ok)

      get entity_panel_path(widget), headers: { "Turbo-Frame" => "entity-panel" }
      expect(response).to have_http_status(:ok)
      get "/api/v1/graph_data", params: { ids: widget.id.to_s }, headers: json
      expect(response).to have_http_status(:ok)

      get search_path, params: { q: "SynthWidget" }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "counts entity reads ranked by a query, but not plain entity reads" do
      limit.times { get search_path, params: { q: "SynthWidget" } }

      get "/api/v1/memory_entities/#{widget.id}", headers: json
      expect(response).to have_http_status(:ok)

      get "/api/v1/memory_entities/#{widget.id}", params: { query: "tiles" }, headers: json
      expect(response).to have_http_status(:too_many_requests)
    end

    it "caps all guests together, whatever IP they come from" do
      (GuestSearchThrottle::GLOBAL_LIMIT / limit).times do |i|
        limit.times do
          get search_path, params: { q: "SynthWidget" }, env: { "REMOTE_ADDR" => "10.0.0.#{i + 1}" }
          expect(response).to have_http_status(:ok)
        end
      end

      get search_path, params: { q: "SynthWidget" }, env: { "REMOTE_ADDR" => "10.0.1.1" }

      expect(response).to have_http_status(:too_many_requests)
    end

    it "shares the budget with the API search actions, which answer 429 JSON" do
      limit.times { get search_path, params: { q: "SynthWidget" } }

      get "/api/v1/memory_entities/search", params: { q: "SynthWidget" }, headers: json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body).to eq("error" => "rate_limited", "role" => "guest")

      get "/api/v1/search/subgraph", params: { q: "SynthWidget" }, headers: json
      expect(response).to have_http_status(:too_many_requests)
    end

    it "doesn't limit a guest request that carries a valid bearer token" do
      ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
      (limit + 1).times do
        get "/api/v1/memory_entities/search", params: { q: "SynthWidget" },
                                              headers: json.merge("Authorization" => "Bearer synthetic-token")
        expect(response).to have_http_status(:ok)
      end
    ensure
      ENV.delete("GRAPH_MEM_MCP_TOKEN")
    end
  end

  it "doesn't limit the operator" do
    sign_in_operator

    (limit + 1).times do
      get search_path, params: { q: "SynthWidget" }
      expect(response).to have_http_status(:ok)
    end
  end
end
