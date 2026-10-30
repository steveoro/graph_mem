# frozen_string_literal: true

require "rails_helper"

RSpec.describe "System › Background jobs", type: :request do
  include ActiveJob::TestHelper

  before { sign_in_operator }

  after { CompactionRun.delete_all; MaintenanceReport.delete_all }

  it "shows the cards and links to the queue (Mission Control)" do
    get system_jobs_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="background-jobs"', 'data-testid="jobs-queue-link"', 'href="/system/queue"')
  end

  # From the removed maintenance_hub_spec (these pages outlived the hub).
  it "keeps the compactor and garbage collector controls" do
    get system_jobs_path

    jobs = Nokogiri::HTML(response.body).at_css("#background-jobs")
    expect(jobs.text).to include("Dream State / Compactor Run", "Garbage Collector")
    expect(jobs.at_css("#btn-dream-state-resume")).to be_present
    expect(jobs.at_css("#btn-gc-run")).to be_present
    expect(jobs.at_css("#btn-compaction-review")["href"]).to eq(review_path)
    expect(jobs.at_css("#btn-dream-state-refresh")["href"]).to eq(system_jobs_path)
  end

  it "shows the repair action only when compaction failed with a relation error" do
    get system_jobs_path
    expect(response.body).not_to include('id="btn-repair-relations"')

    CompactionRun.create!(
      status: "failed", phase: "tree_walk", started_at: 1.hour.ago, finished_at: 30.minutes.ago,
      stats: { "error" => "Duplicate entry '266-211-part_of' for key 'index_memory_relations_uniqueness'", "entities_processed" => 40 }
    )

    get system_jobs_path
    expect(response.body).to include('id="btn-repair-relations"', "Repair relation duplicates")
  end

  describe "POST /system/jobs/compaction/start" do
    it "redirects when dream-state compactor is disabled" do
      AppSettings.enable_dream_state_compactor = false

      post system_start_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "starts compaction and redirects with notice" do
      expect {
        post system_start_compaction_path
      }.to have_enqueued_job(DreamStateCompactionJob)

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Dream-state compaction started")
    end
  end

  describe "POST /system/jobs/compaction/pause" do
    it "requests pause on a running compaction" do
      run = CompactionRun.create!(status: "running", phase: "orphans", stats: { "entities_processed" => 0 })

      post system_pause_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      expect(run.reload.pause_requested).to be true
    end

    it "alerts when no running compaction exists" do
      post system_pause_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("No running compaction")
    end
  end

  describe "POST /system/jobs/garbage_collection/run" do
    it "redirects when garbage collector is disabled" do
      AppSettings.enable_garbage_collector = false

      post system_run_garbage_collection_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "runs garbage collection and redirects with report summary" do
      MemoryEntity.create!(name: "OpGC", entity_type: "Project")

      post system_run_garbage_collection_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Garbage collection completed")
      expect(MaintenanceReport.count).to eq(2)
    end
  end

  describe "POST /system/jobs/relations/repair" do
    it "repairs relations and redirects with summary" do
      entity_a = MemoryEntity.create!(name: "OpRepair A", entity_type: "Project")
      entity_b = MemoryEntity.create!(name: "OpRepair B", entity_type: "Task")
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "relates_to")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "relates_to")

      post system_repair_relations_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Relation repair completed")
      expect(MemoryRelation.count).to eq(1)
    end
  end
end
