# frozen_string_literal: true

require "rails_helper"

# UI-4b W4: the Move under… card and the move. Synthetic data.
RSpec.describe "Explore moves", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:part) { MemoryEntity.create!(name: "Synth Part", entity_type: "Component", project_id: alpha.id) }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    MemoryRelation.create!(from_entity: part, to_entity: widget, relation_type: "part_of")
  end

  def card(node, parent)
    get new_explore_move_path(node_id: node.id, parent_id: parent.id), headers: { "Turbo-Frame" => "explore-dialog" }
    Nokogiri::HTML(response.body)
  end

  it_behaves_like "an operator-only Explore write", -> { post explore_moves_path, params: { node_id: widget.id, parent_id: gadget.id }, headers: stream_headers }

  context "as the operator" do
    before { sign_in_operator }

    it "shows the subtree size and the project change in the confirm card" do
      doc = card(widget, gadget)

      expect(doc.at_css("[data-testid='explore-move-subtree']").text).to include("Moves 2 entities")
      expect(doc.at_css("[data-testid='explore-move-project-change']").text.strip).to eq("Moves them from Alpha Service to Gadget Project.")
      expect(doc.at_css("[data-testid='explore-move-submit']")).to be_present
    end

    it "caps the subtree count at the canvas cap" do
      stub_const("Api::V1::GraphDataController::MAX_NODES", 1)

      expect(card(widget, gadget).at_css("[data-testid='explore-move-subtree']").text).to include("Moves 1+ entities")
    end

    it "explains why a project root can't move, with no button" do
      doc = card(alpha, gadget)

      expect(doc.at_css("[data-testid='explore-move-blocker']").text).to eq("Project roots can't be moved.")
      expect(doc.at_css("[data-testid='explore-move-submit']")).to be_nil
    end

    it "moves in explore.move (subtree and project), and refuses a root (422)" do
      post explore_moves_path, params: { node_id: widget.id, parent_id: gadget.id }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(widget.reload.project_id).to eq(gadget.id)
      expect(part.reload.project_id).to eq(gadget.id)
      expect(ChangeSet.sole).to have_attributes(kind: "explore.move", subject_id: widget.id)

      post explore_moves_path, params: { node_id: alpha.id, parent_id: gadget.id }, headers: stream_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Project roots can't be moved.")
      expect(MemoryRelation.where(from_entity_id: alpha.id)).to be_empty
    end
  end
end
