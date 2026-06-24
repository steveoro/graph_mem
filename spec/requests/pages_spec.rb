# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator dashboard pages", type: :request do
  before { sign_in_operator }

  after { CompactionRun.delete_all }

  describe "GET /" do
    it "renders the operator dashboard" do
      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operator Dashboard")
      expect(response.body).to include("Dream State / Compactor Run")
      expect(response.body).not_to include(">Compactor Run<")
      expect(response.body).to include("Garbage Collector")
      expect(response.body).to include('id="btn-dashboard-graph"')
      expect(response.body).to include('id="btn-dream-state-resume"')
      expect(response.body).to include('id="btn-dream-state-refresh"')
      expect(response.body).to include("Compaction review queue")
    end

    it "shows repair action when compaction failed with a relation error" do
      CompactionRun.create!(
        status: "failed",
        phase: "tree_walk",
        stats: {
          "error" => "Duplicate entry '266-211-part_of' for key 'index_memory_relations_uniqueness'",
          "entities_processed" => 40
        },
        started_at: 1.hour.ago,
        finished_at: 30.minutes.ago
      )

      get root_path

      expect(response.body).to include('id="btn-repair-relations"')
      expect(response.body).to include("Repair relation duplicates")
    end
  end

  describe "GET /graph" do
    it "renders the graph explorer with Stimulus hooks" do
      get graph_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="graph"')
      expect(response.body).to include('data-graph-target="container"')
    end
  end

  describe "GET /maintenance" do
    it "renders the maintenance hub" do
      MemoryEntity.create!(name: "ExportRoot", entity_type: "Project")

      get maintenance_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Maintenance Hub")
      expect(response.body).to include('id="btn-maintenance-import"')
      expect(response.body).to include('id="btn-maintenance-export"')
    end
  end
end
