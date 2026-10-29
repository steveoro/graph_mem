# frozen_string_literal: true

module System
  # System › Embeddings: coverage, configuration, indexes and the maintenance jobs.
  # Regenerate all and drop indexes need a typed word (TypedConfirmation: 422 on a mismatch).
  class EmbeddingsController < BaseController
    include TypedConfirmation

    self.nav_section = :embeddings

    # The words typed to confirm (the UI plan §5.2).
    REGENERATE_WORD = "REGENERATE"
    DROP_WORD = "DROP"

    before_action -> { require_typed_word!(REGENERATE_WORD, "regenerate") }, only: :regenerate
    before_action -> { require_typed_word!(DROP_WORD, "drop-indexes") }, only: :drop_indexes

    def index
      @status = EmbeddingStatusSnapshot.call
      @connection_result = session.delete(:embeddings_connection_result)&.with_indifferent_access
    end

    def test_connection
      result = EmbeddingService.check_connection
      session[:embeddings_connection_result] = result

      if result[:ok]
        redirect_to system_embeddings_path,
                    notice: t("operator.embeddings.connection_ok",
                              dims: result[:dims], latency_ms: result[:latency_ms])
      else
        redirect_to system_embeddings_path,
                    alert: t("operator.embeddings.connection_failed", error: result[:error])
      end
    end

    def backfill
      enqueue_maintenance!("backfill")
    end

    def regenerate
      enqueue_maintenance!("regenerate")
    end

    def add_indexes
      result = EmbeddingIndexManager.add_indexes!
      if result[:converged]
        redirect_to system_embeddings_path, notice: result[:message]
      else
        redirect_to system_embeddings_path,
                    alert: t("operator.embeddings.indexes.add_not_converged", details: result[:message].truncate(800))
      end
    rescue EmbeddingIndexManager::PrecheckError => e
      redirect_to system_embeddings_path, alert: e.message
    rescue EmbeddingIndexManager::Error => e
      redirect_to system_embeddings_path, alert: t("operator.embeddings.indexes.add_failed", error: e.message)
    end

    def drop_indexes
      result = EmbeddingIndexManager.drop_indexes!
      redirect_to system_embeddings_path, notice: result[:message]
    rescue EmbeddingIndexManager::Error => e
      redirect_to system_embeddings_path, alert: t("operator.embeddings.indexes.drop_failed", error: e.message)
    end

    private

    def require_typed_word!(word, card)
      return if typed_confirmation?(word)

      typed_confirmation_failed!(card)
      index
      render :index, status: :unprocessable_content
    end

    def enqueue_maintenance!(mode)
      unless EmbeddingService.vector_enabled?
        redirect_to system_embeddings_path, alert: t("operator.embeddings.vector_disabled")
        return
      end

      case EmbeddingsMaintenanceEnqueuer.enqueue!(mode)
      when :already_pending
        redirect_to system_embeddings_path, alert: t("operator.embeddings.job_already_running", mode: mode)
      when :enqueued
        redirect_to system_embeddings_path,
                    notice: t("operator.embeddings.#{mode}_enqueued")
      end
    end
  end
end
