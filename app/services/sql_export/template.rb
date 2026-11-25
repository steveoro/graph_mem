# frozen_string_literal: true

module SqlExport
  # The fixed part of a graph_mem-sql script, one directory per format version under
  # lib/graph_mem/sql_exchange/ (v1: the plan's sections 1-8 as numbered files). A script is the header,
  # then #before_data (session, lock, transaction, staging tables), the staging INSERTs (the only part
  # that varies), then #after_data (guards, merge, checks, record, report, COMMIT). Both sides use it:
  # SqlExport::Writer writes it, SqlImport::Validator requires it byte for byte, and SqlImport::Executor
  # runs this app's copy of its statements.
  #
  #   template = SqlExport::Template.new(1)
  #   template.before_data              # => "-- Everything in this file but the staging INSERTs ...\nSET NAMES utf8mb4;\n..."
  #   template.columns("gm_stage_refs") # => %w[sk project_name name entity_type]
  #   template.statements(:merge).first # => "INSERT INTO gm_map_entities (sk, is_ref, scope_id) SELECT ..."
  class Template
    ROOT = Rails.root.join("lib/graph_mem/sql_exchange")
    # The format each version writes, and the newest schema (schema_migrations version) it supports.
    # A migration that touches memory_entities, memory_observations or memory_relations adds a new
    # version directory; any other migration moves the newest version's max_schema (a spec fails until
    # one of the two is done).
    MAX_SCHEMA = { 1 => "20261124120000" }.freeze
    CURRENT_VERSION = MAX_SCHEMA.keys.max
    # Never NO_BACKSLASH_ESCAPES: the writer quotes with connection.quote (backslash escapes), and the
    # validator reads quoted strings by the same rule.
    SQL_MODE = "STRICT_TRANS_TABLES,STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION"
    # The staging tables the data part may insert into, in the order the writer writes them, with the
    # exact column list of their INSERTs.
    COLUMNS = {
      "gm_stage_meta" => %w[k v],
      "gm_stage_entities" => %w[sk root_sk name entity_type aliases description created_at updated_at],
      "gm_stage_aliases" => %w[sk pos alias],
      "gm_stage_refs" => %w[sk project_name name entity_type],
      "gm_stage_observations" => %w[sk entity_sk content confidence source valid_from valid_until tags status obsoleted_at
                                    obsolescence_reason perspective superseded_by_sk outdated_by_sk created_at updated_at],
      "gm_stage_relations" => %w[sk from_sk to_sk relation_type weight confidence properties created_at updated_at]
    }.freeze
    BEFORE_DATA = %w[01_preamble].freeze
    GUARDS = %w[02_guards].freeze
    MERGE = %w[03_entities 04_observations 05_relations 06_checks 07_record 08_report].freeze
    # Statements a hand run needs and the app does itself (SqlImport::Executor): it holds the lock
    # through ProjectMembership.with_membership_lock and wraps the run in its own transaction.
    CLIENT_ONLY = [ /\ASTART TRANSACTION\z/, /\ACOMMIT\z/, /\ASET @gm_lock = GET_LOCK\(/ ].freeze

    # @param version [Integer]
    # @return [Boolean] whether this app has the template of that format version
    def self.known?(version) = MAX_SCHEMA.key?(version)

    # The relation type a script carries: MemoryRelation.canonical_relation_type, followed until stable
    # (RelationTypeSweep.target_type), except that a variant mapping to `part_of` that SQL doesn't read
    # as `part_of` ("child_of") keeps its spelling, as RelationTypeSweep never writes a part_of edge
    # either: the target's next sweep queues it for review.
    #
    # @param stored [String]
    # @return [String]
    def self.relation_type(stored)
      target = RelationTypeSweep.target_type(stored)
      return stored if target.blank? || (RelationTypeSweep.part_of?(target) && !MemoryRelation.reads_as_part_of?(stored))

      target
    end

    attr_reader :version

    # @param version [Integer] a known format version
    # @raise [ArgumentError] for a version this app has no template for
    def initialize(version = CURRENT_VERSION)
      raise ArgumentError, "graph_mem-sql v#{version} is not known here" unless self.class.known?(version)

      @version = version
    end

    # @return [String] the newest schema this version supports
    def max_schema = MAX_SCHEMA.fetch(version)

    # @return [String] the fixed text before the staging INSERTs
    def before_data = @before_data ||= render(BEFORE_DATA)

    # @return [String] the fixed text after the staging INSERTs
    def after_data = @after_data ||= render(GUARDS + MERGE)

    # @param table [String] a staging table
    # @return [Array<String>, nil] its INSERT column list, nil for any other table
    def columns(table) = COLUMNS[table]

    # @param part [Symbol] :before_data, :guards or :merge
    # @return [Array<String>] the part's statements, without delimiters (GraphMem::SqlStatements)
    def statements(part)
      @statements ||= {}
      @statements[part] ||= GraphMem::SqlStatements.split(render({ before_data: BEFORE_DATA, guards: GUARDS, merge: MERGE }.fetch(part)))
    end

    # @param statement [String]
    # @return [Boolean] a statement the app replaces with its own lock and transaction
    def client_only?(statement) = CLIENT_ONLY.any? { |pattern| statement.match?(pattern) }

    # @return [String] the DROP TEMPORARY TABLE statement of every gm_ table the script creates
    def drop_statement = statements(:before_data).find { |statement| statement.start_with?("DROP TEMPORARY TABLE") }

    private

    def render(names)
      values = { "format" => version.to_s, "max_schema" => max_schema, "sql_mode" => SQL_MODE, "lock_prefix" => ProjectMembership::LOCK_NAME_PREFIX }
      names.map { |name| ROOT.join("v#{version}", "#{name}.sql").read }.join.gsub(/\{\{(\w+)\}\}/) { values.fetch(Regexp.last_match(1)) }
    end
  end
end
