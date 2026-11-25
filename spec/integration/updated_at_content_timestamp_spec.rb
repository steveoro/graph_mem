# frozen_string_literal: true

require "rails_helper"

# graph_mem-sql imports are "newer wins" on updated_at (SQL exchange plan, Decision 1), so updated_at
# must stay a content timestamp: none of the derived writers below may move it, nor the Cloud toggle.
RSpec.describe "updated_at is a content timestamp" do
  include ActiveSupport::Testing::TimeHelpers

  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component") }
  let!(:gadget) { fs_member!(project, "SynthGadget", "Component") }
  let!(:fact) { fs_observe!(widget, "SynthWidget calls SynthGadget.") }

  def keeps_updated_at(*records)
    stamps = records.map { |record| record.reload.updated_at }
    travel_to(1.hour.from_now) { yield }
    expect(records.map { |record| record.reload.updated_at }).to eq(stamps)
  end

  it "the embedding store", :with_test_embeddings do
    record_embedding_calls!
    keeps_updated_at(widget, fact) do
      EmbeddingService.embed_entity(widget)
      EmbeddingService.embed_observation(fact)
    end
    expect([ widget.embedded_at, fact.embedded_at ]).to all(be_present)
  end

  it "the keyword path and the LLM words" do
    keeps_updated_at(fact) { FactKeywords.compute!([ fact ]) }
    expect(fact.keywords_at).to be_present
    fact.update_columns(keywords: %w[SynthPrj SynthWidget SynthGadget]) # names an entity: no LLM call

    keeps_updated_at(fact) { FactKeywords::LlmWords.compute!([ fact.reload ]) }
    expect(fact.llm_keywords_at).to be_present
  end

  it "the trust recompute, the counter cache and the garbage collector's counter repair" do
    keeps_updated_at(fact, widget) do
      MemoryRelation.recompute_trust_scores_for([ widget.id ])
      fs_observe!(widget, "A duplicate fact.")
      fs_observe!(widget, "A duplicate fact.")
      GarbageCollectionRunner.call
    end
    expect(widget.memory_observations_count).to eq(2)
  end

  it "the membership backfill" do
    gadget.update_columns(project_id: nil)
    keeps_updated_at(gadget) { ProjectIdBackfill.new(out: StringIO.new).run }
    expect(gadget.project_id).to eq(project.id)
  end

  describe "the Cloud toggle", type: :request do
    before { sign_in_operator }

    it "turns cloud access on and off without moving the project's updated_at" do
      keeps_updated_at(project) do
        patch projects_cloud_access_path(project), params: { allowed: "true", root: "" }
        expect(project.reload.cloud_allowed).to be(true)
        patch projects_cloud_access_path(project), params: { allowed: "false" }
      end
      expect(project.cloud_allowed).to be(false)
      expect(AuditLog.where(auditable: project, action: "update").count).to eq(2)
    end
  end
end
