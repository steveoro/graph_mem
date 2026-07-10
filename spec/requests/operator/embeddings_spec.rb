# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator embeddings", type: :request do
  include ActiveJob::TestHelper

  describe "GET /operator/embeddings" do
    it "redirects unauthenticated users to login" do
      get operator_embeddings_path

      expect(response).to redirect_to(operator_login_path)
    end

    context "when signed in" do
      before do
        sign_in_operator
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(EmbeddingIndexStatus).to receive(:indexes).and_return(
          memory_entities: false,
          memory_observations: false
        )
      end

      it "renders the embeddings management page" do
        allow(EmbeddingConfig).to receive(:config_sources).and_return(
          url: :default, model: :default, provider: :default, dims: :default
        )

        get operator_embeddings_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Embeddings")
        expect(response.body).to include('id="btn-embeddings-test"')
        expect(response.body).to include('id="btn-embeddings-backfill"')
        expect(response.body).to include('id="btn-embeddings-regenerate"')
        expect(response.body).to include('id="btn-embeddings-add-indexes"')
        expect(response.body).to include('data-testid="embedding-source-default"')
        expect(response.body).to include("Edit in System Settings")
      end
    end
  end

  describe "POST /operator/embeddings/test_connection" do
    before { sign_in_operator }

    it "redirects with notice when connection succeeds" do
      allow(EmbeddingService).to receive(:check_connection).and_return(
        ok: true, dims: 768, latency_ms: 42.5, error: nil
      )

      post operator_test_embeddings_connection_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Connection OK")
      expect(response.body).to include("Last connection test")
      expect(response.body).to include("OK")
      expect(response.body).to include("768")
      expect(response.body).to include("42.5")
    end

    it "redirects with alert when connection fails" do
      allow(EmbeddingService).to receive(:check_connection).and_return(
        ok: false, dims: nil, latency_ms: 10.0, error: "HTTP 500"
      )

      post operator_test_embeddings_connection_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Connection failed")
      expect(response.body).to include("Last connection test")
      expect(response.body).to include("Failed")
      expect(response.body).to include("HTTP 500")
    end
  end

  describe "POST /operator/embeddings/backfill" do
    before do
      sign_in_operator
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with("backfill").and_return(:enqueued)
    end

    it "enqueues a backfill job" do
      post operator_backfill_embeddings_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Backfill job enqueued")
    end
  end

  describe "POST /operator/embeddings/regenerate" do
    before do
      sign_in_operator
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with("regenerate").and_return(:enqueued)
    end

    it "enqueues a regenerate job" do
      post operator_regenerate_embeddings_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Regenerate job enqueued")
    end
  end

  describe "POST /operator/embeddings/add_indexes" do
    before do
      sign_in_operator
      allow(EmbeddingIndexManager).to receive(:add_indexes!).and_return(
        success: true, message: "VECTOR INDEX active", indexes: {}
      )
    end

    it "adds indexes and redirects with notice" do
      post operator_add_embeddings_indexes_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("VECTOR INDEX active")
    end
  end

  describe "POST /operator/embeddings/drop_indexes" do
    before do
      sign_in_operator
      allow(EmbeddingIndexManager).to receive(:drop_indexes!).and_return(
        success: true, message: "VECTOR INDEX removed", indexes: {}
      )
    end

    it "drops indexes and redirects with notice" do
      post operator_drop_embeddings_indexes_path

      expect(response).to redirect_to(operator_embeddings_path)
      follow_redirect!
      expect(response.body).to include("VECTOR INDEX removed")
    end
  end
end
