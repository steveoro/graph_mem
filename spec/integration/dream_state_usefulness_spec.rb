# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dream-state usefulness acceptance benchmark", :with_test_embeddings, type: :integration do
  let(:maintenance_reports_tool) { GetMaintenanceReportsTool.new }
  let(:dream_state_status_tool) { DreamStateStatusTool.new }

  before do
    clear_enqueued_jobs
    AppSettings.enable_dream_state_compactor = true
  end

  after do
    clear_enqueued_jobs
    CompactionRun.delete_all
    MaintenanceReport.delete_all
  end

  describe "full compaction run via jobs" do
    before do
      @graph = build_acceptance_graph!
      @before_snapshot = graph_health_snapshot
      @before_retrieval = @graph.retrieval_queries.transform_values { |query| retrieval_entity_ids(query) }
      @run = run_compaction_via_jobs!
      @after_snapshot = graph_health_snapshot
      @after_retrieval = @graph.retrieval_queries.transform_values { |query| retrieval_entity_ids(query) }
    end

    let(:graph) { @graph }
    let(:before_snapshot) { @before_snapshot }
    let(:before_retrieval) { @before_retrieval }
    let(:run) { @run }
    let(:after_snapshot) { @after_snapshot }
    let(:after_retrieval) { @after_retrieval }

    it "completes the compaction run with coherent cursor, phase, and stats" do
      expect(run.status).to eq("completed")
      expect(run.phase).to eq("relationship_discovery")
      expect(run.finished_at).to be_present
      expect(run.started_at).to be_present
      expect(run.stats).to include(
        "orphans_parented" => be >= 1,
        "orphans_queued" => be >= 1,
        "observations_deduped" => 2,
        "merges_auto" => be >= 1,
        "merges_queued" => be >= 1,
        "relationships_queued" => be >= 1,
        "entities_processed" => be > 0
      )

      status = dream_state_status_tool.call
      expect(status[:dream_state]).to eq("completed")
      expect(status[:run_id]).to eq(run.id)
      expect(status[:stats]).to include("merges_auto" => be >= 1)
    end

    it "parents high-confidence orphans and queues ambiguous ones" do
      expect(
        MemoryRelation.find_by(
          from_entity: graph.auto_orphan,
          to_entity: graph.bench_project,
          relation_type: "part_of"
        )
      ).to be_present

      review_orphans = compaction_review_items.select { |item| item["kind"] == "orphan_parent" }
      queued_entity_ids = review_orphans.map { |item| item["entity_id"] }
      expect(queued_entity_ids).to include(graph.review_orphan.id)
      expect(queued_entity_ids).to include(graph.unrelated_control.id)
    end

    it "deduplicates byte-identical observations during tree walk" do
      contents = graph.linked_child.reload.memory_observations.pluck(:content)
      expect(contents).to match_array([
        "bench duplicate note",
        "unique linked note",
        "Shared dependency on BenchProject auth module"
      ])
    end

    it "auto-merges near-identical entities and queues review-band pairs" do
      expect(MemoryEntity.find_by(id: graph.merge_source_auto.id)).to be_nil
      expect(MemoryEntity.find_by(id: graph.merge_target_auto.id)).to be_present
      expect(graph.merge_target_auto.reload.memory_observations.pluck(:content))
        .to include("auto merge provenance")

      merge_reviews = compaction_review_items.select { |item| item["kind"] == "entity_merge" }
      entity_pairs = merge_reviews.map { |item| [ item.dig("entity_a", "entity_id"), item.dig("entity_b", "entity_id") ] }
      expect(entity_pairs).to include([ graph.merge_source_review.id, graph.merge_target_review.id ])

      expect(MemoryEntity.find_by(id: graph.merge_source_review.id)).to be_present
      expect(MemoryEntity.find_by(id: graph.merge_target_review.id)).to be_present
    end

    it "leaves protected and unrelated controls unchanged" do
      expect(graph.bench_project.reload).to be_present
      expect(graph.bench_project2.reload).to be_present
      expect(graph.control_task.reload).to be_present
      expect(graph.control_task.memory_observations.pluck(:content)).to match_array([
        "control observation",
        "Shared dependency on BenchProject auth module"
      ])

      expect(
        MemoryRelation.find_by(
          from_entity: graph.control_task,
          to_entity: graph.bench_project2,
          relation_type: "part_of"
        )
      ).to be_present
    end

    it "improves structural usefulness without losing provenance" do
      expect(after_snapshot.entity_count).to eq(before_snapshot.entity_count - 1)
      expect(after_snapshot.observation_count).to eq(before_snapshot.observation_count - 2)
      expect(after_snapshot.dream_state_orphan_count).to eq(before_snapshot.dream_state_orphan_count - 1)
      expect(after_snapshot.duplicate_observation_groups).to eq(0)
      expect(after_snapshot.duplicate_observation_groups).to be < before_snapshot.duplicate_observation_groups
    end

    it "preserves deterministic retrieval for project roots and consolidates duplicate search hits" do
      expect(before_retrieval[:bench_project].first).to eq(graph.bench_project.id)
      expect(after_retrieval[:bench_project].first).to eq(graph.bench_project.id)

      expect(before_retrieval[:auto_merge]).to include(graph.merge_source_auto.id)
      expect(after_retrieval[:auto_merge]).not_to include(graph.merge_source_auto.id)
      expect(after_retrieval[:auto_merge]).to include(graph.merge_target_auto.id)

      expect(after_retrieval[:control_task]).to include(graph.control_task.id)
    end

    it "exposes compaction review items through get_maintenance_reports" do
      result = maintenance_reports_tool.call(report_type: "compaction_review", limit: 5)

      expect(result[:total]).to be >= 1
      items = result[:reports].flat_map { |report| report[:data]["items"] }
      kinds = items.map { |item| item["kind"] }
      expect(kinds).to include("orphan_parent", "entity_merge", "relationship_proposal")
    end

    it "uses review-band cosine distances between 0.10 and 0.30" do
      distance = cosine_distance_between(graph.merge_source_review, graph.merge_target_review)
      expect(distance).to be >= 0.10
      expect(distance).to be < 0.30
    end
  end

  describe "pause and resume mid-run" do
    let(:graph) { build_acceptance_graph! }

    it "pauses cooperatively, flushes review items, and resumes from the cursor without reprocessing" do
      graph

      run = CompactionRunner.start_or_resume!
      perform_enqueued_jobs(only: DreamStateCompactionJob)
      run.reload

      expect(run.status).to eq("running")
      expect(run.cursor_entity_id).to be_present
      processed_at_pause_request = run.stats["entities_processed"]
      cursor_at_pause = run.cursor_entity_id

      run.request_pause!
      perform_enqueued_jobs(only: DreamStateCompactionJob)
      run.reload

      expect(run).to be_paused
      expect(run.stats["entities_processed"]).to be >= processed_at_pause_request
      expect(MaintenanceReport.by_type("compaction_review").exists?).to be true

      resumed_run = CompactionRunner.start_or_resume!
      expect(resumed_run.id).to eq(run.id)
      drain_compaction_jobs!
      run.reload

      expect(run.status).to eq("completed")
      expect(run.stats["entities_processed"]).to be > processed_at_pause_request
      expect(
        MemoryRelation.find_by(
          from_entity: graph.auto_orphan,
          to_entity: graph.bench_project,
          relation_type: "part_of"
        )
      ).to be_present

      # Cursor advances past the pause point; the paused entity is not processed twice.
      expect(run.cursor_entity_id).not_to eq(cursor_at_pause)
    end
  end

  describe "relationship discovery" do
    let(:graph) { build_acceptance_graph! }

    before { graph }

    it "proposes missing semantic links with evidence-backed review payloads" do
      run_compaction_via_jobs!

      proposals = compaction_review_items.select { |item| item["kind"] == "relationship_proposal" }
      expect(proposals).not_to be_empty

      proposals.each do |proposal|
        expect(proposal).to include(
          "from_entity_id",
          "to_entity_id",
          "relation_type",
          "confidence_band",
          "supporting_observation_ids",
          "explanation"
        )
        expect(proposal["relation_type"]).to be_in(%w[relates_to implements solves depends_on part_of])
      end
    end

    it "proposes cross-project connections only when shared observations justify them" do
      run_compaction_via_jobs!

      cross_project = compaction_review_items.find do |item|
        item["kind"] == "relationship_proposal" &&
          item["from_entity_id"] == graph.linked_child.id &&
          item["to_entity_id"] == graph.control_task.id
      end

      expect(cross_project).to be_present
      expect(cross_project["supporting_observation_ids"]).to be_present
    end

    it "keeps inferred links review-only and avoids duplicate or unsupported relations" do
      existing = MemoryRelation.create!(
        from_entity: graph.linked_child,
        to_entity: graph.control_task,
        relation_type: "relates_to"
      )

      run_compaction_via_jobs!

      proposals = compaction_review_items.select { |item| item["kind"] == "relationship_proposal" }
      duplicate = proposals.count do |item|
        item["from_entity_id"] == existing.from_entity_id &&
          item["to_entity_id"] == existing.to_entity_id &&
          item["relation_type"] == existing.relation_type
      end

      expect(duplicate).to eq(0)
      expect(MemoryRelation.where(relation_type: "unsupported_type")).to be_empty
      expect(proposals).to all(include("confidence_band" => be_in(%w[high medium low])))
    end

    it "improves reachability for fixed benchmark questions once proposals are accepted" do
      before_paths = retrieval_entity_ids("BenchProject login")
      run_compaction_via_jobs!

      proposal = compaction_review_items.find do |item|
        item["kind"] == "relationship_proposal" &&
          item["relation_type"] == "solves" &&
          item["from_entity_id"] == graph.discovery_solution.id &&
          item["to_entity_id"] == graph.discovery_issue.id
      end
      expect(proposal).to be_present

      MemoryRelation.create!(
        from_entity_id: proposal["from_entity_id"],
        to_entity_id: proposal["to_entity_id"],
        relation_type: proposal["relation_type"]
      )

      after_paths = retrieval_entity_ids("BenchProject login")
      expect(after_paths.length).to be <= before_paths.length
      expect(after_paths).to include(graph.discovery_issue.id, graph.discovery_solution.id)
    end
  end
end
