# frozen_string_literal: true

require "rails_helper"

# UI-4a A2: every entry point records one change set with its kind, actor and subject.
RSpec.describe "Change set recording" do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  around do |example|
    Current.actor = "mcp:synthetic"
    example.run
  ensure
    Current.reset
  end

  def latest_set
    ChangeSet.order(:id).last
  end

  describe "graph services" do
    it "records GraphWriteService.call as graph.write with the first entity as subject" do
      GraphWriteService.call(operations: [ { type: "create_entity", name: "SynthGadget", entity_type: "Component" } ])

      gadget = MemoryEntity.find_by!(name: "SynthGadget")
      expect(latest_set).to have_attributes(kind: "graph.write", actor: "mcp:synthetic", subject_type: "MemoryEntity",
                                            subject_id: gadget.id, undo_strategy: "audit")
      expect(latest_set.audit_logs.pluck(:auditable_id)).to include(gadget.id)
    end

    it "records GraphWriteService.execute_one as graph.write" do
      GraphWriteService.execute_one("create_observation", { entity_id: widget.id, text_content: "synthetic fact" })

      expect(latest_set).to have_attributes(kind: "graph.write", subject_id: widget.id)
    end

    it "records GraphEditService.call and .execute_one as graph.edit" do
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "edited" } ])
      expect(latest_set).to have_attributes(kind: "graph.edit", subject_id: widget.id, undo_strategy: "audit")

      GraphEditService.execute_one("update_entity", { entity_id: alpha.id, description: "edited too" })
      expect(latest_set).to have_attributes(kind: "graph.edit", subject_id: alpha.id)
      expect(ChangeSet.count).to eq(2)
    end

    it "records GraphDeleteService as graph.delete; a hard delete makes the set not undoable" do
      relation = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "depends_on")
      GraphDeleteService.call(operations: [ { type: "delete_relation", relation_id: relation.id } ])
      expect(latest_set).to have_attributes(kind: "graph.delete", subject_id: widget.id, undo_strategy: "audit")

      GraphDeleteService.execute_one("delete_entity", { entity_id: beta.id })
      expect(latest_set).to have_attributes(kind: "graph.delete", undo_strategy: "none", not_undoable_reason: "hard_delete")
    end

    it "writes no set for a batch that fails" do
      expect do
        GraphEditService.call(operations: [ { type: "update_entity", entity_id: -1, description: "nothing" } ])
      end.to raise_error(McpGraphMemErrors::Error)
      expect(ChangeSet.count).to eq(0)
    end
  end

  describe "merges" do
    it "records a standalone merge as kind merge with the target as subject and returns its uuid" do
      result = NodeOperationsStrategy.new.merge_into(widget.id, alpha.id)

      expect(result).to include(success: true, change_set_uuid: latest_set.uuid)
      expect(latest_set).to have_attributes(kind: "merge", subject_id: alpha.id, actor: "mcp:synthetic",
                                            summary: "merged 'SynthWidget' into 'Alpha Service'")
    end

    it "joins the graph_delete batch it runs in" do
      GraphDeleteService.call(operations: [
        { type: "merge_entities", source_entity_id: widget.id, target_entity_id: alpha.id }
      ])

      expect(ChangeSet.count).to eq(1)
      expect(latest_set.kind).to eq("graph.delete")
    end

    it "records a compaction auto-merge with the run as actor, one set per merge" do
      run = CompactionRun.create!(status: "running", phase: "tree_walk", stats: {}, started_at: Time.current)
      match = EntityMergeEvidence::Match.new(source: widget, target: alpha, score: EntityMergeEvidence::AUTO_SCORE,
                                             distance: 0.0, reasons: [])
      allow(EntityMergeEvidence).to receive(:candidates_for).and_return([ match ])

      DreamStateCompactor.new(run: run).send(:process_entity_merges, widget.id)

      expect(latest_set.kind).to eq("compaction.auto_merge")
      expect(latest_set.actor).to eq("compaction:#{run.id}")
      expect(latest_set.subject_type).to eq("MemoryEntity")
    end
  end

  describe "review actions" do
    let(:item) do
      {
        id: "merge-1", kind: "entity_merge",
        entity_a: { entity_id: widget.id, name: widget.name, entity_type: widget.entity_type },
        entity_b: { entity_id: alpha.id, name: alpha.name, entity_type: alpha.entity_type },
        cosine_distance: 0.05, score: 0.95
      }
    end
    let!(:row) { CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).first }

    it "records apply as review.apply, with the merge inside it and the row's before/after" do
      result = CompactionReviewService.apply(row.row_uuid)

      expect(result[:success]).to be(true)
      expect(ChangeSet.count).to eq(1)
      expect(latest_set).to have_attributes(kind: "review.apply", subject_id: widget.id)
      review = latest_set.section(:review_rows).sole
      expect(review).to include("id" => row.id, "row_uuid" => row.row_uuid)
      expect(review["before"]["status"]).to eq("active")
      expect(review["after"]["status"]).to eq("approved")
    end

    # Bulk apply only applies safe kinds since UI-5a, so it bulk-applies a relationship proposal.
    it "records bulk_apply as one review.bulk_apply set" do
      proposal = { id: "rel-1", kind: "relationship_proposal", from_entity_id: widget.id, to_entity_id: beta.id,
                   relation_type: "depends_on", confidence_band: "high", score: 12 }
      safe_row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ proposal ]).first

      CompactionReviewService.bulk_apply([ safe_row.row_uuid, row.row_uuid ])

      expect(ChangeSet.pluck(:kind)).to eq([ "review.bulk_apply" ])
      expect(row.reload.status).to eq("active") # the merge row is skipped
    end

    it "records dismiss with the row change and the suppressions it created" do
      CompactionReviewService.dismiss(row.row_uuid, reason: "synthetic")

      expect(latest_set.kind).to eq("review.dismiss")
      expect(latest_set.section(:review_rows).sole["after"]).to include("status" => "dismissed", "resolution_reason" => "synthetic")
      created = latest_set.section(:suppressions_created)
      expect(created.map { |entry| entry["id"] }).to match_array(MaintenanceReportSuppression.pluck(:id))
    end

    it "records bulk_dismiss, restore (with the deleted suppressions) and ignore" do
      CompactionReviewService.bulk_dismiss([ row.row_uuid ])
      expect(latest_set.kind).to eq("review.bulk_dismiss")
      suppression_ids = MaintenanceReportSuppression.pluck(:id)

      CompactionReviewService.restore(row.row_uuid)
      expect(latest_set.kind).to eq("review.restore")
      expect(latest_set.section(:suppressions_deleted).map { |entry| entry["id"] }).to match_array(suppression_ids)

      CompactionReviewService.ignore(row.row_uuid)
      expect(latest_set.kind).to eq("review.ignore")
      expect(latest_set.section(:review_rows).sole.dig("after", "status")).to eq("ignored")
    end

    it "records nothing for a refused action" do
      CompactionReviewService.dismiss(row.row_uuid)
      expect { CompactionReviewService.apply(row.row_uuid) }.not_to change(ChangeSet, :count)
    end
  end

  describe "HTTP entry points", type: :request do
    before { sign_in_operator }

    it "records POST /data_exchange/merge_node as maintenance.merge_node" do
      post merge_node_data_exchange_index_path, params: { source_id: widget.id, target_id: alpha.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(latest_set.kind).to eq("maintenance.merge_node")
      expect(latest_set.actor).to start_with("operator:")
    end

    it "records an /api/v1 write as api.write and a read as nothing" do
      get "/api/v1/memory_entities/#{widget.id}"
      expect(ChangeSet.count).to eq(0)

      patch "/api/v1/memory_entities/#{widget.id}", params: { memory_entity: { description: "via API" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(latest_set).to have_attributes(kind: "api.write", subject_id: widget.id)
    end

    it "records the API merge inside the api.write set" do
      post "/api/v1/memory_entities/#{widget.id}/merge_into/#{alpha.id}"

      expect(response).to have_http_status(:no_content)
      expect(latest_set.kind).to eq("api.write")
    end
  end
end
