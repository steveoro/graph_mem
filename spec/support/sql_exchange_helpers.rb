# frozen_string_literal: true

# Helpers for the graph_mem-sql specs (SqlExport / SqlImport): write a script, import it, edit a
# script and sign it again (the header's sha256), and snapshot the graph tables.
module SqlExchangeHelpers
  GRAPH_TABLES = { memory_entities: MemoryEntity, memory_observations: MemoryObservation, memory_relations: MemoryRelation }.freeze

  # @return [String] the script for the roots
  def sql_export(*roots, include_nested: true)
    io = StringIO.new
    SqlExport::Writer.new(roots.map(&:id), include_nested: include_nested).write(io)
    io.string
  end

  # @return [SqlImport::Executor::Result]
  def sql_import(text, dry_run: false)
    SqlImport::Executor.call(SqlImport::Validator.validate(text), dry_run: dry_run)
  end

  # The script with its header's sha256 recomputed, as anyone editing a file could.
  def resign(text)
    header, body = text.split(/^(?=-- Everything in this file)/, 2)
    header.sub(/^-- sha256: \h+$/, "-- sha256: #{Digest::SHA256.hexdigest(body)}") + body
  end

  # Every row of the graph tables (embeddings left out), keyed by id.
  def graph_snapshot
    GRAPH_TABLES.transform_values do |model|
      model.order(:id).map { |row| [ row.id, row.attributes.except("embedding") ] }.to_h
    end
  end

  # The graph as names, ids left out: the round trip compares this.
  def graph_by_names(project)
    ids = [ project.id ] + ProjectMembership.member_ids(project.id).to_a
    names = MemoryEntity.where(id: ids).to_h { |entity| [ entity.id, entity.name ] }
    contents = MemoryObservation.where(memory_entity_id: ids).pluck(:id, :content).to_h
    {
      entities: MemoryEntity.where(id: ids).map { |e| [ e.name, e.entity_type, e.aliases, e.description, e.created_at, e.updated_at ] }.sort_by(&:first),
      observations: MemoryObservation.where(memory_entity_id: ids).map do |o|
        [ names[o.memory_entity_id], o.content, o.confidence, o.source, o.tags, o.status, o.obsoleted_at, o.obsolescence_reason,
          o.perspective, contents[o.superseded_by_id], o.created_at, o.updated_at ]
      end.sort_by { |row| row.first(2) },
      relations: MemoryRelation.where(from_entity_id: ids).or(MemoryRelation.where(to_entity_id: ids)).map do |r|
        [ names[r.from_entity_id], names[r.to_entity_id], r.relation_type, r.weight, r.properties, r.created_at, r.updated_at ]
      end.sort_by { |row| row.first(3).map(&:to_s) }
    }
  end

  # Deletes a project and its members with their observations and relations (no callbacks, no audit rows).
  def sql_delete_tree!(project)
    ids = [ project.id ] + ProjectMembership.member_ids(project.id).to_a
    MemoryRelation.where(from_entity_id: ids).or(MemoryRelation.where(to_entity_id: ids)).delete_all
    MemoryObservation.where(memory_entity_id: ids).update_all(superseded_by_id: nil, outdated_by_id: nil)
    MemoryObservation.where(memory_entity_id: ids).delete_all
    MemoryEntity.where(id: ids - [ project.id ]).delete_all
    project.delete
  end

  # Makes an SQL import fail once it committed, as an error on the way out of the run would (here after
  # the membership lock is released); the rows stay written.
  def fail_sql_import_after_commit!(message)
    allow(ProjectMembership).to receive(:with_membership_lock).and_wrap_original do |original, *args, **kwargs, &block|
      original.call(*args, **kwargs, &block).tap { raise ActiveRecord::StatementInvalid, message }
    end
  end

  # @return [Hash{String => Integer}] "table/action" => rows of a result's summary
  def sql_counts(result)
    result.summary.to_h { |row| [ "#{row['table'].delete_prefix('memory_')}/#{row['action']}", row["rows"] ] }
  end
end

RSpec.configure do |config|
  config.include SqlExchangeHelpers
end
