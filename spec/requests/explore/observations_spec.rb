# frozen_string_literal: true

require "rails_helper"

# UI-4b W3: add, edit (supersede) and retire observations from the panel. Vectors are off in
# specs, so the similarity check is skipped and the toast says so (Decision 3).
RSpec.describe "Explore observation edits", type: :request do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:fact) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.") }

  def add(content, perspective: nil, force: nil, headers: stream_headers)
    post explore_entity_observations_path(widget), params: { observation: { content: content, perspective: perspective }, force: force }.compact,
                                                   headers: headers
  end

  it_behaves_like "an operator-only Explore write", -> { add("Synthetic note.") }
  it_behaves_like "an operator-only Explore write", -> { patch explore_observation_path(fact), params: { observation: { content: "x" } }, headers: stream_headers }
  it_behaves_like "an operator-only Explore write", -> { post retire_explore_observation_path(fact), headers: stream_headers }

  context "as the operator" do
    before { sign_in_operator }

    it "adds one in an explore.observation_add change set and says similarity wasn't checked" do
      add("SynthWidget caches tiles.", perspective: "experience")

      expect(response).to have_http_status(:ok)
      added = widget.memory_observations.order(:id).last
      expect(added).to have_attributes(content: "SynthWidget caches tiles.", perspective: "experience", source: "explore", status: "active")
      expect(ChangeSet.sole).to have_attributes(kind: "explore.observation_add", subject_id: widget.id)
      expect(toast_text).to include("similarity not checked")
      expect(turbo_stream_for("update", "entity-panel").text).to include("SynthWidget caches tiles.")
    end

    it "refuses an exact duplicate with 422 and points at it" do
      expect { add("SynthWidget renders synthetic tiles.") }.not_to change(MemoryObservation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("This observation already exists.")
      expect(turbo_stream_for("update", "entity-panel").text).to include("It is observation ##{fact.id}.")
    end

    it "warns about a similar observation and adds it anyway with force=1" do
      similar = ImportObservationDuplicateDetector::Result.new(duplicate: true, observation: fact, distance: 0.05, exact_match: false)
      allow_any_instance_of(ImportObservationDuplicateDetector).to receive(:find_duplicate).and_return(similar)

      expect { add("SynthWidget draws synthetic tiles.") }.not_to change(MemoryObservation, :count)
      expect(response).to have_http_status(:unprocessable_content)
      panel = turbo_stream_for("update", "entity-panel")
      expect(panel.at_css("[data-testid='entity-panel-similar']").text).to include("SynthWidget renders synthetic tiles.")
      expect(panel.at_css("[data-testid='entity-panel-add-anyway']")["value"]).to eq("1")

      expect { add("SynthWidget draws synthetic tiles.", force: "1") }.to change(MemoryObservation, :count).by(1)
      expect(toast_text).to eq("Observation added. Undo ×")
    end

    it "validates text and perspective" do
      add("  ")
      expect(response).to have_http_status(:unprocessable_content)
      add("x" * (ExploreEdits::Observations::MAX_OBSERVATION_LENGTH + 1))
      expect(response).to have_http_status(:unprocessable_content)
      add("Synthetic note.", perspective: "opinion")
      expect(response).to have_http_status(:unprocessable_content)
      expect(ChangeSet.count).to eq(0)
    end

    it "edits by superseding (history kept), in explore.observation_edit" do
      patch explore_observation_path(fact), params: { observation: { content: "SynthWidget renders synthetic tiles fast.", perspective: "world" } },
                                            headers: stream_headers

      expect(response).to have_http_status(:ok)
      replacement = MemoryObservation.find_by(content: "SynthWidget renders synthetic tiles fast.")
      expect(fact.reload).to have_attributes(status: "superseded", superseded_by_id: replacement.id)
      expect(ChangeSet.sole.kind).to eq("explore.observation_edit")
    end

    it "retires one (obsolete) and refuses an inactive one" do
      post retire_explore_observation_path(fact), params: { reason: "Synthetic: no longer true" }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(fact.reload).to have_attributes(status: "obsolete", obsolescence_reason: "Synthetic: no longer true")
      expect(ChangeSet.sole.kind).to eq("explore.observation_retire")

      post retire_explore_observation_path(fact), headers: stream_headers
      expect(response).to have_http_status(:unprocessable_content)
      patch explore_observation_path(fact), params: { observation: { content: "x" } }, headers: stream_headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
