# frozen_string_literal: true

require "rails_helper"

# The SQL exchange plan's scenario: restore an older graph_mem-sql export of SynthPrj over a graph
# edited since, run it again, and the two companions (forward sync, fresh target). Real rows, no doubles.
RSpec.describe "graph_mem-sql: restore an older export over an edited graph" do
  include ActiveSupport::Testing::TimeHelpers

  let(:t0) { Time.utc(2026, 11, 20, 9, 0, 0) }

  # Step 1: SynthPrj <- ModuleA <- ServiceA1 <- MethodA1x, SynthPrj <- ModuleB <- ServiceB1 and
  # ModuleB <- ServiceB2 <- MethodB2x; each node with observations (one obsolete, one superseded).
  def build!
    travel_to(t0) do
      @prj = fs_project!("SynthPrj")
      @mod_a = fs_member!(@prj, "ModuleA#{SecureRandom.hex(3)}", "Module", aliases: "ModA")
      @svc_a1 = fs_member!(@mod_a, "ServiceA1#{SecureRandom.hex(3)}", "Service", description: "Runs the A1 jobs", aliases: "A1svc")
      @method = fs_member!(@svc_a1, "MethodA1x#{SecureRandom.hex(3)}", "Method")
      @mod_b = fs_member!(@prj, "ModuleB#{SecureRandom.hex(3)}", "Module")
      @svc_b1 = fs_member!(@mod_b, "ServiceB1#{SecureRandom.hex(3)}", "Service")
      @svc_b2 = fs_member!(@mod_b, "ServiceB2#{SecureRandom.hex(3)}", "Service")
      @method_b = fs_member!(@svc_b2, "MethodB2x#{SecureRandom.hex(3)}", "Method")
      [ @mod_a, @svc_a1, @method, @mod_b, @svc_b1, @svc_b2, @method_b ].each_with_index do |entity, index|
        fs_observe!(entity, "Fact #{index} about #{entity.name}", tags: [ "synth" ], confidence: 0.75)
        fs_observe!(entity, "Retired fact #{index}").mark_obsolete!(reason: "synthetic retire")
        fs_observe!(entity, "Old fact #{index}").supersede!({ content: "New fact #{index}" }, reason: "synthetic supersede")
      end
      @depends = MemoryRelation.create!(from_entity: @svc_a1, to_entity: @svc_b1, relation_type: "depends_on", weight: 0.5)
      MemoryRelation.create!(from_entity: @svc_b2, to_entity: @mod_a, relation_type: "relates_to")
    end
  end

  # Step 3, an hour later: new subnodes, changed nodes, missing rows, bystanders.
  def edit!
    travel_to(t0 + 1.hour) do
      @svc_a2 = fs_member!(@mod_a, "ServiceA2#{SecureRandom.hex(3)}", "Service")
      fs_observe!(@svc_a2, "ServiceA2 is new")
      @b_fact = fs_observe!(@mod_b, "ModuleB got a new fact")
      @svc_a1.update!(description: "Runs the A1 jobs, edited", aliases: "A1svc|A1service")
      @retagged = @mod_b.memory_observations.find_by(content: "Fact 3 about #{@mod_b.name}")
      @retagged.update!(tags: %w[synth edited], confidence: 0.9)
      @retired = @svc_b1.memory_observations.find_by(content: "Fact 4 about #{@svc_b1.name}").mark_obsolete!(reason: "edited")
      @moved = MemoryRelation.find_by(from_entity_id: @svc_b1.id, relation_type: "part_of")
      @moved.update!(to_entity: @mod_a)
      @method.destroy!
      @method_b.destroy!
      @svc_b2.destroy!
      @mod_a.memory_observations.find_by(content: "Fact 0 about #{@mod_a.name}").destroy!
      @depends.destroy!
      @other = fs_project!("OtherPrj")
      @other_twin = fs_member!(@other, @svc_a1.name, "Service", description: "OtherPrj's namesake")
      fs_observe!(@other_twin, "Belongs to OtherPrj")
      @global = MemoryEntity.create!(name: "SynthGlobal#{SecureRandom.hex(3)}", entity_type: "Preference")
    end
  end

  def table_counts = SqlExchangeHelpers::GRAPH_TABLES.transform_values(&:count)

  it "reinstates what is missing, keeps the newer local edits, touches nothing else, and is idempotent" do
    build!
    script = travel_to(t0 + 1.minute) { sql_export(@prj) }
    edit!
    before = graph_snapshot
    counts_before = table_counts
    snapshot_ids = before.transform_values { |rows| rows.keys.to_set }

    result = travel_to(t0 + 2.hours) { sql_import(script) }

    after = graph_snapshot
    expect(table_counts.map { |table, count| count >= counts_before[table] }).to all(be(true))
    # Every row there before is byte-identical (kept local, unchanged, bystanders, additions), but for the
    # observation counter of an entity that got a fact back.
    before.each do |table, rows|
      rows.each { |id, row| expect(after[table][id].except("memory_observations_count")).to eq(row.except("memory_observations_count")), "#{table} ##{id} changed" }
    end

    created = after.to_h { |table, rows| [ table, rows.except(*snapshot_ids[table]) ] }
    method = created[:memory_entities].values.find { |row| row["name"] == @method.name }
    expect(created[:memory_entities].values.map { |row| row["name"] }).to contain_exactly(@method.name, @method_b.name, @svc_b2.name)
    expect(created[:memory_entities].values).to all(include("project_id" => @prj.id, "embedded_at" => nil, "cloud_allowed" => false))
    expect(method).to include("entity_type" => "Method", "created_at" => @method.created_at, "updated_at" => @method.updated_at)
    expect(MemoryRelation.where(from_entity_id: method["id"], relation_type: "part_of").pluck(:to_entity_id)).to eq([ @svc_a1.id ])
    expect(MemoryRelation.find_by(from_entity_id: @svc_a1.id, to_entity_id: @svc_b1.id, relation_type: "depends_on")).to have_attributes(weight: 0.5)
    expect(created[:memory_observations].size).to eq(4 * 3 + 1) # three entities' four facts, ModuleA's fact 0
    old = MemoryObservation.find_by(memory_entity_id: method["id"], content: "Old fact 2")
    expect(old).to have_attributes(status: "superseded", superseded_by: MemoryObservation.find_by(memory_entity_id: method["id"], content: "New fact 2"))
    expect(MemoryObservation.find_by(memory_entity_id: method["id"], content: "Retired fact 2")).to have_attributes(status: "obsolete", obsolescence_reason: "synthetic retire")
    expect(created[:memory_observations].values).to all(include("embedded_at" => nil, "keywords_at" => nil))
    MemoryEntity.where(id: [ @prj.id ] + ProjectMembership.member_ids(@prj.id).to_a).find_each do |entity|
      expect(entity.memory_observations_count).to eq(entity.memory_observations.count)
      expect(MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").count).to eq(entity.id == @prj.id ? 0 : 1)
    end
    expect(MemoryEntity.where(name: @svc_a1.name).pluck(:project_id)).to contain_exactly(@prj.id, @other.id)

    counts = sql_counts(result)
    expect(counts.keys.grep(/updated/)).to be_empty
    expect(counts).to include("entities/new" => 3, "entities/kept_local" => 1, "observations/new" => 13,
                              "observations/kept_local" => 2, "relations/new" => 5, "relations/kept_local" => 1)
    listed = result.affected.group_by { |row| [ row["table"], row["action"] ] }.transform_values { |rows| rows.map { |row| row["id"] } }
    expect(listed.keys).to contain_exactly(*%w[entities observations relations].flat_map { |t| [ [ "memory_#{t}", "new" ], [ "memory_#{t}", "kept_local" ] ] })
    expect(listed[%w[memory_entities kept_local]]).to eq([ @svc_a1.id ])
    expect(listed[%w[memory_observations kept_local]]).to contain_exactly(@retagged.id, @retired.id)
    expect(listed[%w[memory_relations kept_local]]).to eq([ @moved.id ])
    expect(listed[%w[memory_entities new]]).to match_array(created[:memory_entities].keys)
    expect(listed[%w[memory_observations new]]).to match_array(created[:memory_observations].keys)

    reason = "sql_import:#{result.operation_id}"
    audits = AuditLog.where(reason: reason)
    expect(audits.pluck(:action).uniq).to eq([ "create" ])
    expect(audits.where(auditable_type: "MemoryEntity").pluck(:auditable_id)).to match_array(created[:memory_entities].keys)
    expect(audits.count).to eq(created.values.sum(&:size))
    expect(audits.where(auditable_id: [ @other.id, @other_twin.id, @global.id ], auditable_type: "MemoryEntity")).to be_empty
    expect(audits.first).to have_attributes(actor: "sql_import", change_set_id: nil)
    operation = OperationProgress.find_by!(operation_id: result.operation_id)
    expect(operation).to have_attributes(operation_type: "import", status: "completed")
    expect(operation.counters["memory_entities"]).to include("new" => 3, "kept_local" => 1)
    expect(operation.details).to include("format" => "sql", "roots" => [ "SynthPrj" ], "outside_app" => false, "affected_count" => result.affected.size)

    # Step 6: again, nothing changes and nothing is audited.
    second = travel_to(t0 + 3.hours) { sql_import(script) }
    expect(sql_counts(second).keys.map { |key| key.split("/").last }.uniq).to contain_exactly("unchanged", "kept_local")
    expect(graph_snapshot).to eq(after)
    expect(AuditLog.where(reason: "sql_import:#{second.operation_id}")).to be_empty
  end

  it "leaves no audit or operation row after a dry run or a failed run" do
    build!
    script = sql_export(@prj)
    sql_delete_tree!(@prj)
    audits = AuditLog.count
    snapshot = graph_snapshot

    dry = sql_import(script, dry_run: true)
    expect(sql_counts(dry)).to include("entities/new" => 8)
    broken = resign(script.sub('[\"synth\"]', '[\"synth\"')) # tags no longer JSON: the value guard refuses the run
    expect { sql_import(broken) }.to raise_error(SqlImport::Executor::Refused, /memory_observations\.tags is not JSON/)

    expect(graph_snapshot).to eq(snapshot)
    expect(AuditLog.count).to eq(audits)
    expect(OperationProgress.where(operation_type: "import")).to be_empty
  end

  it "forward sync: an export taken after the edits brings them to the step-1 graph as updates and additions" do
    build!
    script = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      edit!
      script = travel_to(t0 + 61.minutes) { sql_export(@prj) }
      raise ActiveRecord::Rollback # back to the step-1 graph, ids included
    end
    counts_before = table_counts

    result = travel_to(t0 + 2.hours) { sql_import(script) }

    expect(table_counts.map { |table, count| count >= counts_before[table] }).to all(be(true))
    expect(@svc_a1.reload).to have_attributes(description: "Runs the A1 jobs, edited", aliases: "A1svc|A1service", embedded_at: nil)
    retagged = @mod_b.memory_observations.find_by(content: "Fact 3 about #{@mod_b.name}")
    expect(retagged).to have_attributes(tags: %w[synth edited], confidence: 0.9)
    expect(@svc_b1.memory_observations.find_by(content: "Fact 4 about #{@svc_b1.name}")).to have_attributes(status: "obsolete", obsolescence_reason: "edited")
    expect(MemoryRelation.where(from_entity_id: @svc_b1.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ @mod_a.id ])
    expect(@svc_b1.reload.project_id).to eq(@prj.id)
    expect(MemoryEntity.find_by(name: @svc_a2.name, project_id: @prj.id).memory_observations.pluck(:content)).to eq([ "ServiceA2 is new" ])
    expect(@mod_b.memory_observations.pluck(:content)).to include("ModuleB got a new fact")
    expect(MemoryEntity.where(id: [ @method.id, @svc_b2.id, @method_b.id ]).count).to eq(3) # nothing deleted

    expect(sql_counts(result)).to include("entities/updated" => 1, "observations/updated" => 2, "relations/updated" => 1)
    update = AuditLog.find_by!(reason: "sql_import:#{result.operation_id}", auditable_type: "MemoryEntity", auditable_id: @svc_a1.id)
    expect(update).to have_attributes(action: "update")
    expect(update.changed_fields).to include("description" => { "from" => "Runs the A1 jobs", "to" => "Runs the A1 jobs, edited" },
                                             "aliases" => { "from" => "A1svc", "to" => "A1svc|A1service" })
    moved = AuditLog.find_by!(reason: "sql_import:#{result.operation_id}", auditable_type: "MemoryRelation", action: "update")
    expect(moved.changed_fields).to include("to_entity_id" => { "from" => @mod_b.id, "to" => @mod_a.id })
  end

  it "fresh target: the project is created from nothing, cloud access off, and matches the export" do
    build!
    edit!
    expected = graph_by_names(@prj)
    script = sql_export(@prj)
    other = graph_by_names(@other)
    sql_delete_tree!(@prj)

    sql_import(script)

    project = MemoryEntity.find_by!(name: "SynthPrj", project_id: nil)
    expect(project).to have_attributes(entity_type: "Project", cloud_allowed: false, cloud_root: nil, embedded_at: nil)
    expect(graph_by_names(project)).to eq(expected)
    expect(graph_by_names(@other)).to eq(other)
  end

  # Dream State R1b: after the swap a library is global, the Project's depends_on it. The Project's
  # script follows that edge one hop (SqlExport::Scope), so the library travels as rows with its
  # own part_of subtree, not only as a reference by name.
  describe "a Project whose library was swapped for its depends_on" do
    let(:operator) { "operator:synth@127.0.0.1" }

    def build_library!
      travel_to(t0) do
        @app = fs_project!("SynthApp")
        @widget = fs_member!(@app, "SynthWidget", "Component")
        @lib = fs_member!(@app, "SynthLib", "Gem", description: "Parses the feeds")
        @notes = fs_member!(@lib, "SynthLib Notes", "Documentation")
        fs_observe!(@app, "SynthApp uses SynthLib to parse its feeds.")
        fs_observe!(@lib, "SynthLib 2 needs Ruby 3.4.")
        fs_observe!(@notes, "Pin SynthLib below 3.")
      end
    end

    # The R1b-1 swap, through its review row (the pending one when it was queued already).
    def swap_library!(library = @lib, project = @app)
      relation = MemoryRelation.find_by!(from_entity_id: library.id, to_entity_id: project.id, relation_type: "part_of")
      names = { library.id => library.name, project.id => project.name }
      item = CompactionReviewApplier::RelationRetypeDependency.swap_item(relation, names, evidence: { entity_type: library.entity_type, facts: [] })
      row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).first ||
            MaintenanceReportRow.pending.find_by!(kind: "relation_retype", signature: "relation_retype|swap|#{relation.id}|depends_on")
      apply_row(row)
    end

    def apply_row(row) = Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid) }

    def global(name) = MemoryEntity.find_by!(name: name, project_id: nil)

    def depends_on?(from, to) = MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id, relation_type: "depends_on")

    def parent_ids(entity) = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").pluck(:to_entity_id)

    it "carries the library as rows: into an empty target it lands global with its children, SynthApp depends_on it, no drift" do
      build_library!
      expect(travel_to(t0 + 1.minute) { swap_library! }).to include(success: true)
      expected_app = graph_by_names(@app)
      expected_lib = graph_by_names(@lib)
      script = sql_export(@app)
      expect(script).to include("-- roots: SynthApp (Project)\n", "-- counts: entities=4 observations=3 relations=3 refs=0\n")
      sql_delete_tree!(@app)
      sql_delete_tree!(@lib)

      result = sql_import(script)

      app = global("SynthApp")
      lib = global("SynthLib")
      notes = global("SynthLib Notes")
      expect(lib).to have_attributes(entity_type: "Gem", description: "Parses the feeds")
      expect(depends_on?(app, lib)).to be(true)
      expect(parent_ids(lib)).to be_empty
      expect(parent_ids(notes)).to eq([ lib.id ])
      expect(graph_by_names(app)).to eq(expected_app)
      expect(graph_by_names(lib)).to eq(expected_lib)
      expect(sql_counts(result)).to include("entities/new" => 4, "observations/new" => 3, "relations/new" => 3)
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end

    it "merges into a target where the library is global already: matched by name, no duplicate" do
      build_library!
      swap_library!
      script = sql_export(@app)
      sql_delete_tree!(@app) # the target has the library global (it swapped too), but not the project
      fs_observe!(@lib, "Only the target knows this.")

      result = sql_import(script)

      app = global("SynthApp")
      expect(MemoryEntity.where(name: "SynthLib").pluck(:id)).to eq([ @lib.id ])
      expect(MemoryEntity.where(name: "SynthLib Notes").pluck(:id)).to eq([ @notes.id ])
      expect(depends_on?(app, @lib)).to be(true)
      expect(@lib.reload.project_id).to be_nil
      expect(@lib.memory_observations.pluck(:content)).to contain_exactly("SynthLib 2 needs Ruby 3.4.", "Only the target knows this.")
      expect(sql_counts(result)).to include("entities/new" => 2, "entities/unchanged" => 2, "relations/new" => 2, "relations/unchanged" => 1)
      expect(ProjectIdBackfill.drift.any?).to be(false)
    end

    it "exports the library alone with its subtree, and the Project only as a reference" do
      build_library!
      swap_library!

      script = sql_export(@lib)

      expect(script).to include("-- roots: SynthLib (Gem)\n", "-- counts: entities=2 observations=2 relations=2 refs=1\n")
      expect(script).to match(/INSERT INTO gm_stage_refs \(sk, project_name, name, entity_type\) VALUES\n\(3, NULL, 'SynthApp', 'Project'\);/)
      expect(script).not_to include("SynthWidget", "SynthApp uses SynthLib")
    end

    # A target that hasn't swapped yet holds the library as a project member. The script's library is
    # global, so the merge (which matches a global row in the global scope only) inserts a global copy
    # next to the member; the target's own swap then meets that copy and goes through the collision
    # flow, which queues the merge of the two libraries and of each same-named child pair.
    it "into a target that hasn't swapped: a global copy comes in next to the member, and the queued rows alone converge it" do
      build_library!
      script = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        travel_to(t0 + 1.minute) { swap_library! }
        script = sql_export(@app)
        raise ActiveRecord::Rollback # back to the unswapped graph: the target
      end
      expect(@lib.reload.project_id).to eq(@app.id)

      result = sql_import(script)

      copy = global("SynthLib")
      copy_notes = global("SynthLib Notes")
      expect(MemoryEntity.where(name: "SynthLib").pluck(:id, :project_id)).to contain_exactly([ @lib.id, @app.id ], [ copy.id, nil ])
      expect(parent_ids(@lib)).to eq([ @app.id ])
      expect(depends_on?(@app, copy)).to be(true)
      expect(parent_ids(copy_notes)).to eq([ copy.id ])
      expect(sql_counts(result)).to include("entities/new" => 2, "relations/new" => 2)
      expect(ProjectIdBackfill.drift.any?).to be(false)

      # The target's swap is refused (the global copy holds the name) and queues two merges: the copy into
      # the member, and the copy's child into the member's child of the same name and type.
      swap = swap_library!
      expect(swap).to include(success: false)
      expect(swap[:error]).to include("a global Gem 'SynthLib' (##{copy.id}) already has its name")
      merges = MaintenanceReportRow.where(kind: "entity_merge").order(:id).to_a
      expect(merges.map { |row| row.payload.values_at("entity_a", "entity_b").map { |side| side["entity_id"] } })
        .to eq([ [ copy.id, @lib.id ], [ copy_notes.id, @notes.id ] ])
      library_merge, child_merge = merges

      # The library merge first would move the copy's child into the project, where its name is taken.
      refused = apply_row(library_merge)
      expect(refused).to include(success: false)
      expect(refused[:error]).to include("SynthLib Notes")

      # The child merge, then the library merge, then the swap: the queued rows alone converge it.
      expect(apply_row(child_merge)).to include(success: true)
      expect(apply_row(library_merge)).to include(success: true)
      expect(swap_library!).to include(success: true)

      expect(MemoryEntity.where(name: "SynthLib").pluck(:id, :project_id)).to eq([ [ @lib.id, nil ] ])
      expect(MemoryEntity.where(name: "SynthLib Notes").pluck(:id, :project_id)).to eq([ [ @notes.id, nil ] ])
      expect(depends_on?(@app, @lib)).to be(true)
      expect(parent_ids(@lib)).to be_empty
      expect(parent_ids(@notes)).to eq([ @lib.id ])
      expect(ProjectIdBackfill.drift.any?).to be(false)
      expect(ProjectIdBackfill.new(out: StringIO.new).run.changed).to eq(0)
    end

    # An active fact tagged source-fact keeps its tag through the swap, but outside a project the tag is
    # inert and the model refuses it on save, as the import's checks would: the writer leaves it out.
    it "carries a swapped library's source fact active and without its tag; the source keeps the tag" do
      build_library!
      fact = fs_fact!(@lib, "SynthLib 3 replaces the old parser.", tags: [ "synth" ])
      swap_library!
      expect(fact.reload).to have_attributes(status: "active", tags: [ SourceFact::SOURCE_FACT_TAG, "synth" ])
      project_script = sql_export(@app)
      library_script = sql_export(@lib)
      expect(fact.reload.tags).to eq([ SourceFact::SOURCE_FACT_TAG, "synth" ])
      sql_delete_tree!(@app)
      sql_delete_tree!(@lib)

      sql_import(project_script)

      copy = global("SynthLib").memory_observations.find_by!(content: fact.content)
      expect(copy).to have_attributes(status: "active", tags: [ "synth" ])
      sql_delete_tree!(global("SynthApp"))
      sql_delete_tree!(global("SynthLib"))

      sql_import(library_script)

      expect(global("SynthLib").memory_observations.find_by!(content: fact.content)).to have_attributes(status: "active", tags: [ "synth" ])
    end
  end
end
