# frozen_string_literal: true

module SqlImport
  # The in-app SQL import: upload → validate → dry run → preview (Projects › Imports, through
  # ImportFlow), then execute → report. The upload is kept as an ImportSession under a fresh id and
  # validated (SqlImport::Validator) before each run, the dry run included; nothing else runs it.
  # graph_mem:import_sql shares the end of a real run (#finish): the operation's details get the file,
  # the affected rows with their detail (the script records them without it), the alias, claim and
  # skipped-link notes and the full-maintenance choice, then SqlImportFollowUpJob is queued, after the
  # import committed and released the membership lock.
  #
  #   session_id = SqlImport::Flow.upload(file, file_name: "synth_prj.sql")  # raises Validator::Invalid, …
  #   ImportSession.load_preview(session_id)["summary"] # => { "memory_entities" => { "new" => 6, … }, … }
  #   operation = SqlImport::Flow.execute(session_id, full_maintenance: false)
  module Flow
    PRODUCER = "graph_mem-sql"
    # Rows a preview keeps (the operation's own list is capped at 5,000 by the script too).
    MAX_ROWS = 5_000
    # Alias/claim notes and skipped links kept for the preview and the report, each.
    MAX_NOTES = 100
    # ActiveRecord::StatementInvalid: a value that passes the validator's grammar and that MariaDB rejects
    # (1e999, a roots line that isn't JSON) fails the run inside its transaction, so nothing was written.
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
    # once it ran; a refused run keeps it, so the preview can show why.
    #
    # @param session_id [String]
    # @param full_maintenance [Boolean] start "Run all scheduled jobs now" after the follow-up
    # @return [OperationProgress]
    # @raise [Validator::Invalid, Executor::Refused, ProjectMembership::LockTimeout]
    def execute(session_id, full_maintenance:)
      meta = ImportSession.load_meta(session_id).stringify_keys
      result = Executor.call(Validator.validate_file(ImportSession.sql_path(session_id)))
      finish(result, file_name: meta["file_name"], full_maintenance: full_maintenance).tap { ImportSession.cleanup(session_id) }
    end

    # Completes the record of a real run and queues its follow-up.
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
      SqlImportFollowUpJob.perform_later(operation.operation_id)
      operation
    end

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
