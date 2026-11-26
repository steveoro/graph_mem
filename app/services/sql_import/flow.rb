# frozen_string_literal: true

module SqlImport
  # The in-app SQL import: upload → validate → dry run → preview (Projects › Imports, through
  # ImportFlow), then execute → report. The upload is kept as an ImportSession under a fresh id and
  # validated (SqlImport::Validator) before each run, the dry run included; nothing else runs it.
  # graph_mem:import_sql shares the end of a real run (#finish): the operation's details get the file,
  # the affected rows with their detail (the script records them without it), the alias, claim and
  # skipped-link notes and the full-maintenance choice, then SqlImportFollowUpJob is queued, after the
  # import committed and released the membership lock. A follow-up that can't be queued is recorded as
  # failed on the operation, not raised: the import is done.
  #
  # A REFUSALS error comes only from before the commit (nothing was written); anything #execute meets
  # after it is raised as FinishFailed, which no REFUSALS entry matches (the executor raises its own
  # post-commit errors as Executor::Committed).
  #
  #   session_id = SqlImport::Flow.upload(file, file_name: "synth_prj.sql")  # raises Validator::Invalid, …
  #   ImportSession.load_preview(session_id)["summary"] # => { "memory_entities" => { "new" => 6, … }, … }
  #   operation = SqlImport::Flow.execute(session_id, full_maintenance: false)
  #   operation.details["follow_up"] # => { "status" => "queued" }, or { "status" => "failed", "error" => "…" }
  module Flow
    # The run committed, then leaving it (Executor::Committed) or completing its record (#finish) failed:
    # the rows are written, its details and follow-up may be missing. The message is Flow.error_text of
    # the error.
    class FinishFailed < StandardError
      # @return [String] the committed run's operation id
      attr_reader :operation_id

      # @param operation_id [String]
      # @param error [StandardError]
      def initialize(operation_id, error)
        @operation_id = operation_id
        super(Flow.error_text(error))
      end
    end

    PRODUCER = "graph_mem-sql"
    # Rows a preview keeps (the operation's own list is capped at 5,000 by the script too).
    MAX_ROWS = 5_000
    # Alias/claim notes and skipped links kept for the preview and the report, each.
    MAX_NOTES = 100
    # Characters of an error kept on the operation or shown after a commit (as the follow-up's own errors).
    MAX_ERROR = 500
    # What a run refused before it committed: nothing was written. ActiveRecord::StatementInvalid: a value
    # that passes the validator's grammar and that MariaDB rejects (1e999, a roots line that isn't JSON)
    # fails the run inside its transaction. Rescue these around the run only, never around #finish.
    REFUSALS = [ Validator::Invalid, Executor::Refused, ProjectMembership::LockTimeout, ActiveRecord::StatementInvalid ].freeze
    # The notes listing links the run didn't write, by the action of their affected rows.
    LINK_NOTES = { "skipped_links" => "skipped_link", "dropped_links" => "dropped_link" }.freeze

    module_function

    # The reason to show for a refusal: the database's own message for a value MariaDB rejected (not the
    # adapter's wrapper with the statement), else the refusal's message.
    #
    # @param error [StandardError] one of REFUSALS
    # @return [String]
    def refusal_reason(error)
      return error.message unless error.is_a?(ActiveRecord::StatementInvalid)

      (error.cause || error).message
    end

    # @param error [StandardError]
    # @return [String] "<class>: <message>" (the database's own message for a statement it refused, as
    #   #refusal_reason), at most MAX_ERROR characters
    def error_text(error)
      "#{error.class}: #{refusal_reason(error)}".truncate(MAX_ERROR)
    end

    # Stores the upload, validates it and dry-runs it; a refused file leaves nothing behind.
    #
    # @param io [#read] the uploaded file
    # @param file_name [String] its base name, for the history
    # @return [String] the import session id
    # @raise [Validator::Invalid, Executor::Refused, ProjectMembership::LockTimeout]
    def upload(io, file_name:)
      session_id = ImportSession.create_sql(io, meta: { file_name: file_name, producer: PRODUCER })
      script = Validator.validate_file(ImportSession.sql_path(session_id))
      ImportSession.store_preview(session_id, preview(script, Executor.call(script, dry_run: true)))
      session_id
    rescue StandardError
      ImportSession.cleanup(session_id)
      raise
    end

    # Validates the session's script again and runs it for real, then #finish. The session is removed
    # as soon as the run committed, so a second Execute finds no import; a refused run keeps it, so the
    # preview can show why.
    #
    # @param session_id [String]
    # @param full_maintenance [Boolean] start "Run all scheduled jobs now" after the follow-up
    # @return [OperationProgress]
    # @raise [Validator::Invalid, Executor::Refused, ProjectMembership::LockTimeout, ActiveRecord::StatementInvalid]
    #   before the commit (REFUSALS): nothing was written
    # @raise [FinishFailed] after the commit: the rows are written
    def execute(session_id, full_maintenance:)
      meta = ImportSession.load_meta(session_id).stringify_keys
      result = Executor.call(Validator.validate_file(ImportSession.sql_path(session_id)))
      begin
        ImportSession.cleanup(session_id)
        finish(result, file_name: meta["file_name"], full_maintenance: full_maintenance)
      rescue StandardError => e
        raise FinishFailed.new(result.operation_id, e)
      end
    rescue Executor::Committed => e
      ImportSession.cleanup(session_id)
      raise FinishFailed.new(e.result.operation_id, e.cause)
    end

    # Completes the record of a real run and queues its follow-up. A follow-up that can't be queued is
    # recorded on the operation (details["follow_up"] status "failed", with the error), not raised.
    #
    # @param result [Executor::Result] a real (not dry) run
    # @param file_name [String, nil]
    # @param full_maintenance [Boolean]
    # @return [OperationProgress] the run's `import` row
    def finish(result, file_name:, full_maintenance:)
      operation = OperationProgress.find_by!(operation_id: result.operation_id, operation_type: "import")
      operation.reload.with_lock do
        details = operation.details.to_h
        roots = Array(details["roots"])
        operation.update!(details: details.merge(
          "file_name" => file_name, "producer" => PRODUCER, "project_name" => roots.join(", "),
          "project_entity_id" => (MemoryEntity.where(name: roots, project_id: nil).pick(:id) if roots.one?),
          "affected" => rows(result.affected).first(MAX_ROWS), "notes" => notes(result.affected),
          "full_maintenance" => full_maintenance, "follow_up" => { "status" => "queued" }
        ).compact)
      end
      queue_follow_up(operation)
      operation
    end

    # Queues SqlImportFollowUpJob, or records why it couldn't be (the queue database is down, or an
    # adapter refused the job) as the follow-up's failure.
    #
    # @param operation [OperationProgress] the run's `import` row
    # @return [void]
    def queue_follow_up(operation)
      error = nil
      queued = SqlImportFollowUpJob.perform_later(operation.operation_id) { |job| error = job.enqueue_error }
      follow_up_failed!(operation, error ? error_text(error) : "the job was not queued") unless queued
    rescue StandardError => e
      follow_up_failed!(operation, error_text(e))
    end

    def follow_up_failed!(operation, error)
      Rails.logger.error "SqlImport::Flow: the follow-up of import #{operation.operation_id} could not be queued: #{error}"
      operation.reload.with_lock do
        operation.update!(details: operation.details.to_h.merge("follow_up" => { "status" => "failed", "error" => error }))
      end
    end
    private_class_method :follow_up_failed!

    # @param script [Validator::Script]
    # @param result [Executor::Result] the dry run
    # @return [Hash] header, summary (table => action => rows), rows, row_count, notes
    def preview(script, result)
      { "header" => script.header, "summary" => counts(result.summary), "rows" => rows(result.affected).first(MAX_ROWS),
        "row_count" => result.affected.size, "notes" => notes(result.affected) }
    end

    # @param summary [Array<Hash>] Executor::Result#summary
    # @return [Hash{String => Hash{String => Integer}}] the shape of the operation's counters
    def counts(summary)
      summary.each_with_object({}) { |row, counts| (counts[row["table"]] ||= {})[row["action"]] = row["rows"].to_i }
    end

    # @param affected [Array<Hash>] Executor::Result#affected
    # @return [Array<Hash>] table, action, id, entity, detail and the changed fields, or the reason of a
    #   skipped or dropped link (the shape of the operation's details["affected"], plus detail and reason)
    def rows(affected)
      affected.map do |row|
        link = LINK_NOTES.value?(row["action"])
        { "table" => row["table"], "action" => row["action"], "id" => row["id"], "entity" => row["entity"], "detail" => row["detail"],
          "fields" => (row["changed"]&.keys unless link), "reason" => (row.dig("changed", "reason") if link) }.compact
      end
    end

    # @return [Hash] "matches": the entities matched by alias, claimed from global, or inserted because
    #   their name was ambiguous or a namesake wasn't claimed; "skipped_links": the edges whose other end
    #   isn't here; "dropped_links": the outdated_by links the merge dropped because the model would
    #   refuse them, each with the reason; each capped at MAX_NOTES, with the full counts ("<key>_count")
    def notes(affected)
      matches = affected.select { |row| row["table"] == "memory_entities" && row["detail"].to_s.match?(/\A[^,]+, /) }
      LINK_NOTES.each_with_object("matches" => matches.first(MAX_NOTES).map { |row| row.slice("action", "id", "entity", "detail") },
                                  "matches_count" => matches.size) do |(key, action), notes|
        listed = affected.select { |row| row["action"] == action }
        notes[key] = listed.first(MAX_NOTES).map { |row| row.slice("entity", "detail").merge("reason" => row.dig("changed", "reason")) }
        notes["#{key}_count"] = listed.size
      end
    end
  end
end
