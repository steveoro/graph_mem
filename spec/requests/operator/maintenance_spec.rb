# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator maintenance controls", type: :request do
  include ActiveJob::TestHelper

  before { sign_in_operator }

  after { CompactionRun.delete_all; MaintenanceReport.delete_all }

  describe "POST /operator/maintenance/compaction/start" do
    it "redirects when dream-state compactor is disabled" do
      AppSettings.enable_dream_state_compactor = false

      post operator_start_compaction_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "starts compaction and redirects with notice" do
      expect {
        post operator_start_compaction_path
      }.to have_enqueued_job(DreamStateCompactionJob)

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Dream-state compaction started")
    end
  end

  describe "POST /operator/maintenance/compaction/pause" do
    it "requests pause on a running compaction" do
      run = CompactionRun.create!(status: "running", phase: "orphans", stats: { "entities_processed" => 0 })

      post operator_pause_compaction_path

      expect(response).to redirect_to(root_path)
      expect(run.reload.pause_requested).to be true
    end

    it "alerts when no running compaction exists" do
      post operator_pause_compaction_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("No running compaction")
    end
  end

  describe "POST /operator/maintenance/garbage_collection/run" do
    it "redirects when garbage collector is disabled" do
      AppSettings.enable_garbage_collector = false

      post operator_run_garbage_collection_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "runs garbage collection and redirects with report summary" do
      MemoryEntity.create!(name: "OpGC", entity_type: "Project")

      post operator_run_garbage_collection_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Garbage collection completed")
      expect(MaintenanceReport.count).to eq(2)
    end
  end

  describe "POST /operator/maintenance/relations/repair" do
    it "repairs relations and redirects with summary" do
      entity_a = MemoryEntity.create!(name: "OpRepair A", entity_type: "Project")
      entity_b = MemoryEntity.create!(name: "OpRepair B", entity_type: "Task")
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "relates_to")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "relates_to")

      post operator_repair_relations_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Relation repair completed")
      expect(MemoryRelation.count).to eq(1)
    end
  end
end
