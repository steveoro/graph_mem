# frozen_string_literal: true

module Operator
  class EmbeddingsController < ApplicationController
    def index
      @status = EmbeddingStatusSnapshot.call
      @connection_result = session.delete(:embeddings_connection_result)&.with_indifferent_access
    end

    def test_connection
      result = EmbeddingService.check_connection
      session[:embeddings_connection_result] = result

      if result[:ok]
        redirect_to operator_embeddings_path,
                    notice: t("operator.embeddings.connection_ok",
                              dims: result[:dims], latency_ms: result[:latency_ms])
      else
        redirect_to operator_embeddings_path,
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
      redirect_to operator_embeddings_path, notice: result[:message]
    rescue EmbeddingIndexManager::PrecheckError => e
      redirect_to operator_embeddings_path, alert: e.message
    rescue EmbeddingIndexManager::Error => e
      redirect_to operator_embeddings_path, alert: t("operator.embeddings.indexes.add_failed", error: e.message)
    end

    def drop_indexes
      result = EmbeddingIndexManager.drop_indexes!
      redirect_to operator_embeddings_path, notice: result[:message]
    rescue EmbeddingIndexManager::Error => e
      redirect_to operator_embeddings_path, alert: t("operator.embeddings.indexes.drop_failed", error: e.message)
    end

    private

    def enqueue_maintenance!(mode)
      unless EmbeddingService.vector_enabled?
        redirect_to operator_embeddings_path, alert: t("operator.embeddings.vector_disabled")
        return
      end

      case EmbeddingsMaintenanceEnqueuer.enqueue!(mode)
      when :already_pending
        redirect_to operator_embeddings_path, alert: t("operator.embeddings.job_already_running", mode: mode)
      when :enqueued
        redirect_to operator_embeddings_path,
                    notice: t("operator.embeddings.#{mode}_enqueued")
      end
    end
  end
end
