# frozen_string_literal: true

require "digest"

module SqlExport
  # Writes a graph_mem-sql script (format SqlExport::Template::CURRENT_VERSION) for the given roots: the
  # header, then the template's fixed part around the staging INSERTs (at most BATCH_ROWS rows or
  # BATCH_BYTES per statement, every value through connection.quote). Ids travel only as staging keys;
  # no embedding, keyword, trust score or cloud column is written. The header names no host and no path.
  #
  #   SqlExport::Writer.new([ project.id ]).write_file("tmp/exports/synth_prj.sql")
  #   # => { entities: 84, observations: 912, relations: 140, refs: 3 }
  #   SqlExport::Writer.new([ project.id ]).write(io) { |table, rows| puts "#{table}: #{rows}" }
  class Writer
    MARKER = "-- graph_mem-sql v"
    BATCH_ROWS = 200
    BATCH_BYTES = 512 * 1024
    READ_BATCH = 1_000
    TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%6N"

    # @param root_ids [Array<Integer>] see SqlExport::Scope
    # @param include_nested [Boolean] see SqlExport::Scope
    def initialize(root_ids, include_nested: true)
      @scope = Scope.new(root_ids, include_nested: include_nested)
      @template = Template.new
      @connection = ActiveRecord::Base.connection
    end

    # @param path [String, Pathname]
    # @yieldparam table [String] the staging table just written
    # @yieldparam rows [Integer] its row count
    # @return [Hash{Symbol => Integer}] the counts written
    def write_file(path, &progress)
      File.open(path.to_s, "w") { |file| write(file, &progress) }
    end

    # @param io [IO] where the script goes
    # @yieldparam table [String]
    # @yieldparam rows [Integer]
    # @return [Hash{Symbol => Integer}] the counts written
    def write(io, &progress)
      Tempfile.create([ "graph_mem-sql", ".sql" ]) do |body|
        digest = Digest::SHA256.new
        emit = ->(text) { digest << text; body.write(text) }
        emit.call(@template.before_data)
        counts = write_data(emit, &progress)
        emit.call(@template.after_data)
        io.write(header(counts, digest.hexdigest))
        body.rewind
        IO.copy_stream(body, io)
        counts
      end
    end

    private

    def write_data(emit, &progress)
      assign_keys
      inserts(emit, "gm_stage_meta", meta_rows, &progress)
      inserts(emit, "gm_stage_entities", entity_rows, &progress)
      inserts(emit, "gm_stage_aliases", alias_rows, &progress)
      inserts(emit, "gm_stage_refs", ref_rows, &progress)
      inserts(emit, "gm_stage_observations", observation_rows, &progress)
      inserts(emit, "gm_stage_relations", relation_rows, &progress)
      { entities: @entity_sk.size, observations: @observation_sk.size, relations: @relation_count, refs: @scope.ref_ids.size }
    end

    # Staging keys: entities 1..n, then references, in one key space; observations 1..m.
    def assign_keys
      @entity_sk = @scope.entity_roots.keys.each_with_index.to_h { |id, index| [ id, index + 1 ] }
      @ref_sk = @scope.ref_ids.each_with_index.to_h { |id, index| [ id, @entity_sk.size + index + 1 ] }
      @observation_sk = @scope.observation_ids.each_with_index.to_h { |id, index| [ id, index + 1 ] }
      @entities = MemoryEntity.where(id: @scope.entity_roots.keys).index_by(&:id)
    end

    def meta_rows
      [ [ "format", @template.version.to_s ], [ "app", GraphMem::VERSION ], [ "schema", schema_version ],
        [ "exported_at", exported_at ], [ "roots", @scope.roots.map(&:name).to_json ] ]
    end

    def entity_rows
      @scope.entity_roots.map do |id, root_id|
        entity = @entities.fetch(id)
        [ @entity_sk[id], root_id ? @entity_sk.fetch(root_id) : 0, entity.name, entity.entity_type, entity.aliases,
          entity.description, time(entity.created_at), time(entity.updated_at) ]
      end
    end

    # One row per alias (split on , | ; as every reader does), without blanks, case-insensitive repeats
    # or the entity's own name: the importer's alias match and alias union read these.
    def alias_rows
      @entities.values.flat_map do |entity|
        names = entity.aliases.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?).uniq(&:downcase)
        names.reject { |name| name.casecmp?(entity.name.to_s.strip) }.each_with_index.map { |name, pos| [ @entity_sk[entity.id], pos, name ] }
      end
    end

    # The outside end of an edge crossing the boundary: its Project root's name (nil: global scope).
    def ref_rows
      refs = MemoryEntity.where(id: @scope.ref_ids).index_by(&:id)
      projects = MemoryEntity.where(id: refs.values.filter_map(&:project_id)).pluck(:id, :name).to_h
      @scope.ref_ids.map { |id| [ @ref_sk[id], projects[refs[id].project_id], refs[id].name, refs[id].entity_type ] }
    end

    def observation_rows
      columns = %w[id memory_entity_id content confidence source valid_from valid_until tags status obsoleted_at
                   obsolescence_reason perspective superseded_by_id outdated_by_id created_at updated_at]
      raw_rows(MemoryObservation, columns, @scope.observation_ids).map do |row|
        id, entity_id, *values, superseded_by, outdated_by, created_at, updated_at = row
        values = values.each_with_index.map { |value, index| [ 3, 4, 7 ].include?(index) ? time(value) : value }
        [ @observation_sk[id], @entity_sk.fetch(entity_id), *values, key_of(superseded_by, id), key_of(outdated_by, id),
          time(created_at), time(updated_at) ]
      end
    end

    # A link to a dropped duplicate points at its kept copy; a link to itself, or outside the export, is NULL.
    def key_of(linked_id, own_id)
      kept = @scope.link(linked_id)
      kept && kept != @scope.link(own_id) ? @observation_sk[kept] : nil
    end

    # Types as Template.relation_type gives them. Two stored variants of one type on the same ends (the
    # sweep hasn't merged them yet) would be one staging key: the row stored canonical wins, else the first.
    def relation_rows
      columns = %w[id from_entity_id to_entity_id relation_type weight confidence properties created_at updated_at]
      rows = raw_rows(MemoryRelation, columns, @scope.relation_ids).map do |_id, from, to, type, weight, confidence, properties, created_at, updated_at|
        [ entity_key(from), entity_key(to), Template.relation_type(type), weight, confidence, properties, time(created_at), time(updated_at), type ]
      end
      key = ->(row) { [ row[0], row[1], row[2].downcase ] }
      winners = rows.group_by(&key).transform_values { |group| group.find { |row| row[2] == row.last } || group.first }
      @relation_count = 0
      rows.select { |row| winners[key.call(row)].equal?(row) }.map { |row| [ @relation_count += 1, *row[0..-2] ] }
    end

    def entity_key(id) = @entity_sk[id] || @ref_sk.fetch(id)

    # Stored values as the database has them (JSON columns as their text, not deserialized), in id order.
    def raw_rows(model, columns, ids)
      ids.each_slice(READ_BATCH).flat_map { |slice| @connection.select_rows(model.where(id: slice).order(:id).select(*columns).arel) }
    end

    def inserts(emit, table, rows)
      columns = @template.columns(table)
      head = "INSERT INTO #{table} (#{columns.join(', ')}) VALUES\n"
      batch = []
      bytes = 0
      flush = lambda do
        emit.call("#{head}#{batch.join(",\n")};\n") if batch.any?
        batch = []
        bytes = 0
      end
      rows.each do |row|
        tuple = "(#{row.map { |value| @connection.quote(value) }.join(', ')})"
        flush.call if batch.size >= BATCH_ROWS || (batch.any? && bytes + tuple.bytesize > BATCH_BYTES)
        batch << tuple
        bytes += tuple.bytesize
      end
      flush.call
      yield table, rows.size if block_given?
    end

    def header(counts, digest)
      roots = @scope.roots.map { |root| "#{root.name} (#{root.entity_type})" }.join(", ")
      model = EmbeddingConfig.resolved_config.values_at(:model, :dims).join("/")
      lines = [ "#{MARKER}#{@template.version}",
                "app: #{GraphMem::VERSION}", "schema: #{schema_version}", "exported_at: #{exported_at}",
                "roots: #{roots}",
                "counts: #{counts.map { |key, count| "#{key}=#{count}" }.join(' ')}",
                "embedding_model: #{model} (informational)",
                "sha256: #{digest}" ]
      # A header line is a comment: no control character, and no /* (the validator refuses /*! there).
      lines.map { |line| "#{line.start_with?(MARKER) ? '' : '-- '}#{line.gsub(/[[:cntrl:]]/, ' ').gsub('/*', '/ *')}\n" }.join
    end

    def schema_version = @schema_version ||= @connection.select_value("SELECT MAX(version) FROM schema_migrations").to_s

    def exported_at = @exported_at ||= Time.current.utc.iso8601

    def time(value) = value&.utc&.strftime(TIME_FORMAT)
  end
end
