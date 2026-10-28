# frozen_string_literal: true

require "rails_helper"

# UI-4b W4: the type picker, Add relation and Remove relation. Synthetic data.
RSpec.describe "Explore relation edits", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
  let!(:existing) { MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on") }

  def add(from, to, type)
    post explore_relations_path, params: { from_id: from.id, to_id: to.id, relation_type: type }, headers: stream_headers
  end

  it_behaves_like "an operator-only Explore write", -> { add(router, widget, "relates_to") }
  it_behaves_like "an operator-only Explore write", -> { delete explore_relation_path(existing), headers: stream_headers }

  context "as the operator" do
    before { sign_in_operator }

    it "renders the type picker with suggestions first, the direction as text and a swap link" do
      get new_explore_relation_path(from_id: widget.id, to_id: alpha.id), headers: { "Turbo-Frame" => "explore-dialog" }

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("turbo-frame#explore-dialog")).to be_present
      expect(doc.at_css("#explore-relation-type optgroup option")["value"]).to eq("part_of")
      expect(doc.css("#explore-relation-type option").map { |option| option["value"] }).to match_array(GraphVocabulary::RELATION_TYPES)
      expect(doc.at_css("[data-testid='explore-relation-direction']").text).to include("SynthWidget", "Alpha Service")
      expect(doc.at_css("[data-testid='explore-relation-swap']")["href"]).to eq(new_explore_relation_path(from_id: alpha.id, to_id: widget.id))
    end

    it "adds one in explore.relation_add and streams graph_changed" do
      add(widget, alpha, "part_of")

      expect(response).to have_http_status(:ok)
      expect(MemoryRelation.find_by(from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "part_of")).to be_present
      expect(widget.reload.project_id).to eq(alpha.id)
      expect(ChangeSet.sole).to have_attributes(kind: "explore.relation_add", subject_id: widget.id)
      expect(graph_changed_payload["changed"]).to contain_exactly(widget.id.to_s, alpha.id.to_s)
    end

    it "refuses a duplicate, a self-relation, a cycle, an unknown type and a part_of from a root (422)" do
      add(widget, router, "depends_on")
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("That relation already exists.")

      add(widget, widget, "relates_to")
      expect(response).to have_http_status(:unprocessable_content)

      MemoryRelation.create!(from_entity: router, to_entity: alpha, relation_type: "part_of")
      add(alpha, router, "part_of")
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Project roots can't be moved.")

      add(widget, router, "<script>")
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Pick a relation type from the list.")
      expect(ChangeSet.count).to eq(0)
    end

    it "answers 422 when the unique index catches a duplicate the check missed" do
      allow(MemoryRelation).to receive(:exists?).and_call_original
      allow(GraphWriteService).to receive(:execute_one).and_raise(ActiveRecord::RecordNotUnique, "Duplicate entry")

      add(router, widget, "relates_to")

      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("That relation already exists.")
    end

    it "removes one in explore.relation_remove; undo re-creates it with the same id" do
      delete explore_relation_path(existing), headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(MemoryRelation.exists?(existing.id)).to be(false)
      set = ChangeSet.sole
      expect(set).to have_attributes(kind: "explore.relation_remove", undo_strategy: "audit")

      post undo_change_path(set.uuid), headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect(MemoryRelation.find(existing.id)).to have_attributes(from_entity_id: widget.id, to_entity_id: router.id, relation_type: "depends_on")
    end
  end
end
