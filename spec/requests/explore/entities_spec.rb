# frozen_string_literal: true

require "rails_helper"

# UI-4b W2: PATCH /explore/entities/:id. Synthetic data.
RSpec.describe "Explore entity edits", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id, aliases: "synth tile") }

  def patch_entity(entity, attributes, headers: stream_headers)
    patch explore_entity_path(entity), params: { entity: attributes }, headers: headers
  end

  it_behaves_like "an operator-only Explore write", -> { patch_entity(widget, { name: "SynthWidget 2" }) }

  context "as the operator" do
    before { sign_in_operator }

    it "saves in one explore.entity_edit change set with the operator actor, and streams toast, panel and graph_changed" do
      patch_entity(widget, { name: "SynthWidget 2", aliases: "synth tile, gizmo", description: "Renders synthetic tiles" })

      expect(response).to have_http_status(:ok)
      expect(widget.reload).to have_attributes(name: "SynthWidget 2", aliases: "synth tile, gizmo", description: "Renders synthetic tiles")
      set = ChangeSet.sole
      expect(set).to have_attributes(kind: "explore.entity_edit", subject_id: widget.id, undo_strategy: "audit")
      expect(set.actor).to start_with("operator:#{OperatorAuthHelpers::TEST_OPERATOR_USERNAME}@")
      expect(set.audit_logs.pluck(:actor).uniq).to eq([ set.actor ])
      expect(toast_text).to include("Saved 'SynthWidget 2'.", "Undo")
      expect(turbo_stream_for("update", "toasts").at_css("[data-undo-until]")["data-undo-until"]).to be_present
      expect(turbo_stream_for("update", "entity-panel").at_css("h2").text).to eq("SynthWidget 2")
      expect(graph_changed_payload).to eq("removed" => [], "changed" => [ widget.id.to_s ])
    end

    it "answers 422 with the model's message in the panel form for a duplicate name, writing nothing" do
      MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: alpha.id)

      expect { patch_entity(widget, { name: "synth router" }) }.not_to change(ChangeSet, :count)

      expect(response).to have_http_status(:unprocessable_content)
      error = turbo_stream_for("update", "entity-panel").at_css("[data-testid='entity-panel-form-error']")
      expect(error.text).to include("Name has already been taken")
      expect(turbo_stream_for("update", "entity-panel").at_css("input[name='entity[name]']")["value"]).to eq("synth router")
      expect(turbo_stream_for("graph_changed")).to be_nil
      expect(widget.reload.name).to eq("SynthWidget")
    end

    it "lets a project root be renamed only" do
      patch_entity(alpha, { entity_type: "Component" })
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Project roots can only be renamed.")

      patch_entity(alpha, { aliases: "alpha" })
      expect(response).to have_http_status(:unprocessable_content)

      patch_entity(alpha, { name: "Alpha Service 2", description: "Synthetic project" })
      expect(response).to have_http_status(:ok)
      expect(alpha.reload).to have_attributes(name: "Alpha Service 2", entity_type: "Project", aliases: nil)
    end

    it "refuses an unchanged or blank edit" do
      patch_entity(widget, { name: "SynthWidget" })
      expect(response).to have_http_status(:unprocessable_content)
      expect(toast_text).to include("Nothing changed.")

      patch_entity(widget, { name: "  " })
      expect(response).to have_http_status(:unprocessable_content)
      expect(ChangeSet.count).to eq(0)
    end

    it "redirects an HTML request to Explore with the flash" do
      patch_entity(widget, { name: "SynthWidget 2" }, headers: {})

      expect(response).to redirect_to(explore_path(entity_id: widget.id))
      expect(flash[:notice]).to eq("Saved 'SynthWidget 2'.")
      expect(flash[:undo]).to include("uuid" => ChangeSet.sole.uuid, "until" => be_present)
    end

    it "answers 404 for an unknown entity" do
      patch explore_entity_path(id: 0), params: { entity: { name: "x" } }, headers: stream_headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
