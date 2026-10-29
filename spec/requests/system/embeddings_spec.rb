# frozen_string_literal: true

require "rails_helper"

RSpec.describe "System › Embeddings", type: :request do
  include ActiveJob::TestHelper

  describe "GET /system/embeddings" do
    it "redirects unauthenticated users to login" do
      get system_embeddings_path

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

        get system_embeddings_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Embeddings")
        expect(response.body).to include('id="btn-embeddings-test"')
        expect(response.body).to include('id="btn-embeddings-backfill"')
        expect(response.body).to include('data-testid="typed-confirm-regenerate"', 'data-typed-confirm-expected-value="REGENERATE"')
        expect(response.body).to include('id="btn-embeddings-add-indexes"')
        expect(response.body).to include('data-testid="embedding-source-default"')
        expect(response.body).to include("Edit in System Settings")
      end
    end
  end

  describe "POST /system/embeddings/test_connection" do
    before { sign_in_operator }

    it "redirects with notice when connection succeeds" do
      allow(EmbeddingService).to receive(:check_connection).and_return(
        ok: true, dims: 768, latency_ms: 42.5, error: nil
      )

      post system_test_embeddings_connection_path

      expect(response).to redirect_to(system_embeddings_path)
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

      post system_test_embeddings_connection_path

      expect(response).to redirect_to(system_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Connection failed")
      expect(response.body).to include("Last connection test")
      expect(response.body).to include("Failed")
      expect(response.body).to include("HTTP 500")
    end
  end

  describe "POST /system/embeddings/backfill" do
    before do
      sign_in_operator
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with("backfill").and_return(:enqueued)
    end

    it "enqueues a backfill job" do
      post system_backfill_embeddings_path

      expect(response).to redirect_to(system_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Backfill job enqueued")
    end
  end

  describe "POST /system/embeddings/regenerate" do
    before do
      sign_in_operator
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with("regenerate").and_return(:enqueued)
    end

    it "answers 422 and enqueues nothing without the typed word" do
      [ {}, { confirmation: "regenerate" }, { confirmation: "DROP" } ].each do |params|
        post system_regenerate_embeddings_path, params: params

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('data-testid="typed-confirm-error-regenerate"')
      end
      expect(EmbeddingsMaintenanceEnqueuer).not_to have_received(:enqueue!)
    end

    it "enqueues a regenerate job once REGENERATE is typed" do
      post system_regenerate_embeddings_path, params: { confirmation: "REGENERATE" }

      expect(response).to redirect_to(system_embeddings_path)
      follow_redirect!
      expect(response.body).to include("Regenerate job enqueued")
    end
  end

  describe "POST /system/embeddings/add_indexes" do
    before { sign_in_operator }

    it "adds indexes and redirects with notice when converged" do
      allow(EmbeddingIndexManager).to receive(:add_indexes!).and_return(
        success: true, converged: true, message: "VECTOR INDEX active",
        warnings: [], indexes: {}
      )

      post system_add_embeddings_indexes_path

      expect(response).to redirect_to(system_embeddings_path)
      follow_redirect!
      expect(response.body).to include("VECTOR INDEX active")
    end

    it "flashes an alert with the warnings when the database did not converge" do
      allow(EmbeddingIndexManager).to receive(:add_indexes!).and_return(
        success: true, converged: false,
        message: "Finished with warnings. WARNINGS: memory_entities.embedding drifted.",
        warnings: [ "memory_entities.embedding drifted" ], indexes: {}
      )

      post system_add_embeddings_indexes_path

      expect(response).to redirect_to(system_embeddings_path)
      expect(flash[:alert]).to start_with("Indexes not fully converged:")
      expect(flash[:alert].scan("drifted").size).to eq(1)
    end
  end

  describe "POST /system/embeddings/drop_indexes" do
    before do
      sign_in_operator
      allow(EmbeddingIndexManager).to receive(:drop_indexes!).and_return(
        success: true, message: "VECTOR INDEX removed", indexes: {}
      )
    end

    it "answers 422 and drops nothing without the typed word" do
      post system_drop_embeddings_indexes_path, params: { confirmation: "drop" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-testid="typed-confirm-error-drop-indexes"')
      expect(EmbeddingIndexManager).not_to have_received(:drop_indexes!)
    end

    it "drops indexes and redirects with notice once DROP is typed" do
      post system_drop_embeddings_indexes_path, params: { confirmation: "DROP" }

      expect(response).to redirect_to(system_embeddings_path)
      follow_redirect!
      expect(response.body).to include("VECTOR INDEX removed")
    end
  end
end
