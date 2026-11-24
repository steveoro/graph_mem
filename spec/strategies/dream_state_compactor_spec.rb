# frozen_string_literal: true

require "rails_helper"

RSpec.describe DreamStateCompactor, type: :model do
  let(:run) do
    CompactionRun.create!(
      status: "running",
      phase: "tree_walk",
      stats: {
        "entities_processed" => 0,
        "observations_deduped" => 0
      },
      started_at: Time.current
    )
  end

  let!(:project) { MemoryEntity.create!(name: "CompactProject", entity_type: "Project") }

  describe "observation deduplication" do
    it "removes byte-identical duplicate observations" do
      MemoryObservation.create!(memory_entity: project, content: "same note")
      MemoryObservation.create!(memory_entity: project, content: "same note")
      MemoryObservation.create!(memory_entity: project, content: "unique note")

      compactor = described_class.new(run: run)
      compactor.send(:dedupe_observations_for_entity, project.id)

      expect(project.memory_observations.pluck(:content)).to match_array([ "same note", "unique note" ])
      expect(run.reload.stats["observations_deduped"]).to eq(1)
    end
  end

  describe "pause handling" do
    it "pauses when pause_requested is set mid-batch" do
      MemoryEntity.create!(name: "CompactOther", entity_type: "Project")
      run.update!(phase: "tree_walk", cursor_entity_id: nil)

      allow_any_instance_of(described_class).to receive(:process_entity_for_phase) do
        run.update!(pause_requested: true)
      end

      result = described_class.new(run: run).process_batch!

      expect(result).to eq(:paused)
      expect(run.reload).to be_paused
    end
  end

  describe "orphan auto-parenting" do
    it "parents orphans with a high-confidence project token match" do
      match_project = MemoryEntity.create!(name: "TraverseProject", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "TraverseProject_orphan", entity_type: "Task")
      orphan_run = CompactionRun.create!(
        status: "running",
        phase: "orphans",
        stats: {},
        started_at: Time.current
      )

      described_class.new(run: orphan_run).send(:process_orphan, orphan.id)

      relation = MemoryRelation.find_by(from_entity: orphan, to_entity: match_project, relation_type: "part_of")
      expect(relation).to be_present
      expect(orphan_run.reload.stats["orphans_parented"]).to eq(1)
    end

    it "leaves an orphan with no suggestion alone: no review row, no queued stat" do
      MemoryEntity.create!(name: "Swiftshop v2", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "Make Sure The Scratch Folder Exists Before Writing", entity_type: "Task",
                                    description: "Create it if missing")
      orphan_run = CompactionRun.create!(status: "running", phase: "orphans", stats: {}, started_at: Time.current)
      compactor = described_class.new(run: orphan_run)

      compactor.send(:process_orphan, orphan.id)

      expect(compactor.instance_variable_get(:@review_items)).to be_empty
      expect(orphan_run.reload.stats["orphans_queued"].to_i).to eq(0)
      expect(MemoryRelation.where(from_entity: orphan)).to be_empty
    end
  end

  describe "phase completion" do
    it "marks the run completed after the final phase batch" do
      run.update!(phase: "relationship_discovery", cursor_entity_id: project.id)

      result = described_class.new(run: run).process_batch!

      expect(result).to eq(:completed)
      expect(run.reload.status).to eq("completed")
    end
  end

  describe "relationship discovery" do
    let(:discovery) { instance_double(RelationshipDiscoveryStrategy) }

    it "queues relationship proposals and flushes them to compaction_review" do
      issue = MemoryEntity.create!(name: "DiscoveryIssue", entity_type: "Issue")
      MemoryObservation.create!(memory_entity: issue, content: "Blocks DiscoveryProject login flow")
      solution = MemoryEntity.create!(name: "DiscoverySolution", entity_type: "PossibleSolution")
      MemoryObservation.create!(memory_entity: solution, content: "Fixes DiscoveryProject login flow")

      discovery_run = CompactionRun.create!(
        status: "running",
        phase: "relationship_discovery",
        stats: {},
        started_at: Time.current
      )

      allow(discovery).to receive(:proposals_for_entity).and_return(
        [ {
          kind: "relationship_proposal",
          from_entity_id: solution.id,
          to_entity_id: issue.id,
          relation_type: "solves",
          confidence_band: "high",
          score: 11,
          supporting_observation_ids: [ 1, 2 ],
          explanation: "test"
        } ]
      )

      compactor = described_class.new(run: discovery_run, relationship_discovery: discovery)
      compactor.send(:process_relationship_discovery, solution.id)
      compactor.send(:flush_review_queue!)

      expect(discovery).to have_received(:proposals_for_entity).with(
        solution.id,
        scope_entity_ids: [ solution.id ]
      )
      expect(discovery_run.reload.stats["relationships_queued"]).to eq(1)
      report = MaintenanceReport.by_type("compaction_review").recent.first
      row = report.maintenance_report_rows.first
      expect(row).to be_present
      expect(row.kind).to eq("relationship_proposal")
      expect(row.payload["from_entity_id"]).to eq(solution.id)
    end
  end

  describe "queued stats" do
    it "count the rows actually seeded, not the candidates: the per-run cap and dedupe come off the stat" do
      stub_const("ReviewRowClassifier::RUN_CAPS", ReviewRowClassifier::RUN_CAPS.merge("relationship_proposal" => 2))
      source = MemoryEntity.create!(name: "StatsSource", entity_type: "Component")
      targets = Array.new(4) { |i| MemoryEntity.create!(name: "StatsTarget #{i}", entity_type: "Component") }
      proposals = targets.map do |target|
        { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: source.id, to_entity_id: target.id,
          relation_type: "depends_on", confidence_band: "high", score: 12, explanation: "test" }
      end
      stats_run = CompactionRun.create!(status: "running", phase: "relationship_discovery", stats: {}, started_at: Time.current)
      discovery = instance_double(RelationshipDiscoveryStrategy, proposals_for_entity: proposals)
      compactor = described_class.new(run: stats_run, relationship_discovery: discovery)

      compactor.send(:process_relationship_discovery, source.id)
      expect(stats_run.reload.stats["relationships_queued"].to_i).to eq(0) # nothing seeded before the flush

      compactor.send(:flush_review_queue!)

      expect(stats_run.reload.stats["relationships_queued"]).to eq(2)
      expect(MaintenanceReportRow.where(kind: "relationship_proposal", maintenance_report_id: MaintenanceReport.recent.first.id).count).to eq(2)
    end
  end

  # PR 2 of the part_of membership plan: an auto-merge takes the membership lock before the entity's
  # transaction, never inside it.
  describe "membership lock", :with_test_embeddings do
    let!(:source) { fs_member!(project, "SynthWidget", "Task") }
    let!(:target) { fs_member!(project, "SynthWidgetTwin", "Task") }

    before do
      [ source, target ].each do |entity|
        MemoryObservation.create!(memory_entity: entity, content: "SynthWidget batches gadget frames before the nightly export run.")
        assign_test_embedding!(entity, 1.0, 0.0)
      end
      allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).and_call_original
      run.update!(cursor_entity_id: project.id) # the tree walk visits the project, then source, then target
    end

    it "auto-merges with the lock taken before the entity's transaction" do
      result = nil
      expect(open_transactions_at_get_lock { result = described_class.new(run: run).process_batch! }).to eq(0)

      expect(result).to eq(:continued)
      expect(MemoryEntity.where(id: [ source.id, target.id ]).count).to eq(1)
      expect(run.reload.stats["merges_auto"]).to eq(1)
      expect(EmbeddingsMaintenanceEnqueuer).to have_received(:enqueue!).with("backfill")
      expect(membership_lock_free?).to be(true)
    end

    it "takes no lock for a phase that neither moves nor merges" do
      run.update!(phase: "relationship_discovery", cursor_entity_id: nil)
      sql = []
      callback = ->(*, payload) { sql << payload[:sql].to_s }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.new(run: run).process_batch! }

      expect(sql.grep(/GET_LOCK/)).to be_empty
    end
  end

  describe "project root protection" do
    it "does not auto-merge Project entities" do
      project_a = MemoryEntity.create!(name: "MergeProjectA", entity_type: "Project")
      project_b = MemoryEntity.create!(name: "MergeProjectB", entity_type: "Project")
      node_ops = instance_double(NodeOperationsStrategy)
      allow(node_ops).to receive(:merge_into)

      compactor = described_class.new(run: run, node_ops: node_ops)
      compactor.send(:process_entity_merges, project_a.id)

      expect(node_ops).not_to have_received(:merge_into)
      expect(MemoryEntity.find_by(id: project_a.id)).to be_present
      expect(MemoryEntity.find_by(id: project_b.id)).to be_present
    end

    it "does not queue merge reviews involving Project entities" do
      _task = MemoryEntity.create!(name: "MergeTask", entity_type: "Task")
      node_ops = instance_double(NodeOperationsStrategy)
      allow(node_ops).to receive(:merge_into)

      compactor = described_class.new(run: run, node_ops: node_ops)
      compactor.send(:process_entity_merges, project.id)

      review_items = compactor.instance_variable_get(:@review_items)
      expect(review_items).to be_empty
      expect(node_ops).not_to have_received(:merge_into)
    end
  end
end
