# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator dashboard pages", type: :request do
  before { sign_in_operator }

  after do
    CompactionRun.delete_all
    AgentContext.delete_all
  end

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
      expect(response.body).to include('id="btn-compaction-review"')
      expect(response.body).to include("Review suggestions")
      expect(response.body).to include('data-testid="topnav-search"')
      expect(response.body).to include('data-testid="topnav-maintenance"')
      expect(response.body).to include('data-testid="topnav-settings"')
      expect(response.body).to include('class="dashboard-topnav__link dashboard-topnav__link--icon"')
      expect(response.body).to include('aria-label="Search"')
      expect(response.body).to include('aria-label="Maintenance"')
      expect(response.body).to include('aria-label="Settings"')
    end

    it "links the audit logs stat chip to the audit log browse page" do
      get root_path

      expect(response.body).to include('id="chip-audit-logs"')
      expect(response.body).to include(operator_audit_logs_path)
    end

    it "includes the embeddings dashboard card" do
      get root_path

      expect(response.body).to include('id="btn-dashboard-embeddings"')
      expect(response.body).to include(operator_embeddings_path)
    end

    it "includes the MCP clients and project context card" do
      project = MemoryEntity.create!(name: "AdminHub", entity_type: "Project")
      AgentContext.create!(
        client_id: "cursor-test",
        current_project: project,
        last_seen_at: 1.minute.ago,
        last_tool_name: "set_context"
      )

      get root_path

      expect(response.body).to include('data-testid="dashboard-agent-contexts-card"')
      expect(response.body).to include("MCP Clients &amp; Project Context")
      expect(response.body).to include("cursor-test")
      expect(response.body).to include("AdminHub")
      expect(response.body).to include("set_context")
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
      expect(response.body).to include('id="btn-maintenance-choose-file"')
      expect(response.body).to include('data-testid="btn-maintenance-choose-file"')
      expect(response.body).to include("Choose JSON file")
      expect(response.body).to include('id="maintenance-import-file"')
    end

    it "renders export form with Turbo disabled for direct file download" do
      MemoryEntity.create!(name: "ExportRoot", entity_type: "Project")

      get maintenance_path

      expect(response.body).to include('class="maintenance-export-form"')
      expect(response.body).to include('data-turbo="false"')
      expect(response.body).to include(export_data_exchange_index_path)
    end
  end
end
