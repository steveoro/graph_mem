# frozen_string_literal: true

require "rails_helper"

# UI-4a: POST /changes/:uuid/undo, operator only.
RSpec.describe "POST /changes/:uuid/undo", type: :request do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", description: "original") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  def edit_set(description = "edited")
    ChangeSet.record(kind: "graph.edit", actor: "mcp:graph_edit") do |context|
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: description } ])
      context.uuid
    end
  end

  context "as the operator" do
    before { sign_in_operator }

    it "undoes the set and answers with a toast in #toasts" do
      uuid = edit_set

      post undo_change_path(uuid), headers: turbo

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('target="toasts"', "Undone: ")
      expect(widget.reload.description).to eq("original")
      expect(ChangeSet.find_by!(uuid: uuid).undone_by).to start_with("operator:#{OperatorAuthHelpers::TEST_OPERATOR_USERNAME}@")
    end

    it "answers 409 with the conflicts when the record changed since" do
      uuid = edit_set
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "later" } ])

      post undo_change_path(uuid), headers: turbo

      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("changed since")
      expect(widget.reload.description).to eq("later")
    end

    it "answers 422 when the set is past its window or not undoable" do
      uuid = edit_set
      ChangeSet.find_by!(uuid: uuid).update!(undoable_until: 1.minute.ago)
      post undo_change_path(uuid), headers: turbo
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("The undo window passed")

      hard = ChangeSet.record(kind: "graph.delete") do |context|
        GraphDeleteService.call(operations: [ { type: "delete_entity", entity_id: widget.id } ])
        context.uuid
      end
      post undo_change_path(hard), headers: turbo
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Not undoable: hard_delete")
    end

    it "answers 404 for an unknown change" do
      post undo_change_path(SecureRandom.uuid), headers: turbo

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("That change no longer exists.")
    end

    it "redirects back with a flash for an HTML request" do
      uuid = edit_set

      post undo_change_path(uuid), headers: { "HTTP_REFERER" => graph_path }

      expect(response).to redirect_to(graph_path)
      expect(flash[:notice]).to start_with("Undone: ")
    end

    it "requires the CSRF token" do
      uuid = edit_set
      ActionController::Base.allow_forgery_protection = true

      post undo_change_path(uuid), headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(widget.reload.description).to eq("edited")
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end

  it "answers a guest with 403 and writes nothing" do
    uuid = edit_set
    enable_guest!
    sign_in_guest

    expect { post undo_change_path(uuid), headers: turbo }.not_to change(ChangeSet, :count)
    expect(response).to have_http_status(:forbidden)
    expect(ChangeSet.find_by!(uuid: uuid).undone_at).to be_nil
  end

  it "sends a signed-out visitor to the sign-in page" do
    uuid = edit_set

    post undo_change_path(uuid)

    expect(response).to redirect_to(operator_login_path)
    expect(widget.reload.description).to eq("edited")
  end
end
