# frozen_string_literal: true

class EmbeddingService
  # The membership lock is never held across a network call, so inside it the models' inline
  # embeddings are deferred, not made: ProjectMembership.with_membership_lock runs its block in
  # defer_inline_embeddings, the embedding callbacks of MemoryEntity and MemoryObservation hand
  # their record to defer_inline_embedding, and when the outermost lock block exits (after its
  # RELEASE_LOCK, so after the transactions inside it have committed or rolled back) each deferred
  # record is embedded, as it would have been inline. A nested block (the lock is reentrant) adds to
  # the outer one's list and embeds nothing itself. Suppressed embeddings
  # (EmbeddingService.suppress_inline_embeddings: bulk paths) are not deferred: those paths enqueue
  # the embedding backfill instead.
  #
  #   EmbeddingService.defer_inline_embeddings do
  #     ActiveRecord::Base.transaction { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  #   end # the entity is embedded here, after the commit
  #
  # The list lives in ActiveSupport::IsolatedExecutionState, like the connection whose session holds
  # the lock. Extended into EmbeddingService.
  module InlineDeferral
    STATE_KEY = :gmem_deferred_inline_embeddings

    # Runs the block with inline embeddings deferred, then embeds the deferred records (on every
    # exit, an exception included: rows committed before it are still embedded; rows rolled back are
    # gone and skipped). Reentrant: inside an outer call it just yields.
    # @yieldreturn [Object]
    # @return [Object] the block's value
    def defer_inline_embeddings
      state = ActiveSupport::IsolatedExecutionState
      return yield if state[STATE_KEY]

      state[STATE_KEY] = {}
      begin
        yield
      ensure
        deferred = state.delete(STATE_KEY)
        embed_missing(deferred.keys)
      end
    end

    # Called by the models' inline embedding callbacks.
    # @param record [MemoryEntity, MemoryObservation] a saved record whose text needs a vector
    # @return [Boolean] true when it was deferred (inside defer_inline_embeddings), false when the
    #   caller embeds it now
    def defer_inline_embedding(record)
      deferred = ActiveSupport::IsolatedExecutionState[STATE_KEY]
      return false unless deferred

      deferred[[ record.class, record.id ]] = true
      true
    end

    # Embeds each record that still exists and still has no embedding stamp (a rolled-back create is
    # gone; a row the backfill already embedded is stamped), one embedding call each, re-read so the
    # vector's compare-and-set uses the stored updated_at. A failure is logged and the row stays
    # unstamped for the embedding backfill, as a failed inline embedding does.
    # @param keys [Enumerable<Array(Class, Integer)>] [MemoryEntity or MemoryObservation, id] pairs
    # @param logger [Logger]
    # @return [Integer] how many rows got a vector
    def embed_missing(keys, logger: Rails.logger)
      keys.count do |klass, id|
        record = klass.where(embedded_at: nil).find_by(id: id)
        next false unless record

        klass == MemoryEntity ? embed_entity(record) : embed_observation(record)
      rescue StandardError => e
        logger.warn "EmbeddingService: deferred embedding of #{klass.name}##{id} failed: #{e.message}"
        false
      end
    end
  end
end
