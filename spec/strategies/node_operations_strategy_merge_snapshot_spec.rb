# frozen_string_literal: true

require "rails_helper"

# UI-4a C1: every merge path stores a merge step in its change set.
RSpec.describe NodeOperationsStrategy, "merge snapshot" do
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:source) do
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", aliases: "Widget", description: "synthetic")
  end
  let!(:target) { MemoryEntity.create!(name: "Synth Widget", entity_type: "Component", aliases: "SW") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:child) { MemoryEntity.create!(name: "SynthWidget Part", entity_type: "Component") }

  before do
    MemoryObservation.create!(memory_entity: source, content: "SynthWidget renders synthetic tiles.")
    MemoryRelation.create!(from_entity: source, to_entity: project, relation_type: "part_of")
    MemoryRelation.create!(from_entity: source, to_entity: beta, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: target, to_entity: beta, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: child, to_entity: source, relation_type: "part_of")
  end

  def merge_step
    ChangeSet.order(:id).last.section(:merges).sole
  end

  it "stores the source, its vector bytes, observation owners and every edge" do
    relation_ids = MemoryRelation.where(from_entity_id: source.id).or(MemoryRelation.where(to_entity_id: source.id)).pluck(:id)
    hex = MemoryEntity.where(id: source.id).pick(Arel.sql("HEX(embedding)"))
    observation_ids = source.memory_observations.pluck(:id)

    result = described_class.new.merge_into(source.id, target.id)

    expect(result[:success]).to be(true)
    set = ChangeSet.find_by!(uuid: result[:change_set_uuid])
    expect(set).to have_attributes(undo_strategy: "merge", not_undoable_reason: nil)
    step = merge_step
    expect(step["source"]).to include("id" => source.id, "name" => "SynthWidget", "aliases" => "Widget", "embedding_hex" => hex)
    expect(step["source"]).not_to have_key("embedding")
    expect(step["target"]).to eq("id" => target.id, "aliases_before" => "SW", "aliases_after" => "SW,Widget,SynthWidget")
    expect(step["observation_ids"]).to eq(observation_ids)
    expect((step["repointed"].map { |r| r["id"] } + step["destroyed"].map { |r| r["id"] })).to match_array(relation_ids)
    expect(step["destroyed"].map { |r| r["relation_type"] }).to eq([ "depends_on" ]) # the triple already on the target
    expect(step["children"]).to eq([ [ child.id, child.project_id ] ])
  end

  it "keeps the merge's own audit rows inside the merge step (the set stays a merge set)" do
    described_class.new.merge_into(source.id, target.id)

    set = ChangeSet.order(:id).last
    expect(set.audit_logs.pluck(:auditable_type)).to include("MemoryEntity", "MemoryObservation", "MemoryRelation")
    expect(set.audit_logs.where(auditable_type: "MemoryEntity", action: "delete").pluck(:auditable_id)).to eq([ source.id ])
    expect(set.undoable_until).to be_within(1.minute).of(7.days.from_now)
  end

  it "rolls the merge back when the snapshot can't be written" do
    allow_any_instance_of(ChangeSet::Context).to receive(:add_merge_step!)
      .and_raise(ActiveRecord::StatementInvalid, "synthetic snapshot failure")

    expect { described_class.new.merge_into(source.id, target.id) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(MemoryEntity.find_by(id: source.id)).to be_present
    expect(ChangeSet.count).to eq(0)
  end

  it "still merges over the size cap and marks the set snapshot_too_large" do
    stub_const("ChangeSet::MAX_SNAPSHOT_BYTES", 500)

    result = described_class.new.merge_into(source.id, target.id)

    expect(result[:success]).to be(true)
    expect(MemoryEntity.find_by(id: source.id)).to be_nil
    expect(ChangeSet.order(:id).last).to have_attributes(undo_strategy: "none", not_undoable_reason: "snapshot_too_large")
  end

  it "adds at most 5 queries, however many observations and relations the source has" do
    queries = lambda do |entity, survivor|
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        before = EntityMergeSnapshot.capture_before(entity, survivor)
        EntityMergeSnapshot.complete(before, survivor)
      end
      count
    end

    small = queries.call(source, target)
    20.times { |i| MemoryObservation.create!(memory_entity: source, content: "synthetic fact #{i}") }
    10.times do |i|
      other = MemoryEntity.create!(name: "SynthGadget #{i}", entity_type: "Component")
      MemoryRelation.create!(from_entity: other, to_entity: source, relation_type: "depends_on")
    end

    expect(queries.call(source, target)).to eq(small)
    expect(small).to be <= 5
  end

  it "records one set with 50 merge steps for a 50-merge graph_delete batch" do
    operations = Array.new(50) do |i|
      from = MemoryEntity.create!(name: "SynthWidget batch #{i}", entity_type: "Component")
      into = MemoryEntity.create!(name: "SynthWidget keeper #{i}", entity_type: "Component")
      { type: "merge_entities", source_entity_id: from.id, target_entity_id: into.id }
    end

    GraphDeleteService.call(operations: operations)

    expect(ChangeSet.count).to eq(1)
    expect(ChangeSet.last).to have_attributes(kind: "graph.delete", undo_strategy: "merge")
    expect(ChangeSet.last.section(:merges).size).to eq(50)
  end

  describe "every caller path" do
    it "graph_delete merge_entities" do
      GraphDeleteService.call(operations: [ { type: "merge_entities", source_entity_id: source.id, target_entity_id: target.id } ])
      expect(merge_step.dig("source", "id")).to eq(source.id)
    end

    it "review apply (web or MCP)" do
      item = {
        id: "merge-1", kind: "entity_merge",
        entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
        entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type },
        cosine_distance: 0.05, score: 0.95
      }
      row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).first

      CompactionReviewService.apply(row.row_uuid)

      expect(ChangeSet.last).to have_attributes(kind: "review.apply", undo_strategy: "merge")
      expect(merge_step.dig("source", "id")).to eq(source.id)
    end

    it "compaction auto-merge" do
      run = CompactionRun.create!(status: "running", phase: "tree_walk", stats: {}, started_at: Time.current)
      match = EntityMergeEvidence::Match.new(source: source, target: target, score: EntityMergeEvidence::AUTO_SCORE,
                                             distance: 0.0, reasons: [])
      allow(EntityMergeEvidence).to receive(:candidates_for).and_return([ match ])
      allow(EntityMergeEvidence).to receive(:pick_survivor).and_return([ source, target ])

      DreamStateCompactor.new(run: run).send(:process_entity_merges, source.id)

      expect(ChangeSet.last).to have_attributes(kind: "compaction.auto_merge", undo_strategy: "merge")
      expect(merge_step.dig("source", "id")).to eq(source.id)
    end

    context "over HTTP", type: :request do
      before { sign_in_operator }

      it "/api/v1 merge_into" do
        post "/api/v1/memory_entities/#{source.id}/merge_into/#{target.id}"
        expect(response).to have_http_status(:no_content)
        expect(ChangeSet.last).to have_attributes(kind: "api.write", undo_strategy: "merge")
        expect(merge_step.dig("source", "id")).to eq(source.id)
      end

      it "/data_exchange/merge_node" do
        post merge_node_data_exchange_index_path, params: { source_id: source.id, target_id: target.id }, as: :json
        expect(response).to have_http_status(:ok)
        expect(ChangeSet.last).to have_attributes(kind: "maintenance.merge_node", undo_strategy: "merge")
        expect(merge_step.dig("source", "id")).to eq(source.id)
      end
    end
  end
end
