# frozen_string_literal: true

require "rails_helper"

# UI-3 F3/F4: GET /api/v1/memory_entities/search takes the search tool's filters. Synthetic data;
# vectors are off in specs, so only the text channel ranks.
RSpec.describe "API v1 memory entity search filters", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
  let!(:dial) { MemoryEntity.create!(name: "Dial", entity_type: "Component", aliases: "synth dial") }
  let(:json) { { "Accept" => "application/json" } }

  def search(**params)
    get "/api/v1/memory_entities/search", params: { q: "synth" }.merge(params), headers: json
    JSON.parse(response.body)
  end

  def ids(body) = body.pluck("entity_id")

  context "as the operator" do
    before { sign_in_operator }

    it "answers the same plain list without filters as with blank ones" do
      unfiltered = search

      expect(unfiltered).to be_an(Array)
      expect(ids(unfiltered)).to contain_exactly(widget.id, router.id, dial.id)
      expect(search(project_id: "", entity_types: "")).to eq(unfiltered)
    end

    it "filters by project, by types (array or comma-separated) and by field" do
      expect(ids(search(project_id: alpha.id))).to eq([ widget.id ])
      expect(ids(search(entity_types: [ "component" ]))).to contain_exactly(widget.id, dial.id)
      expect(ids(search(entity_types: "Service, Component"))).to contain_exactly(widget.id, router.id, dial.id)
      expect(ids(search(search_in_aliases: "false"))).to contain_exactly(widget.id, router.id)
    end

    it "echoes retrieval.filters when retrieval is included" do
      body = search(entity_types: "Service", include_retrieval: "true")

      expect(ids(body["results"])).to eq([ router.id ])
      expect(body["retrieval"]["filters"]).to eq("project_id" => nil, "entity_types" => [ "Service" ],
                                                 "search_in" => %w[name type aliases observations])
    end

    {
      { project_id: "abc" } => "project_id must be the id of a Project entity.",
      { entity_types: Array.new(21) { |i| "Type#{i}" } } => "entity_types must be a list of 1 to 20 non-blank entity types.",
      { search_in_name: "false", search_in_type: "false", search_in_aliases: "false", search_in_observations: "false" } =>
        "At least one search field (name, type, aliases, observations) must be enabled."
    }.each do |params, message|
      it "answers 422 for #{params.keys.join(', ')}" do
        expect(search(**params)).to eq("error" => message)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "refuses an entity that isn't a Project root" do
      expect(search(project_id: widget.id)).to eq("error" => "project_id must be the id of a Project entity.")
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_guest
    end

    it "gets the filtered results too" do
      expect(ids(search(project_id: alpha.id))).to eq([ widget.id ])
      expect(response).to have_http_status(:ok)
    end
  end
end
