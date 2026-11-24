# frozen_string_literal: true

require "rails_helper"

# The interactive writers that take the membership lock keep their freshness: what they write is
# embedded before the call returns, and every embedding call runs after the lock is released
# (EmbeddingService::InlineDeferral).
RSpec.describe "Embedding outside the membership lock", :with_test_embeddings do
  let!(:calls) { record_embedding_calls! }

  # @param texts [Array<String>] the embedded texts, in any order
  # @param records [Array<MemoryEntity, MemoryObservation>] each one stamped by now
  def expect_embedded_after_the_lock(texts, *records)
    expect(calls.map { |call| call[:text] }).to match_array(texts)
    expect(calls).to all(include(held: false, lock_free: true))
    expect(records.map { |record| record.reload.embedded_at }).to all(be_present)
  end

  # graph_write's semantic duplicate probe embeds "<type>: <name>" before it takes the lock.
  describe "graph_write" do
    let!(:project) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
    let(:probe) { "Component: SynthWidget" }

    before { calls.clear }

    it "embeds a created member, its observations and a new observation before returning" do
      existing = fs_member!(project, "SynthGear")
      calls.clear

      result = GraphWriteService.call(project_id: project.id, operations: [
        { type: "create_entity", name: "SynthWidget", entity_type: "Component", observations: [ "SynthWidget renders tiles." ] },
        { type: "create_observation", entity_id: existing.id, text_content: "SynthGear turns the tiles." }
      ])

      widget = MemoryEntity.find(result[:results].first.dig(:result, :entity_id))
      expect_embedded_after_the_lock([ probe, "Component: SynthWidget", "SynthWidget renders tiles.", "SynthGear turns the tiles." ],
                                     widget, *MemoryObservation.where(memory_entity: [ widget, existing ]))
    end

    it "embeds the entity of a single operation (execute_one) before returning" do
      payload = GraphWriteService.execute_one("create_entity", { name: "SynthWidget", entity_type: "Component" }, project_id: project.id)

      expect_embedded_after_the_lock([ probe, "Component: SynthWidget" ], MemoryEntity.find(payload[:entity_id]))
    end

    it "embeds nothing when the batch rolls back" do
      expect do
        GraphWriteService.call(operations: [
          { type: "create_entity", name: "SynthWidget", entity_type: "Component" },
          { type: "create_observation", entity_id: 0, text_content: "No such entity." }
        ])
      end.to raise_error(McpGraphMemErrors::ResourceNotFound)

      expect(calls.sole).to include(text: probe, held: false)
      expect(MemoryEntity.where(name: "SynthWidget")).not_to exist
    end
  end

  describe "merges: the survivor is re-embedded with its new aliases before the call returns" do
    let!(:source) { MemoryEntity.create!(name: "SynthWidget A", entity_type: "Component") }
    let!(:target) { MemoryEntity.create!(name: "SynthWidget B", entity_type: "Component") }
    let(:survivor_text) { "Component: SynthWidget B. Aliases: SynthWidget A" }

    before { calls.clear }

    it "merge_into" do
      expect(NodeOperationsStrategy.new.merge_into(source.id, target.id)).to include(success: true)
      expect_embedded_after_the_lock([ survivor_text ], target)
    end

    it "graph_delete merge_entities (merge_into under the batch's own lock)" do
      GraphDeleteService.call(operations: [ { type: "merge_entities", source_entity_id: source.id, target_entity_id: target.id } ])
      expect_embedded_after_the_lock([ survivor_text ], target)
    end

    it "an Explore merge" do
      digest = EntityMergePreview.new(source.id, target.id).call.digest
      result = EntityMergeService.call(source_id: source.id, target_id: target.id, digest: digest, actor: FactSupersedeHelpers::OPERATOR_ACTOR)

      expect(result).to include(success: true)
      expect_embedded_after_the_lock([ survivor_text ], target)
    end

    it "a review entity_merge apply (merge_into under the apply's lock and row lock)" do
      report = MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" })
      payload = { entity_a: { entity_id: source.id }, entity_b: { entity_id: target.id } }
      row = MaintenanceReportRow.create!(maintenance_report: report, report_type: "compaction_review", row_uuid: SecureRandom.uuid,
                                         kind: "entity_merge", status: "active",
                                         signature: CompactionReviewService.signature_for("entity_merge", payload),
                                         payload: payload.deep_stringify_keys)

      expect(CompactionReviewService.apply(row.row_uuid)).to include(success: true)
      expect_embedded_after_the_lock([ survivor_text ], target)
    end
  end

  describe "fact supersede" do
    let!(:gadget) { fs_project!("Gadget Project") }
    let!(:widget) { fs_member!(gadget, "SynthWidget") }
    let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
    let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }

    before { calls.clear }

    it "embeds the replacement a review apply writes" do
      item = { id: SecureRandom.uuid, kind: "fact_supersede", fact_observation_id: fact.id, observation_id: old.id,
               verdict: "outdated", confidence: 0.9 }
      row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "fact_supersede", items: [ item ]).sole

      result = Current.set(actor: FactSupersedeHelpers::OPERATOR_ACTOR) do
        CompactionReviewService.apply(row.row_uuid, { fact_action: "supersede", replacement: "The MCP server runs on the mcp gem." })
      end

      expect(result).to include(success: true)
      expect_embedded_after_the_lock([ "The MCP server runs on the mcp gem." ], old.reload.superseded_by)
    end

    it "embeds the replacements of Find & supersede" do
      result = FactSupersede::Bulk.call(project: gadget, observation_ids: [ old.id ], action: "supersede",
                                        replacement: "The MCP server runs on the mcp gem.")

      expect(result).to include(success: true, changed: 1)
      expect_embedded_after_the_lock([ "The MCP server runs on the mcp gem." ], old.reload.superseded_by)
    end
  end

  describe "REST", type: :request do
    before { sign_in_operator }

    it "POST /api/v1/memory_entities/:id/merge_into/:target_id re-embeds the survivor before responding" do
      source = MemoryEntity.create!(name: "SynthWidget A", entity_type: "Component")
      target = MemoryEntity.create!(name: "SynthWidget B", entity_type: "Component")
      calls.clear

      post "/api/v1/memory_entities/#{source.id}/merge_into/#{target.id}"

      expect(response).to have_http_status(:no_content)
      expect_embedded_after_the_lock([ "Component: SynthWidget B. Aliases: SynthWidget A" ], target)
    end

    it "POST /api/v1/bulk with a part_of embeds what it created before responding" do
      project = MemoryEntity.create!(name: "Alpha Project", entity_type: "Project")
      gear = MemoryEntity.create!(name: "SynthGear", entity_type: "Component")
      calls.clear

      post "/api/v1/bulk", as: :json, params: {
        entities: [ { name: "SynthWidget", entity_type: "Component", observations: [ "SynthWidget renders tiles." ] } ],
        observations: [ { entity_id: gear.id, text_content: "SynthGear turns the tiles." } ],
        relations: [ { from_entity_id: gear.id, to_entity_id: project.id, relation_type: "part_of" } ]
      }

      expect(response).to have_http_status(:created)
      widget = MemoryEntity.find_by!(name: "SynthWidget")
      expect(gear.reload.project_id).to eq(project.id)
      expect_embedded_after_the_lock([ "Component: SynthWidget", "SynthWidget renders tiles.", "SynthGear turns the tiles." ],
                                     widget, *MemoryObservation.where(memory_entity: [ widget, gear ]))
    end
  end
end
