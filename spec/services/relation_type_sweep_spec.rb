# frozen_string_literal: true

require "rails_helper"

# R1a: RelationTypeSweep canonicalizes stored relation types (plan item 3).
RSpec.describe RelationTypeSweep do
  let(:suffix) { SecureRandom.hex(3) }
  let(:service) { MemoryEntity.create!(name: "SynthService #{suffix}", entity_type: "Service") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let(:project) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }

  # A relation stored with a raw type, as rows written before the fold-on-write rule are: the save
  # callback would canonicalize it, so the type is written with update_column.
  def stored_relation(from, to, stored_type, **attributes)
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}",
                                      **attributes)
    relation.update_column(:relation_type, stored_type)
    relation
  end

  def retype_rows
    MaintenanceReportRow.where(kind: "relation_retype")
  end

  around do |example|
    RelationTypeMapping.reset_canonicalize_cache!
    example.run
  ensure
    RelationTypeMapping.reset_canonicalize_cache!
  end

  describe "per relation" do
    it "leaves a byte-identical canonical type alone" do
      relation = MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on")

      summary = described_class.call

      expect(summary[:counts]).to include("scanned" => 1, "unchanged" => 1)
      expect(summary[:changes]).to be_empty
      expect(relation.reload.relation_type).to eq("depends_on")
      expect(ChangeSet.where(kind: "dream.relation_types")).to be_empty
    end

    it "updates a case-only variant in place: the row is its own twin, never merged into itself" do
      relation = stored_relation(service, widget, "Depends_On", weight: 0.4)

      summary = described_class.call

      expect(relation.reload.relation_type).to eq("depends_on")
      expect(relation.weight).to eq(0.4)
      expect(MemoryRelation.where(from_entity_id: service.id).count).to eq(1)
      expect(summary[:changes]).to contain_exactly(include("relation_id" => relation.id, "action" => "case_only",
                                                          "old_type" => "Depends_On", "new_type" => "depends_on"))
      expect(described_class.twin_id(service.id, widget.id, "depends_on", except_id: relation.id)).to be_nil
    end

    it "retypes a mapped variant in place when no canonical twin exists, folding spaces and hyphens first" do
      mapped = stored_relation(service, widget, "requires")
      folded = stored_relation(widget, service, "Has Many")

      summary = described_class.call

      expect(mapped.reload.relation_type).to eq("depends_on")
      expect(folded.reload.relation_type).to eq("has_many")
      expect(summary[:counts]).to include("retyped" => 2)
      audit = AuditLog.where(auditable_type: "MemoryRelation", auditable_id: mapped.id, action: "update").last
      expect(audit.changed_fields["relation_type"]).to eq("from" => "requires", "to" => "depends_on")
      expect(audit.actor).to eq(RelationTypeSweep::DEFAULT_ACTOR)
      expect(audit.change_set.kind).to eq("dream.relation_types")
    end

    it "merges a variant into its canonical twin, keeping the higher weight and confidence" do
      twin = MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on", weight: 0.2, confidence: 0.9)
      variant = stored_relation(service, widget, "requires", weight: 0.7, confidence: 0.3)

      summary = described_class.call

      expect(MemoryRelation.exists?(variant.id)).to be(false)
      expect(twin.reload).to have_attributes(weight: 0.7, confidence: 0.9, relation_type: "depends_on")
      expect(summary[:changes]).to contain_exactly(include("relation_id" => variant.id, "action" => "merged", "merged_into_id" => twin.id))
      delete_audit = AuditLog.find_by(auditable_type: "MemoryRelation", auditable_id: variant.id, action: "delete")
      expect(delete_audit.reason).to eq("relation type canonicalized: merged into ##{twin.id}")
    end

    it "gives an empty twin the variant's properties, and keeps them under merged_from otherwise" do
      bare_twin = MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on")
      stored_relation(service, widget, "requires", properties: { "via" => "synth gem" })
      full_twin = MemoryRelation.create!(from_entity: widget, to_entity: service, relation_type: "calls", properties: { "hot" => true })
      variant = stored_relation(widget, service, "invokes", properties: { "via" => "synth rpc" })

      described_class.call

      expect(bare_twin.reload.properties).to eq("via" => "synth gem")
      expect(full_twin.reload.properties).to eq(
        "hot" => true,
        "merged_from" => [ { "relation_id" => variant.id, "relation_type" => "invokes", "properties" => { "via" => "synth rpc" } } ]
      )
    end

    it "merges a part_of variant into an existing part_of twin: no membership change" do
      twin = MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of")
      ProjectMembership.sync!(widget)
      variant = stored_relation(widget, project, "child_of")

      summary = described_class.call

      expect(MemoryRelation.exists?(variant.id)).to be(false)
      expect(twin.reload.relation_type).to eq("part_of")
      expect(widget.reload.project_id).to eq(project.id)
      expect(summary[:counts]).to include("merged" => 1, "queued" => 0)
      expect(retype_rows).to be_empty
    end

    it "queues a part_of variant without a twin as one relation_retype row, never twice" do
      variant = stored_relation(widget, project, "child_of", weight: 0.5)

      first = described_class.call
      second = described_class.call

      expect(variant.reload.relation_type).to eq("child_of")
      expect(widget.reload.project_id).to be_nil
      expect(retype_rows.count).to eq(1)
      row = retype_rows.first
      expect(row.payload).to eq(
        "kind" => "relation_retype", "operation" => "retype", "relation_id" => variant.id,
        "from_entity_id" => widget.id, "from_name" => widget.name, "to_entity_id" => project.id, "to_name" => project.name,
        "old_type" => "child_of", "new_type" => "part_of", "reason" => row.payload["reason"]
      )
      expect(row.payload["reason"]).to include("child_of", "part_of")
      expect(first[:changes]).to contain_exactly(include("action" => "queued", "review_row_id" => row.row_uuid))
      expect(second[:counts]).to include("queued" => 0, "already_queued" => 1)
      expect(second[:changes]).to contain_exactly(include("action" => "already_queued", "review_row_id" => row.row_uuid))
    end

    it "does not queue a dismissed suggestion again" do
      stored_relation(widget, project, "contained_in")
      described_class.call
      CompactionReviewService.dismiss(retype_rows.first.row_uuid, reason: "keep the variant")

      summary = described_class.call

      expect(retype_rows.count).to eq(1)
      expect(summary[:counts]).to include("already_queued" => 1, "queued" => 0)
    end

    it "keeps a stored part_of: an operator row can't remap a vocabulary type, and the guard holds anyway" do
      RelationTypeMapping.create!(variant: "part_of", canonical_type: "contains")
      relation = fs_member!(project, widget).relations_from.find_by!(to_entity: project)
      expect(described_class.call[:counts]).to include("unchanged" => 1)

      # The guard behind it: were a stored part_of ever to canonicalize to another type, it is left alone.
      allow(described_class).to receive(:target_type).and_call_original
      allow(described_class).to receive(:target_type).with("part_of").and_return("contains")
      summary = described_class.call

      expect(relation.reload.relation_type).to eq("part_of")
      expect(summary[:changes]).to contain_exactly(include("action" => "skipped_part_of", "new_type" => "contains"))
    end
  end

  describe "dry run" do
    it "changes nothing and reports the same counts as the real run" do
      stored_relation(service, widget, "Depends_On")
      stored_relation(widget, service, "requires")
      MemoryRelation.create!(from_entity: service, to_entity: project, relation_type: "calls")
      stored_relation(service, project, "invokes")
      stored_relation(widget, project, "child_of")
      before = MemoryRelation.order(:id).pluck(:id, :relation_type, :weight)

      dry = described_class.call(dry_run: true)

      expect(MemoryRelation.order(:id).pluck(:id, :relation_type, :weight)).to eq(before)
      expect(MaintenanceReport.where(report_type: "relation_type_sweep")).to be_empty
      expect(retype_rows).to be_empty
      expect(ChangeSet.where(kind: "dream.relation_types")).to be_empty
      expect(dry[:report_id]).to be_nil

      real = described_class.call
      expect(real[:counts]).to eq(dry[:counts])
      expect(real[:counts]).to include("scanned" => 5, "unchanged" => 1, "case_only" => 1, "retyped" => 1, "merged" => 1, "queued" => 1)
      expect(real[:changes].map { |change| change.except("review_row_id") }).to eq(dry[:changes])
    end
  end

  describe "several variants of one type on the same endpoints, no canonical row yet" do
    def variants(*types) = types.map { |type| stored_relation(service, widget, type, weight: 0.1 * types.index(type)) }

    it "retypes the first and merges the next into it, and the dry run counts the same" do
      first, second = variants("Has Many", "has-many")

      dry = described_class.call(dry_run: true)
      real = described_class.call

      expect(real[:counts]).to eq(dry[:counts])
      expect(real[:counts]).to include("retyped" => 1, "merged" => 1, "error" => 0)
      expect(real[:changes]).to eq(dry[:changes])
      expect(real[:changes].last).to include("relation_id" => second.id, "action" => "merged", "merged_into_id" => first.id)
      expect(MemoryRelation.where(from_entity_id: service.id).pluck(:id, :relation_type)).to eq([ [ first.id, "has_many" ] ])
    end

    it "merges every later variant into the first, three of them" do
      first, = variants("Has Many", "has-many", "HAS  many")

      dry = described_class.call(dry_run: true)
      real = described_class.call

      expect(real[:counts]).to eq(dry[:counts])
      expect(real[:counts]).to include("retyped" => 1, "merged" => 2, "error" => 0)
      expect(real[:changes].drop(1).map { |change| change["merged_into_id"] }).to eq([ first.id, first.id ])
    end

    it "counts the same when the pair is split across two batches" do
      stub_const("RelationTypeSweep::BATCH_SIZE", 1)
      first, = variants("Has Many", "has-many")

      dry = described_class.call(dry_run: true)
      real = described_class.call

      expect(real[:counts]).to eq(dry[:counts])
      expect(real[:counts]).to include("scanned" => 2, "retyped" => 1, "merged" => 1, "error" => 0)
      expect(real[:changes].last["merged_into_id"]).to eq(first.id)
    end
  end

  it "is idempotent: a second run changes nothing" do
    stored_relation(service, widget, "requires")
    stored_relation(widget, service, "Has-Many")
    described_class.call

    second = described_class.call

    expect(second[:counts]).to include("scanned" => 2, "unchanged" => 2)
    expect(second[:changes]).to be_empty
  end

  describe "batches, change sets and the report" do
    it "walks every relation across batch boundaries, one non-undoable change set per batch that wrote" do
      stub_const("RelationTypeSweep::BATCH_SIZE", 2)
      relations = Array.new(5) { |index| stored_relation(service, MemoryEntity.create!(name: "SynthPart #{suffix} #{index}", entity_type: "Component"), "requires") }

      summary = described_class.call

      expect(relations.map { |relation| relation.reload.relation_type }).to all(eq("depends_on"))
      expect(summary[:counts]).to include("scanned" => 5, "retyped" => 5)
      sets = ChangeSet.where(kind: "dream.relation_types").order(:id)
      expect(sets.size).to eq(3)
      expect(sets.map(&:undoable?)).to all(be(false))
      expect(sets.map(&:not_undoable_reason).uniq).to eq([ "relation_canonicalization" ])
      expect(sets.first.summary).to eq("relation types canonicalized: 2 retyped")
      expect(MaintenanceReport.find(summary[:report_id]).data["change_sets"]).to eq(sets.map(&:uuid))
    end

    it "refuses the generic undo of its change set with the reason" do
      stored_relation(service, widget, "requires")
      described_class.call
      set = ChangeSet.find_by!(kind: "dream.relation_types")

      result = ChangeSetUndo.call(set.uuid, actor: "operator:synth")

      expect(result.status).to eq(:not_undoable)
      expect(result.message).to include("relation types canonicalized by the sweep can't be restored")
      expect(MemoryRelation.where(from_entity_id: service.id).pluck(:relation_type)).to eq([ "depends_on" ])
    end

    it "ends with a report listing every change, capped, with counts covering the whole run" do
      stub_const("RelationTypeSweep::MAX_REPORTED_CHANGES", 2)
      twin = MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on")
      merged = stored_relation(service, widget, "requires")
      queued = stored_relation(widget, project, "child_of")
      stored_relation(service, project, "invokes")

      summary = described_class.call(actor: "rake:canonicalize_relations", source: "rake")

      report = MaintenanceReport.find(summary[:report_id])
      expect(report.report_type).to eq("relation_type_sweep")
      expect(report.data).to include("source" => "rake", "actor" => "rake:canonicalize_relations", "changes_omitted" => 1)
      expect(report.data["finished_at"]).to be_present
      expect(report.data["counts"]).to include("scanned" => 4, "unchanged" => 1, "merged" => 1, "queued" => 1, "retyped" => 1)
      expect(report.data["changes"]).to eq([
        { "relation_id" => merged.id, "action" => "merged", "old_type" => "requires", "new_type" => "depends_on",
          "from_entity_id" => service.id, "to_entity_id" => widget.id, "merged_into_id" => twin.id },
        { "relation_id" => queued.id, "action" => "queued", "old_type" => "child_of", "new_type" => "part_of",
          "from_entity_id" => widget.id, "to_entity_id" => project.id, "review_row_id" => retype_rows.first.row_uuid }
      ])
    end

    it "writes a report even when there is nothing to scan" do
      summary = described_class.call

      expect(MaintenanceReport.find(summary[:report_id]).data["counts"]).to include("scanned" => 0)
    end
  end

  it "recomputes trust scores once per endpoint of a merged variant" do
    observation = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders the synth dashboard")
    MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on")
    stored_relation(service, widget, "requires")
    observation.update_column(:trust_score, 0.0)

    described_class.call

    expect(observation.reload.trust_score).to eq(ObservationTrustRanker.rank(observation))
    expect(observation.trust_score).to be > 0.0
  end

  # A mapping added in the web process must reach a sweep the job worker starts right after it,
  # even when the worker's cache answered nil for the type a moment before.
  it "drops the process's mapping cache before a run" do
    relation = stored_relation(service, widget, "synth_links_to")
    expect(MemoryRelation.mapped_relation_type("synth_links_to")).to be_nil
    RelationTypeMapping.create!(variant: "synth_links_to", canonical_type: "depends_on")

    described_class.call

    expect(relation.reload.relation_type).to eq("depends_on")
  end
end
