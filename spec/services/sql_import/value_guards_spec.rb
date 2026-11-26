# frozen_string_literal: true

require "rails_helper"

# The value guards of a graph_mem-sql script (02_guards.sql, and the source-fact rules in 06_checks.sql):
# the SQL path skips the model validations, so each example edits one staged value of a real export
# into one MemoryEntity, MemoryObservation or MemoryRelation would refuse, signs the file again (the
# validator only reads the grammar), and expects the import refused, naming the field, with nothing written.
# An outdated_by link the model would refuse is the exception: the merge drops it (04) and lists it.
RSpec.describe "graph_mem-sql: staged values the models would refuse" do
  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component", description: "renders") }
  let!(:gear) { fs_member!(project, "SynthGear", "Component") }
  let!(:fact) do
    fs_observe!(widget, "SynthWidget renders the dashboard.", confidence: 0.5, perspective: "world", tags: [ "synth" ],
                                                              valid_from: Time.utc(2026, 1, 1), valid_until: Time.utc(2026, 6, 1))
  end
  let!(:edge) do
    MemoryRelation.create!(from_entity: widget, to_entity: gear, relation_type: "depends_on", weight: 0.5, confidence: 0.5,
                           properties: { "k" => "v" })
  end
  let(:script) { sql_export(project) }
  let(:tags) { "'[\\\"synth\\\"]'" } # as connection.quote writes ["synth"]
  let(:properties) { "'{\\\"k\\\":\\\"v\\\"}'" }

  # The staged line of `text` that matches `pattern`.
  def line(pattern, text = script) = text[pattern] || raise("no staged line matches #{pattern.inspect}")
  def entity_line = line(/^\(\d+, 1, 'SynthWidget'.*$/)
  def fact_line = line(/^\(\d+, \d+, 'SynthWidget renders the dashboard\.'.*$/)
  def edge_line = line(/^\(\d+, \d+, \d+, 'depends_on'.*$/)

  # `text` with `old` replaced by `new` in its line `staged`, signed again.
  def edited(staged, old, new, text = script)
    changed = staged.sub(old) { new }
    raise "#{old.inspect} is not in #{staged.inspect}" if changed == staged

    resign(text.sub(staged) { changed })
  end

  # `staged` with its created_at or updated_at (the last two values of every staged line) set to `value`.
  def dated(staged, column, value, text = script)
    created, updated = staged.scan(/'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6})'/).flatten.last(2)
    edited(staged, "'#{created}', '#{updated}')", column == :created_at ? "'#{value}', '#{updated}')" : "'#{created}', '#{value}')", text)
  end

  # The UTC clock of the database plus `hours`, as the writer formats a timestamp.
  def db_clock_plus(hours)
    ActiveRecord::Base.connection.select_value("SELECT DATE_FORMAT(UTC_TIMESTAMP(6) + INTERVAL #{Integer(hours)} HOUR, '%Y-%m-%d %H:%i:%s.%f')")
  end

  # Imports `text` on the current graph and expects the refusal, with nothing written.
  def refused(text, message)
    snapshot = graph_snapshot
    records = [ AuditLog.count, OperationProgress.count ]
    expect(SqlImport::Validator.validate(text)).to be_a(SqlImport::Validator::Script)
    expect { sql_import(text) }.to raise_error(SqlImport::Executor::Refused, message)
    expect(graph_snapshot).to eq(snapshot)
    expect([ AuditLog.count, OperationProgress.count ]).to eq(records)
  end

  context "with the exported tree gone (the import would write every row)" do
    before do
      script
      sql_delete_tree!(project)
    end

    it "imports the edges of each range the models accept" do
      text = edited(fact_line, "dashboard.', 0.5,", "dashboard.', 1,")
      text = edited(line(/^.*'depends_on'.*$/, text), "'depends_on', 0.5, 0.5, #{properties}", "'depends_on', 0, 0, '{}'", text)
      staged = line(/^.*'SynthWidget renders the dashboard\.'.*$/, text)
      text = edited(staged, "'2026-06-01 00:00:00.000000', #{tags}, 'active', NULL, NULL, 'world'",
                    "'2026-01-01 00:00:00.000000', '[]', 'active', NULL, NULL, 'experience'", text)

      sql_import(text)

      copy = MemoryObservation.find_by!(content: fact.content)
      expect(copy).to have_attributes(confidence: 1.0, perspective: "experience", tags: [], valid_until: copy.valid_from)
      expect(MemoryRelation.find_by!(relation_type: "depends_on")).to have_attributes(weight: 0.0, confidence: 0.0, properties: {})
      expect([ copy, *MemoryEntity.all, *MemoryRelation.all ]).to all(be_valid)
    end

    describe "MemoryEntity" do
      it "refuses a blank name, Unicode whitespace included" do
        refused(edited(entity_line, "'SynthWidget'", "'  '"), /memory_entities\.name is blank \(staged entity \d+\)/)
        refused(edited(entity_line, "'SynthWidget'", "' \t　'"), /memory_entities\.name is blank/)
      end

      it "takes a name that only looks blank (a zero-width space), as the model does" do
        sql_import(edited(entity_line, "'SynthWidget'", "'​'"))

        expect(MemoryEntity.find_by!(name: "​")).to be_valid
      end

      it "refuses a blank entity_type" do
        refused(edited(entity_line, "'Component'", "''"), /memory_entities\.entity_type is blank for "SynthWidget"/)
      end

      it "refuses a Project root typed Project only under the collation: its members' project_id must point at a Project" do
        root = line(/^\(1, 0, 'SynthPrj', 'Project'.*$/)

        refused(edited(root, "'Project'", "'project'"), /memory_entities\.entity_type "project" of "SynthPrj" is not exactly Project/)
      end
    end

    describe "MemoryObservation" do
      it "refuses a status that is not one of STATUSES (compared exactly)" do
        refused(edited(fact_line, "'active'", "'Active'"), /memory_observations\.status "Active" is not active, obsolete or superseded/)
      end

      it "refuses blank content" do
        refused(edited(fact_line, "'SynthWidget renders the dashboard.'", "' \t '"),
                /memory_observations\.content is blank \(staged observation \d+ on "SynthWidget"\)/)
      end

      it "refuses a confidence outside 0..1" do
        refused(edited(fact_line, "dashboard.', 0.5,", "dashboard.', 7.5,"), /memory_observations\.confidence 7\.5 is not between 0 and 1/)
        refused(edited(fact_line, "dashboard.', 0.5,", "dashboard.', -0.1,"), /memory_observations\.confidence -0\.1 is not between/)
      end

      it "refuses a perspective that is not one of PERSPECTIVES (compared exactly)" do
        refused(edited(fact_line, "'world'", "'bogus'"), /memory_observations\.perspective "bogus" is not world or experience/)
        refused(edited(fact_line, "'world'", "'World'"), /memory_observations\.perspective "World" is not world or experience/)
      end

      it "refuses a valid_until before valid_from" do
        refused(edited(fact_line, "'2026-06-01 00:00:00.000000'", "'2025-06-01 00:00:00.000000'"),
                /memory_observations\.valid_until 2025-06-01 00:00:00\.000000 is before valid_from 2026-01-01 00:00:00\.000000/)
      end

      it "refuses tags that are not an array of strings" do
        refused(edited(fact_line, tags, "'\\\"notalist\\\"'"), /memory_observations\.tags is not an array of strings/)
        refused(edited(fact_line, tags, "'[\\\"synth\\\", 1]'"), /memory_observations\.tags is not an array of strings/)
        refused(edited(fact_line, tags, "'[[\\\"synth\\\"]]'"), /memory_observations\.tags is not an array of strings/)
      end

      it "refuses tags that are not JSON at all, naming the field" do
        refused(edited(fact_line, tags, "'x'"), /memory_observations\.tags is not JSON/)
        refused(edited(fact_line, tags, "'['"), /memory_observations\.tags is not JSON/)
      end
    end

    describe "MemoryRelation" do
      it "refuses a blank relation_type" do
        refused(edited(edge_line, "'depends_on'", "' '"),
                /memory_relations\.relation_type is blank \(staged relation \d+ from "SynthWidget" to "SynthGear"\)/)
      end

      it "refuses a negative weight" do
        refused(edited(edge_line, "'depends_on', 0.5,", "'depends_on', -4,"), /memory_relations\.weight -4 is below 0/)
      end

      it "refuses a confidence outside 0..1" do
        refused(edited(edge_line, "'depends_on', 0.5, 0.5,", "'depends_on', 0.5, 9,"), /memory_relations\.confidence 9 is not between 0 and 1/)
      end

      it "refuses properties that are not a JSON object" do
        refused(edited(edge_line, properties, "'[1]'"), /memory_relations\.properties is not a JSON object/)
        refused(edited(edge_line, properties, "'null'"), /memory_relations\.properties is not a JSON object/)
      end

      it "refuses properties that are not JSON at all, naming the field" do
        refused(edited(edge_line, properties, "'x'"), /memory_relations\.properties is not JSON/)
      end
    end
  end

  describe "timestamps more than a day ahead of the UTC clock here (they would win every newer-wins compare)" do
    before do
      script
      sql_delete_tree!(project)
    end

    it "refuses a created_at or updated_at dated 2099, naming the table and the row" do
      future = "2099-01-01 00:00:00.000000"
      refused(dated(entity_line, :updated_at, future),
              /memory_entities\.updated_at 2099-01-01 00:00:00\.000000 is more than a day ahead of the clock here \(UTC .*\): staged entity \d+ "SynthWidget"/)
      refused(dated(fact_line, :created_at, future), /memory_observations\.created_at 2099-01-01 .*: staged observation \d+ on "SynthWidget"/)
      refused(dated(edge_line, :updated_at, future), /memory_relations\.updated_at 2099-01-01 .*: staged relation \d+ from "SynthWidget" to "SynthGear"/)
    end

    it "allows one day for clock skew: 23 hours ahead is imported, 25 hours ahead is refused" do
      refused(dated(entity_line, :updated_at, db_clock_plus(25)), /memory_entities\.updated_at .* is more than a day ahead/)

      ahead = db_clock_plus(23)
      sql_import(dated(entity_line, :updated_at, ahead))

      expect(MemoryEntity.find_by!(name: "SynthWidget").updated_at).to eq(Time.find_zone("UTC").parse(ahead))
    end
  end

  describe "the source-fact rules of MemoryObservation (after the merge, on a new row or a changed field)" do
    # The writer leaves that tag out (1.95.0, SqlExport::Writer#tags_for), so the file is edited to carry it.
    it "refuses a source-fact tag on an entity outside a project on a new row, not on a matched row it leaves as it is" do
      global = MemoryEntity.create!(name: "SynthNotes", entity_type: "Preference")
      fs_observe!(global, "Synth notes are kept here.").update_columns(tags: [ SourceFact::SOURCE_FACT_TAG ]) # a fact whose entity left its project
      exported = sql_export(global)
      notes = edited(line(/^\(\d+, \d+, 'Synth notes are kept here\.'.*$/, exported), "'[]'", "'[\\\"#{SourceFact::SOURCE_FACT_TAG}\\\"]'", exported)
      expect(sql_counts(sql_import(notes))).to eq("entities/unchanged" => 1, "observations/unchanged" => 1)
      global.memory_observations.delete_all
      global.delete

      refused(notes, /memory_observations\.tags: a source-fact on "SynthNotes" needs an entity inside a project/)
    end

    it "drops an outdated_by link to a fact that lost its source-fact tag, keeping the row as the model accepts it, and lists the link" do
      source_fact = fs_fact!(gear, "SynthGear replaces the old renderer.")
      outdated = fs_observe!(widget, "SynthWidget used the old renderer.", tags: [ "synth" ])
      outdated.mark_obsolete!(reason: "Outdated by source fact ##{source_fact.id}", outdated_by: source_fact)
      source_fact.update!(tags: []) # after it outdated the observation
      kept = outdated.reload.attributes.slice("content", "status", "obsoleted_at", "obsolescence_reason", "tags", "created_at", "updated_at")
      exported = sql_export(project)
      sql_delete_tree!(project) # a fresh target

      result = sql_import(exported)

      copy = MemoryObservation.find_by!(content: outdated.content)
      expect(copy.attributes).to include(kept.merge("outdated_by_id" => nil))
      expect(copy).to be_valid
      fact_copy = MemoryObservation.find_by!(content: source_fact.content)
      expect(result.affected).to include(include("table" => "memory_observations", "action" => "dropped_link", "id" => copy.id, "entity" => "SynthWidget",
                                                 "detail" => "outdated_by -> ##{fact_copy.id} SynthGear replaces the old renderer.",
                                                 "changed" => { "reason" => "the observation it names is not a source fact of the same project" }))
      expect(OperationProgress.find_by!(operation_id: result.operation_id).details["affected"])
        .to include(include("action" => "dropped_link", "id" => copy.id, "fields" => [ "reason" ]))
      expect(sql_counts(result)).to eq("entities/new" => 3, "observations/new" => 3, "relations/new" => 3) # a note, not a row action
      expect(AuditLog.where(reason: "sql_import:#{result.operation_id}", auditable_id: copy.id).pluck(:action)).to eq([ "create" ])
    end

    it "keeps an outdated_by link to a source fact of the same project" do
      source_fact = fs_fact!(gear, "SynthGear replaces the old renderer.")
      fs_observe!(widget, "SynthWidget used the old renderer.").mark_obsolete!(reason: "synthetic retire", outdated_by: source_fact)
      exported = sql_export(project)
      sql_delete_tree!(project)

      result = sql_import(exported)

      expect(MemoryObservation.find_by!(content: "SynthWidget used the old renderer.").outdated_by.content).to eq(source_fact.content)
      expect(result.affected.map { |row| row["action"] }).not_to include("dropped_link")
    end

    it "drops a staged outdated_by link that names the observation itself, one not in the file, or sits on an active row" do
      source_fact = fs_fact!(gear, "SynthGear replaces the old renderer.")
      fs_observe!(widget, "SynthWidget used the old renderer.").mark_obsolete!(reason: "synthetic retire", outdated_by: source_fact)
      exported = sql_export(project)
      sql_delete_tree!(project)
      staged = line(/^\(\d+, \d+, 'SynthWidget used the old renderer\.'.*$/, exported)
      own = staged[/\A\((\d+),/, 1]
      link = staged[/, NULL, NULL, (\d+), '[^']*', '[^']*'\)[,;]\z/, 1] or raise("no outdated_by key in #{staged}")

      { ", NULL, NULL, #{own}, '" => "it names the observation itself",
        ", NULL, NULL, 999, '" => "the observation it names is not in the file" }.each do |edit, reason|
        result = sql_import(edited(staged, ", NULL, NULL, #{link}, '", edit, exported))
        copy = MemoryObservation.find_by!(content: "SynthWidget used the old renderer.")
        expect(copy).to have_attributes(status: "obsolete", outdated_by_id: nil).and(be_valid)
        expect(result.affected).to include(include("action" => "dropped_link", "id" => copy.id, "changed" => { "reason" => reason }))
        sql_delete_tree!(MemoryEntity.find_by!(name: "SynthPrj"))
      end
      result = sql_import(edited(staged, "'obsolete'", "'active'", exported))
      copy = MemoryObservation.find_by!(content: "SynthWidget used the old renderer.")
      expect(copy).to have_attributes(status: "active", obsoleted_at: nil, outdated_by_id: nil).and(be_valid)
      expect(result.affected).to include(include("action" => "dropped_link", "id" => copy.id,
                                                 "changed" => { "reason" => "an active observation has no outdated_by" }))
    end
  end
end
