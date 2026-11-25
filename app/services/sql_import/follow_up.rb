# frozen_string_literal: true

module SqlImport
  # What the raw SQL of an import skipped, done once it committed and released the membership lock
  # (SqlImportFollowUpJob), for the rows it wrote (SqlImport::Touched). Each step's outcome goes to
  # the operation's details["follow_up"], which the import report shows:
  #
  # 1. the embedding backfill (EmbeddingService#backfill_all, after a connection check): every row
  #    with embedded_at NULL. A busy embeddings lock defers the whole follow-up (#call returns
  #    :deferred and the job runs again), unless it is the last attempt;
  # 2. trust scores of the written observations and of the written entities' active ones;
  # 3. keyword paths (FactKeywordsJob.request!) and FactSupersedeJob for each new source fact and each
  #    fact that gained the tag, as the model callbacks would have;
  # 4. review rows (SqlImport::ReviewSeeds): name/alias collisions and reworded duplicates; a new fact
  #    the duplicate check couldn't compare (no embedding: the service is down) is reported, not skipped
  #    silently. The review policies run when a row was seeded;
  # 5. details["contradiction_entity_ids"]: the stale scan's contradiction pass adds them (the imported
  #    rows keep the source updated_at, which its own filter reads);
  # 6. compaction (CompactionRunner.start_or_resume!, as System › Background jobs starts it) only when
  #    step 4 seeded a row and full maintenance isn't asked for;
  # 7. full maintenance ("Run all scheduled jobs now", trigger "sql_import") when it is asked for.
  #
  # Nothing here takes the membership lock, so nothing embeds under it; the compaction it starts runs
  # its own batches under the lock, after the import released it, and pauses again for the next write
  # (CompactionValve).
  #
  #   SqlImport::FollowUp.call(operation)                     # => :done, or :deferred
  #   SqlImport::FollowUp.contradiction_entity_ids(after: t)  # => [ 12, 14 ]
  class FollowUp
    FULL_TRIGGER = ScheduledRunJob::TRIGGER_SQL_IMPORT

    # @param operation [OperationProgress] an SQL import (details["format"] == "sql")
    # @param last_attempt [Boolean] run the steps even when the embeddings lock stays busy
    # @return [Symbol] :done, or :deferred (the embeddings lock was busy: nothing else ran)
    def self.call(operation, last_attempt: false)
      new(operation).call(last_attempt: last_attempt)
    end

    # The entities of the SQL imports whose follow-up finished after `after`: the stale scan's
    # contradiction pass scans them besides those with observation activity.
    #
    # @param after [Time]
    # @return [Array<Integer>] existing entity ids
    def self.contradiction_entity_ids(after:)
      ids = OperationProgress.where(operation_type: "import").where("updated_at > ?", after)
                             .where("JSON_CONTAINS_PATH(details, 'one', '$.contradiction_entity_ids')").pluck(:details)
                             .select { |details| finished_after?(details, after) }
                             .flat_map { |details| Array(details["contradiction_entity_ids"]) }
      MemoryEntity.where(id: ids.uniq).pluck(:id)
    end

    def self.finished_after?(details, after)
      Time.iso8601(details.dig("follow_up", "finished_at").to_s) > after
    rescue ArgumentError
      false
    end
    private_class_method :finished_after?

    # The report's "Run full maintenance now": while the follow-up is queued or running it starts the
    # run when it ends; otherwise (finished, failed, or an import run outside the app) it starts now.
    #
    # @param operation [OperationProgress] an SQL import
    # @return [Symbol] :after_follow_up, :started or :already_running
    def self.request_full_maintenance!(operation)
      pending = operation.reload.with_lock do
        details = operation.details.to_h
        operation.update!(details: details.merge("full_maintenance" => true))
        %w[queued running].include?(details.dig("follow_up", "status"))
      end
      return :after_follow_up if pending

      outcome = start_full_maintenance
      operation.reload.with_lock { operation.update!(details: operation.details.to_h.merge("full_maintenance_outcome" => outcome)) }
      outcome.to_sym
    end

    # @return [String] "started", or "already_running" when a run is going (it is left alone)
    def self.start_full_maintenance
      ScheduledRunJob.start!(trigger: FULL_TRIGGER) ? "started" : "already_running"
    end

    def initialize(operation)
      @operation = operation
      @report = {}
    end

    # @param last_attempt [Boolean]
    # @return [Symbol] :done or :deferred
    def call(last_attempt:)
      save!("status" => "running")
      if embeddings(last_attempt) == :deferred
        save!("status" => "queued", "deferred" => @operation.details.dig("follow_up", "deferred").to_i + 1)
        return :deferred
      end

      touched = Touched.for(@operation)
      @report["trust_scores"] = ObservationTrustRecompute.call(entity_ids: touched.entity_ids, observation_ids: touched.observation_ids)
      keywords_and_facts(touched)
      seeded = review_rows(touched)
      @report["compaction"] = compaction(seeded)
      finish!(touched)
      :done
    rescue StandardError => e
      save!(@report.merge("status" => "failed", "error" => "#{e.class}: #{e.message}".truncate(500), "finished_at" => Time.current.utc.iso8601))
      raise
    end

    private

    def embeddings(last_attempt)
      return @report["embeddings"] = { "skipped" => "vectors_off" } unless EmbeddingService.vector_enabled?

      check = EmbeddingService.instance.check_connection
      return @report["embeddings"] = { "skipped" => "unavailable", "error" => check[:error].to_s.truncate(200) } unless check[:ok]

      result = EmbeddingService.instance.backfill_all
      return :deferred if result[:deferred] && !last_attempt

      @report["embeddings"] = result.slice(:entities, :observations).stringify_keys.merge(result[:deferred] ? { "skipped" => "lock_busy" } : {})
    end

    # What MemoryObservation's after_commit hooks would have done for the rows the SQL wrote.
    def keywords_and_facts(touched)
      pending = MemoryObservation.active.keywords_pending.where(id: touched.observation_ids).exists?
      FactKeywordsJob.request! if pending
      @report["keywords_requested"] = pending && AppSettings.fact_keywords_enabled?
      return @report["fact_supersede_queued"] = 0 unless AppSettings.fact_supersede_enabled?

      facts = MemoryObservation.includes(:memory_entity).where(id: touched.new_observation_ids).select(&:source_fact?) +
              MemoryObservation.includes(:memory_entity).where(id: touched.retagged_observation_ids).select { |fact| fact.source_fact? && tag_added?(fact) }
      facts.each { |fact| FactSupersedeJob.perform_later(fact.id) }
      @report["fact_supersede_queued"] = facts.size
    end

    def tag_added?(fact)
      AuditLog.where(auditable_type: "MemoryObservation", auditable_id: fact.id, action: "update", reason: "sql_import:#{@operation.operation_id}")
              .pluck(:changed_fields).any? do |fields|
        change = fields.to_h["tags"]
        change.is_a?(Hash) && Array(change["to"]).include?(SourceFact::SOURCE_FACT_TAG) && !Array(change["from"]).include?(SourceFact::SOURCE_FACT_TAG)
      end
    end

    def review_rows(touched)
      result = ReviewSeeds.call(touched, operation_id: @operation.operation_id)
      @report["review_rows"] = result.rows.group_by(&:kind).transform_values(&:size)
      @report["near_duplicates"] = { "checked" => result.checked, "unchecked" => result.unchecked }
      @report["near_duplicates"]["reason"] = @report.dig("embeddings", "skipped") || "not_embedded" if result.unchecked.positive?
      ReviewPolicyJob.enqueue_if_seeded(trigger: ReviewSeeds::SOURCE, seeded: result.rows)
      result.rows.size
    end

    def compaction(seeded)
      return "full_maintenance" if @operation.reload.details.to_h["full_maintenance"]
      return "not_needed" if seeded.zero?
      return "off" unless AppSettings.dream_state_compactor_enabled?

      @report["compaction_run_id"] = CompactionRunner.start_or_resume!.id
      "started"
    end

    # The last write: under the row lock, so a "Run full maintenance now" pressed meanwhile is either
    # seen here or sees the follow-up finished (request_full_maintenance!) and starts the run itself.
    def finish!(touched)
      full = nil
      @operation.reload.with_lock do
        details = @operation.details.to_h
        full = details["full_maintenance"] && !details["full_maintenance_outcome"]
        @report.merge!("status" => "done", "finished_at" => Time.current.utc.iso8601)
        @operation.update!(details: details.merge("follow_up" => details["follow_up"].to_h.merge(@report),
                                                  "contradiction_entity_ids" => touched.observation_owner_ids))
      end
      return unless full

      outcome = self.class.start_full_maintenance
      @operation.reload.with_lock { @operation.update!(details: @operation.details.to_h.merge("full_maintenance_outcome" => outcome)) }
    end

    # Every write reloads first: details the script wrote (MariaDB's JSON spacing) read back as changed
    # once deserialized, and with_lock refuses a record with changes.
    def save!(fields)
      @operation.reload.with_lock do
        details = @operation.details.to_h
        @operation.update!(details: details.merge("follow_up" => details["follow_up"].to_h.merge(fields)))
      end
    end
  end
end
