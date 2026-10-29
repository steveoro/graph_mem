# frozen_string_literal: true

require "rails_helper"

# UI-4b W6: the merge dialog and the merge. A merge never does more than its preview showed:
# a stale digest answers 409 and writes nothing. Synthetic data.
RSpec.describe "Explore merges", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget_a) { MemoryEntity.create!(name: "SynthWidget A", entity_type: "Component", project_id: alpha.id) }
  let!(:widget_b) { MemoryEntity.create!(name: "SynthWidget B", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: alpha.id) }

  before do
    MemoryObservation.create!(memory_entity: widget_a, content: "SynthWidget A renders synthetic tiles.")
    MemoryObservation.create!(memory_entity: widget_a, content: "SynthWidget A caches tiles.")
    MemoryRelation.create!(from_entity: widget_a, to_entity: router, relation_type: "depends_on")
  end

  def dialog(source, target = nil, query: nil)
    get new_explore_merge_path({ source_id: source.id, target_id: target&.id, q: query }.compact), headers: { "Turbo-Frame" => "explore-dialog" }
    Nokogiri::HTML(response.body)
  end

  def digest_for(source, target) = EntityMergePreview.new(source.id, target.id).call.digest

  def merge(source, target, digest: digest_for(source, target))
    post explore_merges_path, params: { source_id: source.id, target_id: target.id, digest: digest }, headers: stream_headers
  end

  it_behaves_like "an operator-only Explore write", -> { merge(widget_a, widget_b) }

  context "as the operator" do
    before { sign_in_operator }

    it "lists same-type candidates in the picker" do
      doc = dialog(widget_a, query: "SynthWidget")

      expect(doc.css("[data-testid='explore-merge-candidate']").map(&:text)).to eq([ "SynthWidget B" ])
      expect(doc.at_css("[data-testid='explore-merge-candidate']")["href"]).to eq(new_explore_merge_path(source_id: widget_a.id, target_id: widget_b.id))
    end

    it "renders the preview's counts, the swap link and the digest" do
      doc = dialog(widget_a, widget_b)

      expect(doc.at_css("#explore-dialog-title").text.squish).to eq("Merge SynthWidget A (source, will be removed) into SynthWidget B (survivor)")
      expect(doc.at_css("[data-testid='explore-merge-observations']").text).to include("2 observations move")
      expect(doc.at_css("[data-testid='explore-merge-repointed']").text).to include("1 relation is re-pointed", "out depends_on: 1")
      expect(doc.at_css("[data-testid='explore-merge-aliases']").text).to include("SynthWidget A")
      expect(doc.at_css("[data-testid='explore-merge-swap']")["href"]).to eq(new_explore_merge_path(source_id: widget_b.id, target_id: widget_a.id))
      expect(doc.at_css("input[name='digest']")["value"]).to eq(digest_for(widget_a, widget_b))
    end

    it "shows a blocker and a disabled button for different types" do
      doc = dialog(widget_a, router)

      expect(doc.at_css("[data-testid='explore-merge-blocker']").text).to include("Cannot merge entities of different types")
      expect(doc.at_css("[data-testid='explore-merge-submit']")["disabled"]).to be_present
    end

    it "merges in explore.merge (strategy merge), toasts with Undo, and removes the source from the canvas" do
      merge(widget_a, widget_b)

      expect(response).to have_http_status(:ok)
      expect(MemoryEntity.exists?(widget_a.id)).to be(false)
      expect(widget_b.memory_observations.count).to eq(2)
      set = ChangeSet.sole
      expect(set).to have_attributes(kind: "explore.merge", undo_strategy: "merge", subject_id: widget_b.id)
      expect(set.actor).to start_with("operator:")
      expect(toast_text).to include("Merged 'SynthWidget A' into 'SynthWidget B'.", "Undo")
      expect(graph_changed_payload).to eq("removed" => [ widget_a.id.to_s ], "changed" => [ widget_b.id.to_s ])
      expect(turbo_stream_for("update", "entity-panel").at_css("h2").text).to eq("SynthWidget B")

      post undo_change_path(set.uuid), headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect(MemoryEntity.find(widget_a.id).memory_observations.count).to eq(2)
    end

    it "answers 409 and writes nothing when the graph changed since the preview" do
      digest = digest_for(widget_a, widget_b)
      MemoryObservation.create!(memory_entity: widget_a, content: "SynthWidget A was added after the preview.")
      before_counts = explore_record_counts

      merge(widget_a, widget_b, digest: digest)

      expect(response).to have_http_status(:conflict)
      expect(toast_text).to include(EntityMergeService::CONFLICT_MESSAGE)
      expect(explore_record_counts).to eq(before_counts)
      expect(MemoryEntity.exists?(widget_a.id)).to be(true)
    end

    it "answers 422 for different types and for a project root, writing nothing" do
      merge(widget_a, router, digest: "x")
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Cannot merge entities of different types")

      merge(alpha, widget_b, digest: "x")
      expect(response).to have_http_status(:unprocessable_content)
      expect(ChangeSet.count).to eq(0)
    end
  end
end
