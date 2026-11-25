# frozen_string_literal: true

module SqlImport
  # Runs a validated graph_mem-sql script (SqlImport::Validator::Script) on this app's connection: this
  # app's template statements (SqlExport::Template) around the file's staging INSERTs, inside one
  # ActiveRecord transaction (a savepoint when one is open) taken inside
  # ProjectMembership.with_membership_lock, after asking a running compaction to pause. The template's
  # START TRANSACTION, COMMIT and GET_LOCK are a hand run's; here the lock is the app's own and the
  # script's lock guard reads it from @gm_lock. Between the staging INSERTs and the merge the staged
  # relation types are canonicalized with this machine's mappings (SqlExport::Template.relation_type).
  # The script stamps membership and checks it itself, and nothing here embeds: new and changed rows
  # keep embedded_at NULL for the backfill. A dry run is the same run, rolled back. The session's
  # sql_mode, time zone and character set are put back, and the gm_ tables dropped, on every exit.
  #
  #   result = SqlImport::Executor.call(SqlImport::Validator.validate_file(path), dry_run: true)
  #   result.summary  # => [{ "table" => "memory_entities", "action" => "new", "rows" => 6 }, ...]
  #   result.affected # => [{ "table" => "memory_entities", "action" => "new", "id" => 9012, ... }, ...]
  class Executor
    # A guard of the script refused the import (SIGNAL): nothing was written. The message says why.
    class Refused < StandardError; end

    SIGNAL_ERROR = 1644
    SESSION_READ = "SELECT @@SESSION.sql_mode, @@SESSION.time_zone, @@SESSION.character_set_client, " \
                   "@@SESSION.character_set_connection, @@SESSION.collation_connection, @@SESSION.character_set_results"
    VARIABLES_RESET = "SET @gm_lock = NULL, @gm_operation_id = NULL, @gm_op = NULL"

    # @!attribute operation_id [String] the operation_progresses row of the run (rolled back on a dry run)
    # @!attribute summary [Array<Hash>] "table", "action", "rows" per table and action
    # @!attribute affected [Array<Hash>] "table", "action", "id", "project", "entity", "detail", "changed"
    #   (a Hash of {field => {from, to}}, or {"reason"} for a skipped link; nil for a new row)
    # @!attribute dry_run [Boolean]
    Result = Data.define(:operation_id, :summary, :affected, :dry_run)

    # @param script [SqlImport::Validator::Script]
    # @param dry_run [Boolean] run everything, then roll it back
    # @param operation_id [String] the id the script records its operation_progresses row under
    # @return [Result]
    # @raise [Refused] when a guard of the script refused it
    # @raise [ProjectMembership::LockTimeout] when the membership lock stays busy
    def self.call(script, dry_run: false, operation_id: SecureRandom.uuid)
      new(script).call(dry_run: dry_run, operation_id: operation_id)
    end

    # @param script [SqlImport::Validator::Script]
    def initialize(script)
      @script = script
      @template = SqlExport::Template.new(script.version)
      @connection = ActiveRecord::Base.connection
    end

    # @param dry_run [Boolean]
    # @param operation_id [String]
    # @return [Result]
    def call(dry_run:, operation_id:)
      CompactionValve.request_pause_if_running!
      result = nil
      ProjectMembership.with_membership_lock do
        EmbeddingService.suppress_inline_embeddings do
          @connection.uncached do
            with_session do
              ActiveRecord::Base.transaction(requires_new: true) do
                result = run(operation_id, dry_run)
                raise ActiveRecord::Rollback if dry_run
              end
            end
          end
        end
      end
      result
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.cause.respond_to?(:error_number) && e.cause.error_number == SIGNAL_ERROR

      raise Refused, e.cause.message
    end

    private

    def run(operation_id, dry_run)
      @connection.execute("SET @gm_operation_id = #{@connection.quote(operation_id)}")
      @connection.execute("SET @gm_lock = (IS_USED_LOCK(#{@connection.quote(ProjectMembership.lock_name(@connection))}) = CONNECTION_ID())")
      execute_all(@template.statements(:before_data))
      @script.data_statements.each { |statement| @connection.execute(statement) }
      execute_all(@template.statements(:guards))
      canonicalize_relation_types!
      summary, affected = execute_all(@template.statements(:merge)).last(2)
      affected = affected.to_a.map { |row| row.merge("changed" => row["changed"] && JSON.parse(row["changed"])) }
      Result.new(operation_id: operation_id, summary: summary.to_a, affected: affected, dry_run: dry_run)
    end

    # @return [Array<ActiveRecord::Result>] the result sets of the SELECT statements, in order
    def execute_all(statements)
      statements.each_with_object([]) do |statement, results|
        next if @template.client_only?(statement)

        statement.start_with?("SELECT ") ? results << @connection.select_all(statement) : @connection.execute(statement)
      end
    end

    # The staged relation types as this machine canonicalizes them (its relation_type_mappings rows
    # included). A variant whose canonical twin is staged on the same ends keeps its spelling (UPDATE
    # IGNORE skips it on the staging key): it is inserted as staged, and the next relation-type sweep
    # merges it into the twin.
    def canonicalize_relation_types!
      RelationTypeMapping.reset_canonicalize_cache!
      @connection.select_values("SELECT relation_type FROM gm_stage_relations GROUP BY BINARY relation_type").each do |stored|
        target = SqlExport::Template.relation_type(stored)
        next if target == stored

        @connection.execute("UPDATE IGNORE gm_stage_relations SET relation_type = #{@connection.quote(target)} " \
                            "WHERE BINARY relation_type = BINARY #{@connection.quote(stored)}")
      end
    end

    # Puts the session back as it was (the pooled connection outlives the run) and drops the gm_ tables.
    def with_session
      saved = @connection.select_rows(SESSION_READ).first
      yield
    ensure
      @connection.execute(@template.drop_statement)
      @connection.execute(VARIABLES_RESET)
      restore_session(*saved) if saved
    end

    def restore_session(mode, zone, client, connection_charset, collation, results)
      @connection.execute("SET SESSION sql_mode = #{@connection.quote(mode)}, SESSION time_zone = #{@connection.quote(zone)}, " \
                          "SESSION character_set_client = #{@connection.quote(client)}, " \
                          "SESSION character_set_connection = #{@connection.quote(connection_charset)}, " \
                          "SESSION collation_connection = #{@connection.quote(collation)}, " \
                          "SESSION character_set_results = #{@connection.quote(results)}")
    end
  end
end
