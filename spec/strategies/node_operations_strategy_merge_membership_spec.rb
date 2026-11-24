# frozen_string_literal: true

require "rails_helper"

# Item 2 of the part_of membership plan, Steve's rule for operator and agent merges alike: the
# target keeps its own relationships, and everything that hung on the source (its children and its
# other relations) moves to the target. The source's own parent edge is dropped when the target
# already has a parent, and re-pointed to the target (then synced) when it has none.
RSpec.describe NodeOperationsStrategy, "merge membership" do
  let(:strategy) { described_class.new }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Project", entity_type: "Project") }
  let!(:source) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:target) { MemoryEntity.create!(name: "Synth Widget", entity_type: "Component") }

  def attach!(child, parent)
    MemoryRelation.create!(from_entity: child, to_entity: parent, relation_type: "part_of").tap { ProjectMembership.sync!(child) }
  end

  def parent_ids_of(entity) = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").order(:id).pluck(:to_entity_id)

  def component(name) = MemoryEntity.create!(name: name, entity_type: "Component")

  def review_preview
    row = MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: "entity_merge",
                                       status: "active", signature: "entity_merge|#{SecureRandom.hex(4)}", group_key: "entity_merge|spec",
                                       payload: { "entity_a" => { "entity_id" => source.id }, "entity_b" => { "entity_id" => target.id } })
    CompactionReviewApplier.preview(row)
  end

  context "when the target already has a parent" do
    let!(:source_parent_edge) { attach!(source, alpha) }
    let!(:target_parent_edge) { attach!(target, beta) }
    let!(:gadget) { component("SynthGadget").tap { |entity| attach!(entity, source) } }
    let!(:sprocket) { component("SynthSprocket").tap { |entity| attach!(entity, source) } }
    let!(:bolt) { component("SynthBolt").tap { |entity| attach!(entity, sprocket) } }
    let!(:dial) { component("SynthDial").tap { |entity| attach!(entity, target) } }
    let!(:service) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") }
    let!(:client) { MemoryEntity.create!(name: "Beta Service", entity_type: "Service") }

    before do
      [ service, client ].each { |entity| attach!(entity, beta) }
      MemoryRelation.create!(from_entity: source, to_entity: service, relation_type: "depends_on")
      MemoryRelation.create!(from_entity: target, to_entity: service, relation_type: "calls")
      MemoryRelation.create!(from_entity: client, to_entity: source, relation_type: "relates_to")
    end

    it "keeps the target's own relations and moves everything that hung on the source to the target" do
      target_relations = MemoryRelation.where(from_entity_id: target.id).or(MemoryRelation.where(to_entity_id: target.id))
                                       .pluck(:id, :from_entity_id, :to_entity_id, :relation_type)

      result = strategy.merge_into(source.id, target.id)

      expect(result[:success]).to be(true)
      expect(parent_ids_of(target)).to eq([ beta.id ])
      expect(target.reload.project_id).to eq(beta.id)
      [ gadget, sprocket ].each { |child| expect(parent_ids_of(child)).to eq([ target.id ]) }
      expect([ gadget, sprocket, bolt, dial ].map { |entity| entity.reload.project_id }).to all(eq(beta.id))
      expect(MemoryRelation.where(id: target_relations.map(&:first)).pluck(:id, :from_entity_id, :to_entity_id, :relation_type))
        .to match_array(target_relations)
      expect(MemoryRelation.exists?(from_entity_id: target.id, to_entity_id: service.id, relation_type: "depends_on")).to be(true)
      expect(MemoryRelation.exists?(from_entity_id: client.id, to_entity_id: target.id, relation_type: "relates_to")).to be(true)
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end

    it "previews the source's parent edge as dropped" do
      preview = EntityMergePreview.new(source.id, target.id).call

      expect([ preview.parent_edge, preview.parent_name ]).to eq([ :dropped, "Alpha Project" ])
      expect(preview.dropped.map(&:id)).to include(source_parent_edge.id)
      expect(preview.project_moves.map { |move| [ move.from_name, move.to_name, move.count ] }).to eq([ [ "Alpha Project", "Beta Project", 3 ] ])
      expect(review_preview[:effects]).to include("'Synth Widget' keeps its own parent: the source's part_of 'Alpha Project' is dropped")
    end

    it "drops the source's parent edge, which the merge snapshot keeps" do
      strategy.merge_into(source.id, target.id)

      expect(MemoryRelation.exists?(source_parent_edge.id)).to be(false)
      step = ChangeSet.order(:id).last.section(:merges).sole
      expect(step["destroyed"].map { |relation| relation["id"] }).to include(source_parent_edge.id)
    end

    it "is undone with both parent edges back and every child in its project again" do
      set_uuid = strategy.merge_into(source.id, target.id)[:change_set_uuid]

      expect(ChangeSetUndo.call(set_uuid, actor: "operator:synth")).to be_ok

      expect(parent_ids_of(source.reload)).to eq([ alpha.id ])
      expect(parent_ids_of(target)).to eq([ beta.id ])
      expect([ source.project_id, gadget.reload.project_id, sprocket.reload.project_id, bolt.reload.project_id ]).to all(eq(alpha.id))
      expect([ target.reload.project_id, dial.reload.project_id ]).to eq([ beta.id, beta.id ])
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end
  end

  context "when the target has no parent" do
    let!(:source_parent_edge) { attach!(source, alpha) }
    let!(:gadget) { component("SynthGadget").tap { |entity| attach!(entity, source) } }
    let!(:dial) { component("SynthDial").tap { |entity| attach!(entity, target) } }

    it "gives the target the source's parent and moves it, with its subtree, into that project" do
      strategy.merge_into(source.id, target.id)

      expect(MemoryRelation.find(source_parent_edge.id)).to have_attributes(from_entity_id: target.id, to_entity_id: alpha.id)
      expect(parent_ids_of(target)).to eq([ alpha.id ])
      expect([ target, gadget, dial ].map { |entity| entity.reload.project_id }).to all(eq(alpha.id))
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end

    it "previews the target taking the source's parent, and its move into that project" do
      preview = EntityMergePreview.new(source.id, target.id).call

      expect([ preview.parent_edge, preview.parent_name ]).to eq([ :taken, "Alpha Project" ])
      expect(preview.repointed.map(&:id)).to include(source_parent_edge.id)
      expect(preview.project_moves.map { |move| [ move.from_name, move.to_name, move.count ] }).to eq([ [ nil, "Alpha Project", 2 ] ])
      expect(review_preview[:effects]).to include("'Synth Widget' has no parent of its own: it takes the source's, part_of 'Alpha Project'")
    end

    it "merges through Explore with the preview's digest" do
      digest = EntityMergePreview.new(source.id, target.id).call.digest

      result = EntityMergeService.call(source_id: source.id, target_id: target.id, digest: digest, actor: "operator:synth")

      expect(result[:success]).to be(true)
      expect(target.reload.project_id).to eq(alpha.id)
    end

    it "is undone with the target global again" do
      set_uuid = strategy.merge_into(source.id, target.id)[:change_set_uuid]

      expect(ChangeSetUndo.call(set_uuid, actor: "operator:synth")).to be_ok

      expect(parent_ids_of(source.reload)).to eq([ alpha.id ])
      expect(parent_ids_of(target)).to eq([])
      expect([ source.project_id, gadget.reload.project_id ]).to eq([ alpha.id, alpha.id ])
      expect([ target.reload.project_id, dial.reload.project_id ]).to eq([ nil, nil ])
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end

    context "when a name of the target's subtree is taken in that project" do
      # The same name as the target's child, already in Alpha.
      before { attach!(MemoryEntity.create!(name: "SynthDial", entity_type: "Component", project_id: alpha.id), alpha) }

      let!(:edges) { MemoryRelation.pluck(:id, :from_entity_id, :to_entity_id) }

      def expect_nothing_changed
        expect(MemoryEntity.exists?(source.id)).to be(true)
        expect(MemoryRelation.pluck(:id, :from_entity_id, :to_entity_id)).to match_array(edges)
        expect([ target.reload.project_id, dial.reload.project_id ]).to eq([ nil, nil ])
      end

      it "refuses the merge with nothing changed" do
        expect { strategy.merge_into(source.id, target.id) }.to raise_error(ProjectMembership::Collision, /SynthDial/)
        expect_nothing_changed
      end

      it "records the refusal on a review entity_merge row" do
        item = { id: SecureRandom.uuid, kind: "entity_merge", cosine_distance: 0.05, score: 0.95,
                 entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
                 entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type } }
        row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole

        expect(CompactionReviewService.apply(row.row_uuid)).to include(success: false, error: /SynthDial/)
        expect(row.reload).to have_attributes(status: "active", resolution_reason: /SynthDial/)
        expect_nothing_changed
      end

      it "answers Explore's merge with 422" do
        digest = EntityMergePreview.new(source.id, target.id).call.digest

        result = EntityMergeService.call(source_id: source.id, target_id: target.id, digest: digest, actor: "operator:synth")

        expect(result).to include(success: false, status: :unprocessable_content, error: /SynthDial/)
        expect_nothing_changed
      end

      context "over HTTP", type: :request do
        before { sign_in_operator }

        it "answers REST merge_into with 422" do
          post "/api/v1/memory_entities/#{source.id}/merge_into/#{target.id}"

          expect(response).to have_http_status(:unprocessable_content)
          expect(JSON.parse(response.body)["error"]).to include("SynthDial")
          expect_nothing_changed
        end
      end
    end
  end

  it "keeps the target's parent when the target was part_of the source" do
    attach!(source, alpha)
    attach!(target, source)

    strategy.merge_into(source.id, target.id)

    expect(parent_ids_of(target)).to eq([ alpha.id ])
    expect(target.reload.project_id).to eq(alpha.id)
  end

  it "drops the source's parent edge when re-pointing it would make a cycle" do
    holder = component("SynthHolder")
    attach!(holder, target)
    attach!(source, holder)

    strategy.merge_into(source.id, target.id)

    expect(parent_ids_of(target)).to eq([])
    expect(parent_ids_of(holder)).to eq([ target.id ])
  end

  # One run through each entry point with a cheap spec: the target keeps one parent, its own.
  describe "every merge entry point" do
    before do
      attach!(source, alpha)
      attach!(target, beta)
    end

    def expect_target_kept_its_parent
      expect(MemoryEntity.exists?(source.id)).to be(false)
      expect(parent_ids_of(target)).to eq([ beta.id ])
      expect(target.reload.project_id).to eq(beta.id)
    end

    it "MCP graph_delete merge_entities" do
      GraphDeleteService.call(operations: [ { type: "merge_entities", source_entity_id: source.id, target_entity_id: target.id } ])
      expect_target_kept_its_parent
    end

    it "a review entity_merge row" do
      item = { id: SecureRandom.uuid, kind: "entity_merge", cosine_distance: 0.05, score: 0.95,
               entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
               entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type } }
      row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole

      expect(CompactionReviewService.apply(row.row_uuid)[:success]).to be(true)
      expect_target_kept_its_parent
    end

    it "dream-state auto-merge" do
      run = CompactionRun.create!(status: "running", phase: "tree_walk", stats: {}, started_at: Time.current)
      match = EntityMergeEvidence::Match.new(source: source, target: target, score: EntityMergeEvidence::AUTO_SCORE,
                                             distance: 0.0, reasons: [])
      allow(EntityMergeEvidence).to receive(:candidates_for).and_return([ match ])
      allow(EntityMergeEvidence).to receive(:pick_survivor).and_return([ source, target ])

      DreamStateCompactor.new(run: run).send(:process_entity_merges, source.id)

      expect_target_kept_its_parent
    end

    context "over HTTP", type: :request do
      before { sign_in_operator }

      it "REST merge_into" do
        post "/api/v1/memory_entities/#{source.id}/merge_into/#{target.id}"

        expect(response).to have_http_status(:no_content)
        expect_target_kept_its_parent
      end
    end
  end
end
