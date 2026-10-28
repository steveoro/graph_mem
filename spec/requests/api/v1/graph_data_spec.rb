# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Graph Data", type: :request do
  describe "GET /api/v1/graph_data" do
    it "counts active observations only" do
      entity = MemoryEntity.create!(name: "Lifecycle graph node", entity_type: "Project")
      MemoryObservation.create!(memory_entity: entity, content: "Current")
      MemoryObservation.create!(memory_entity: entity, content: "Historical").mark_obsolete!

      get "/api/v1/graph_data"

      expect(response).to have_http_status(:ok)
      node = JSON.parse(response.body)["elements"].find do |element|
        element["group"] == "nodes" && element.dig("data", "id") == entity.id.to_s
      end
      expect(node.dig("data", "memory_observations_count")).to eq(1)
    end
  end

  # UI-3 P6: "Show as graph" from Search.
  describe "GET /api/v1/graph_data?ids=" do
    let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
    let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
    let!(:outside) { MemoryEntity.create!(name: "Outside Node", entity_type: "Component") }
    let!(:inside) { MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on") }

    before { MemoryRelation.create!(from_entity: widget, to_entity: outside, relation_type: "depends_on") }

    def elements(group) = response.parsed_body["elements"].select { |element| element["group"] == group }

    it "returns those entities and the relations among them only, skipping unknown ids" do
      get "/api/v1/graph_data", params: { ids: "#{router.id}, #{widget.id},#{widget.id},999999999" }

      expect(response).to have_http_status(:ok)
      expect(elements("nodes").map { |node| node.dig("data", "id") }).to eq([ widget.id.to_s, router.id.to_s ])
      expect(elements("edges").map { |edge| edge.dig("data", "relation_id") }).to eq([ inside.id ])
      expect(response.parsed_body["options"]).to eq("focus_entity_ids" => [ widget.id.to_s, router.id.to_s ])
    end

    it "accepts 100 ids" do
      get "/api/v1/graph_data", params: { ids: (1..100).to_a.join(",") }

      expect(response).to have_http_status(:ok)
    end

    [ "", "0", "-1", "1,,2", "abc", "1.5", (1..101).to_a.join(",") ].each do |ids|
      it "answers 422 for ids=#{ids.truncate(20).inspect}" do
        get "/api/v1/graph_data", params: { ids: ids }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "ids must be 1 to 100 comma-separated entity ids.")
      end
    end

    it "serves a guest" do
      enable_guest!
      sign_in_guest

      get "/api/v1/graph_data", params: { ids: widget.id.to_s }, headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(elements("nodes").size).to eq(1)
    end
  end

  # UI-4b E1: the cap, depth, project scope and a fixed number of queries, same JSON shape.
  describe "Explore reads" do
    let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
    let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
    let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: alpha.id) }
    let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
    let!(:far) { MemoryEntity.create!(name: "Synth Far", entity_type: "Service") }

    before do
      MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
      MemoryRelation.create!(from_entity: router, to_entity: widget, relation_type: "part_of")
      MemoryRelation.create!(from_entity: router, to_entity: far, relation_type: "depends_on")
      MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")
    end

    def node_ids = response.parsed_body["elements"].select { |e| e["group"] == "nodes" }.map { |e| e.dig("data", "id").to_i }
    def edge_ids = response.parsed_body["elements"].select { |e| e["group"] == "edges" }.map { |e| e.dig("data", "relation_id") }

    def queries
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end

    def grow(count)
      count.times do |i|
        node = MemoryEntity.create!(name: "Synth Extra #{SecureRandom.hex(4)} #{i}", entity_type: "Note", project_id: alpha.id)
        MemoryObservation.create!(memory_entity: node, content: "Synthetic note #{i}.")
        MemoryRelation.create!(from_entity: node, to_entity: widget, relation_type: "relates_to")
      end
    end

    it "keeps the JSON shape and adds no truncated/total under the cap" do
      get "/api/v1/graph_data"

      expect(response.parsed_body.keys).to contain_exactly("elements", "options")
      node = response.parsed_body["elements"].find { |e| e.dig("data", "id") == widget.id.to_s }
      expect(node["data"].keys).to contain_exactly("id", "label", "type", "aliases", "memory_observations_count", "is_focus")
      expect(node.dig("data", "memory_observations_count")).to eq(1)
      edge = response.parsed_body["elements"].find { |e| e["group"] == "edges" }
      expect(edge["data"].keys).to contain_exactly("id", "relation_id", "source", "target", "label", "weight", "confidence",
                                                   "properties", "from_entity_name", "to_entity_name")
      expect(edge.dig("data", "from_entity_name")).to be_present
    end

    {
      "full" => -> { {} }, "root" => -> { { root_only: "true" } }, "project" => -> { { project_id: alpha.id } },
      "scoped" => -> { { scoped_entity_id: widget.id } }, "neighbourhood" => -> { { entity_id: widget.id, depth: 2 } }
    }.each do |branch, params|
      it "runs a fixed number of queries as the graph grows (#{branch})" do
        args = instance_exec(&params)
        before_count = queries { get "/api/v1/graph_data", params: args }
        grow(6)
        after_count = queries { get "/api/v1/graph_data", params: args }

        expect(response).to have_http_status(:ok)
        expect(after_count).to eq(before_count)
      end
    end

    it "caps the full graph at MAX_NODES with truncated and total, and only the relations among the nodes" do
      stub_const("Api::V1::GraphDataController::MAX_NODES", 3)

      get "/api/v1/graph_data"

      expect(node_ids).to eq([ alpha.id, widget.id, router.id ])
      expect(response.parsed_body).to include("truncated" => true, "total" => 5)
      expect(edge_ids).to match_array(MemoryRelation.where(relation_type: "part_of").ids)
    end

    it "keeps the focus when a neighbourhood is capped" do
      stub_const("Api::V1::GraphDataController::MAX_NODES", 2)

      get "/api/v1/graph_data", params: { entity_id: far.id, depth: 2 }

      expect(node_ids).to include(far.id)
      expect(node_ids.size).to eq(2)
      expect(response.parsed_body).to include("truncated" => true, "total" => 3)
    end

    it "opens one or two hops" do
      get "/api/v1/graph_data", params: { entity_id: far.id }
      expect(node_ids).to contain_exactly(far.id, router.id)

      get "/api/v1/graph_data", params: { entity_id: far.id, depth: 2 }
      expect(node_ids).to contain_exactly(far.id, router.id, widget.id)
      expect(response.parsed_body["options"]).to eq("focus_entity_id" => far.id.to_s)
    end

    %w[0 3 abc 1.5].each do |value|
      it "answers 422 for depth=#{value}" do
        get "/api/v1/graph_data", params: { entity_id: far.id, depth: value }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "depth must be 1 or 2.")
      end
    end

    it "scopes to a project root and its part_of subtree" do
      get "/api/v1/graph_data", params: { project_id: alpha.id }

      expect(node_ids).to eq([ alpha.id, widget.id, router.id ])
      expect(edge_ids).to match_array(MemoryRelation.where(relation_type: "part_of").ids)
    end

    it "marks a capped project with its member count" do
      stub_const("Api::V1::GraphDataController::MAX_NODES", 2)

      get "/api/v1/graph_data", params: { project_id: alpha.id }

      expect(node_ids).to eq([ alpha.id, widget.id ])
      expect(response.parsed_body).to include("truncated" => true, "total" => 3)
    end

    [ -> { widget.id }, -> { 0 }, -> { "abc" }, -> { 999_999_999 } ].each_with_index do |value, index|
      it "answers 422 for a project_id that isn't a project root (case #{index + 1})" do
        get "/api/v1/graph_data", params: { project_id: instance_exec(&value) }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "project_id must be a project root's id.")
      end
    end

    it "serves a guest every read branch" do
      enable_guest!
      sign_in_guest

      [ {}, { project_id: alpha.id }, { entity_id: widget.id, depth: 2 }, { root_only: "true" } ].each do |params|
        get "/api/v1/graph_data", params: params, headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
