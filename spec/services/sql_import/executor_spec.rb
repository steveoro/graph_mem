# frozen_string_literal: true

require "rails_helper"

# The merge rules, guards and session handling of a graph_mem-sql import (the SynthPrj scenario is
# spec/integration/sql_exchange_synth_project_spec.rb). Real rows; the "source machine" is the same
# database before the edits.
RSpec.describe SqlImport::Executor do
  include ActiveSupport::Testing::TimeHelpers

  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component", description: "first", aliases: "Widget One") }

  def unchanged_graph
    snapshot = graph_snapshot
    yield.tap { expect(graph_snapshot).to eq(snapshot) }
  end

  it "takes a newer incoming row, keeps a newer local one, and keeps a tie local, listing it" do
    script = sql_export(project)
    widget.update_columns(description: "edited here, same updated_at")
    tie = sql_import(script)
    expect(widget.reload.description).to eq("edited here, same updated_at")
    expect(tie.affected).to contain_exactly(include("action" => "kept_local", "id" => widget.id, "changed" => include("description")))

    widget.update_columns(updated_at: 1.day.ago)
    newer = sql_import(script)
    expect(widget.reload).to have_attributes(description: "first", embedded_at: nil)
    expect(sql_counts(newer)).to include("entities/updated" => 1)
  end

  it "matches observations on SHA2 of the content, so a trailing space makes another fact" do
    fs_observe!(widget, "abc ")
    script = sql_export(project)
    MemoryObservation.find_by!(content: "abc ").update_columns(content: "abc")

    sql_import(script)

    expect(widget.memory_observations.pluck(:content)).to contain_exactly("abc", "abc ")
  end

  it "exports one copy per content, active first, and points the dropped copy's links at it" do
    kept = fs_observe!(widget, "duplicate fact")
    dropped = fs_observe!(widget, "duplicate fact")
    dropped.update_columns(status: "obsolete", obsoleted_at: Time.current)
    retired = fs_observe!(widget, "replaced fact")
    retired.update_columns(status: "superseded", obsoleted_at: Time.current, superseded_by_id: dropped.id)
    script = sql_export(project)
    sql_delete_tree!(project)

    sql_import(script)

    copy = MemoryEntity.find_by!(name: "SynthWidget")
    expect(copy.memory_observations.where(content: "duplicate fact").pluck(:status)).to eq([ "active" ])
    expect(copy.memory_observations.find_by!(content: "replaced fact").superseded_by.content).to eq(kept.content)
  end

  it "matches by alias, keeps the local name and adds the incoming one as an alias; an ambiguous alias inserts a new row" do
    fs_member!(project, "SynthGadget", "Component", aliases: "Gadget")
    script = sql_export(project)
    widget.update_columns(name: "Widget One", aliases: nil) # the target knows it by its alias
    MemoryEntity.find_by!(name: "SynthGadget").update_columns(name: "SynthGadget Old", aliases: "SynthGadget")
    fs_member!(project, "SynthGadget Twin", "Component", aliases: "SynthGadget")

    result = sql_import(script)

    expect(widget.reload).to have_attributes(name: "Widget One", aliases: "SynthWidget")
    expect(MemoryEntity.where(project_id: project.id, name: "SynthGadget").count).to eq(1)
    entities = result.affected.select { |row| row["table"] == "memory_entities" }
    expect(entities).to include(include("id" => widget.id, "action" => "updated", "detail" => "Component, matched by alias: SynthWidget"),
                                include("entity" => "SynthGadget", "action" => "new", "detail" => /matches several entities/))
  end

  it "links across the boundary only to an entity that exists here, and lists the skipped edge" do
    other = fs_project!("OtherPrj")
    outside = fs_member!(other, "SynthOutside", "Service")
    MemoryRelation.create!(from_entity: widget, to_entity: outside, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: widget, to_entity: other, relation_type: "relates_to")
    script = sql_export(project)
    outside.destroy!
    sql_delete_tree!(project)

    result = sql_import(script)

    copy = MemoryEntity.find_by!(name: "SynthWidget")
    expect(MemoryRelation.where(from_entity_id: copy.id).pluck(:relation_type)).to contain_exactly("part_of", "relates_to")
    expect(result.affected).to include(include("action" => "skipped_link", "detail" => "depends_on -> (missing) SynthOutside"))
  end

  it "skips a crossing part_of that would move the other end into this project (an edited file), instead of failing" do
    global = MemoryEntity.create!(name: "SynthGlobal", entity_type: "Service")
    MemoryRelation.create!(from_entity: widget, to_entity: global, relation_type: "depends_on")
    script = sql_export(project)
    edited = resign(script.sub(/^\((\d+), 2, 3, 'depends_on'/) { "(#{Regexp.last_match(1)}, 3, 2, 'part_of'" })
    expect(edited).not_to eq(resign(script))

    result = sql_import(edited)

    expect(result.affected).to include(include("action" => "skipped_link", "changed" => { "reason" => "it would move an entity into another project" }))
    expect(global.reload.project_id).to be_nil
  end

  it "canonicalizes staged relation types with this machine's mappings, but never turns a variant into part_of" do
    gadget = fs_member!(project, "SynthGadget", "Component")
    MemoryRelation.create!(from_entity: widget, to_entity: gadget, relation_type: "uses_synth")
    MemoryRelation.insert_all!([ { from_entity_id: gadget.id, to_entity_id: widget.id, relation_type: "child_of", properties: "{}",
                                   created_at: Time.current, updated_at: Time.current } ])
    script = sql_export(project)
    expect(script).to include("'child_of'")
    sql_delete_tree!(project)
    RelationTypeMapping.create!(variant: "uses_synth", canonical_type: "depends_on")

    sql_import(script)

    types = MemoryRelation.joins(:from_entity).pluck("memory_entities.name", :relation_type)
    expect(types).to include([ "SynthWidget", "depends_on" ], [ "SynthGadget", "child_of" ])
    expect(types.count { |_, type| type == "part_of" }).to eq(2)
  ensure
    RelationTypeMapping.reset_canonicalize_cache!
  end

  it "refuses a name that is a Project on one side and not on the other, writing nothing" do
    script = sql_export(project)
    sql_delete_tree!(project)
    MemoryEntity.create!(name: "SynthPrj", entity_type: "Preference")

    unchanged_graph { expect { sql_import(script) }.to raise_error(described_class::Refused, /"SynthPrj" is a Project on one side/) }
  end

  it "refuses a target older than the script, and a script format older than the target, naming both schemas" do
    here = ActiveRecord::Base.connection.select_value("SELECT MAX(version) FROM schema_migrations")
    future = resign(sql_export(project).sub("('schema', '#{here}')", "('schema', '29991231000000')"))
    unchanged_graph { expect { sql_import(future) }.to raise_error(described_class::Refused, /at schema #{here}, older than .*29991231000000/) }

    stub_const("SqlExport::Template::MAX_SCHEMA", { 1 => "20200101000000" })
    unchanged_graph { expect { sql_import(sql_export(project)) }.to raise_error(described_class::Refused, /up to 20200101000000, this database is at schema #{here}/) }
  end

  it "refuses an edit that leaves a member without its part_of edge (the membership check), writing nothing" do
    script = sql_export(project)
    sql_delete_tree!(project)
    edited = resign(script.sub(/INSERT INTO gm_stage_relations .*?;\n/m, ""))

    unchanged_graph { expect { sql_import(edited) }.to raise_error(described_class::Refused, /project of "SynthWidget" would not match/) }
  end

  it "refuses a part_of cycle the merge would close" do
    service = fs_member!(widget, "SynthService", "Service")
    script = travel_to(1.minute.from_now) { sql_export(project) }
    # Here: SynthService is under the root (older edge), SynthWidget under SynthService (newer edge).
    MemoryRelation.where(from_entity_id: [ widget.id, service.id ], relation_type: "part_of").delete_all
    MemoryRelation.create!(from_entity: service, to_entity: project, relation_type: "part_of").update_columns(updated_at: 1.day.ago)
    MemoryRelation.create!(from_entity: widget, to_entity: service, relation_type: "part_of").update_columns(updated_at: 1.day.from_now)

    unchanged_graph { expect { sql_import(script) }.to raise_error(described_class::Refused, /"SynthService" would be part_of itself/) }
  end

  it "waits for the membership lock and fails without writing when it stays busy" do
    script = sql_export(project)
    stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
    stub_const("SqlExchangeLockHolder", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    SqlExchangeLockHolder.establish_connection(ActiveRecord::Base.connection_db_config)
    holder = SqlExchangeLockHolder.connection
    holder.select_value("SELECT GET_LOCK(#{holder.quote(ProjectMembership.lock_name)}, 0)")

    unchanged_graph { expect { sql_import(script) }.to raise_error(ProjectMembership::LockTimeout) }
  ensure
    holder&.select_value("SELECT RELEASE_LOCK(#{holder.quote(ProjectMembership.lock_name)})")
    SqlExchangeLockHolder.connection_pool.disconnect! if defined?(SqlExchangeLockHolder)
  end

  it "asks compaction to pause, runs a dry run as a rollback, and puts the session back" do
    script = sql_export(project)
    sql_delete_tree!(project)
    connection = ActiveRecord::Base.connection
    session = connection.select_rows("SELECT @@SESSION.sql_mode, @@SESSION.time_zone, @@collation_connection").first
    allow(CompactionValve).to receive(:request_pause_if_running!).and_call_original

    result = unchanged_graph { sql_import(script, dry_run: true) }

    expect(CompactionValve).to have_received(:request_pause_if_running!)
    expect(result).to have_attributes(dry_run: true)
    expect(sql_counts(result)).to include("entities/new" => 2)
    expect(OperationProgress.count).to eq(0)
    expect(connection.select_rows("SELECT @@SESSION.sql_mode, @@SESSION.time_zone, @@collation_connection").first).to eq(session)
    expect(connection.select_value("SELECT @gm_operation_id")).to be_nil
    expect { connection.select_value("SELECT 1 FROM gm_stage_entities") }.to raise_error(ActiveRecord::StatementInvalid, /doesn't exist/)
  end
end
