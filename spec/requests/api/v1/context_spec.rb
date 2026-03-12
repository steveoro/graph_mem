# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Context", type: :request do
  after { GraphMemContext.clear! }

  describe "GET /api/v1/context" do
    context "when no context is set" do
      it "returns no_context status" do
        get "/api/v1/context"
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["status"]).to eq("no_context")
      end
    end

    context "when context is set to an existing entity" do
      let!(:project) { MemoryEntity.create!(name: "CtxProject", entity_type: "Project", description: "Desc") }

      before { GraphMemContext.current_project_id = project.id }

      it "returns context_active with entity details" do
        get "/api/v1/context"
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["status"]).to eq("context_active")
        expect(data["entity_id"]).to eq(project.id)
        expect(data["entity_name"]).to eq("CtxProject")
        expect(data["entity_type"]).to eq("Project")
        expect(data["description"]).to eq("Desc")
      end
    end

    context "when context points to a deleted entity" do
      before { GraphMemContext.current_project_id = 999_999 }

      it "clears context and returns context_cleared" do
        get "/api/v1/context"
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["status"]).to eq("context_cleared")
        expect(GraphMemContext.current_project_id).to be_nil
      end
    end
  end

  describe "POST /api/v1/context" do
    context "with a valid entity_id" do
      let!(:project) { MemoryEntity.create!(name: "SetCtx", entity_type: "Project") }

      it "sets the context and returns context_set" do
        post "/api/v1/context", params: { entity_id: project.id }
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["status"]).to eq("context_set")
        expect(data["entity_id"]).to eq(project.id)
        expect(GraphMemContext.current_project_id).to eq(project.id)
      end
    end

    context "without entity_id" do
      it "returns 422 with error" do
        post "/api/v1/context", params: {}
        expect(response).to have_http_status(:unprocessable_content)
        data = JSON.parse(response.body)
        expect(data["error"]).to include("entity_id")
      end
    end

    context "with a non-existent entity_id" do
      it "returns 404" do
        post "/api/v1/context", params: { entity_id: 999_999 }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /api/v1/context" do
    context "when context was active" do
      before do
        project = MemoryEntity.create!(name: "DelCtx", entity_type: "Project")
        GraphMemContext.current_project_id = project.id
      end

      it "clears context and reports was_active true" do
        delete "/api/v1/context"
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["status"]).to eq("context_cleared")
        expect(data["was_active"]).to be true
        expect(GraphMemContext.current_project_id).to be_nil
      end
    end

    context "when no context was active" do
      it "clears context and reports was_active false" do
        delete "/api/v1/context"
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data["was_active"]).to be false
      end
    end
  end
end
