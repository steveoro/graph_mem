# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionReviewService, type: :service do
  let!(:source) { MemoryEntity.create!(name: "Source Task", entity_type: "Task") }
  let!(:target) { MemoryEntity.create!(name: "Target Task", entity_type: "Task") }
  let!(:from_entity) { MemoryEntity.create!(name: "Issue A", entity_type: "Issue") }
  let!(:to_entity) { MemoryEntity.create!(name: "Solution B", entity_type: "PossibleSolution") }
  let!(:project) { MemoryEntity.create!(name: "Project X", entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE) }

  let!(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" }) }

  let!(:merge_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "merge-1",
      kind: "entity_merge",
      status: "active",
      signature: described_class.signature_for("entity_merge", {
        entity_a: { entity_id: source.id },
        entity_b: { entity_id: target.id }
      }),
      payload: {
        "entity_a" => { "entity_id" => source.id, "name" => source.name, "entity_type" => source.entity_type },
        "entity_b" => { "entity_id" => target.id, "name" => target.name, "entity_type" => target.entity_type },
        "cosine_distance" => 0.12,
        "score" => 0.88
      }
    )
  end

  let!(:orphan_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "orphan-1",
      kind: "orphan_parent",
      status: "active",
      signature: described_class.signature_for("orphan_parent", { entity_id: 99 }),
      payload: {
        "entity_id" => 99,
        "entity_name" => "Orphan",
        "entity_type" => "Task",
        "suggested_parents" => [
          { "project_id" => project.id, "project_name" => project.name, "score" => 0.9 }
        ],
        "score" => 0.9
      }
    )
  end

  let!(:relation_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "relation-1",
      kind: "relationship_proposal",
      status: "active",
      signature: described_class.signature_for("relationship_proposal", {
        from_entity_id: from_entity.id,
        to_entity_id: to_entity.id,
        relation_type: "solves"
      }),
      payload: {
        "from_entity_id" => from_entity.id,
        "from_name" => from_entity.name,
        "from_entity_type" => from_entity.entity_type,
        "to_entity_id" => to_entity.id,
        "to_name" => to_entity.name,
        "to_entity_type" => to_entity.entity_type,
        "relation_type" => "solves",
        "confidence_band" => "high",
        "score" => 10
      }
    )
  end

  let(:integrity_keep) do
    MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity, relation_type: "relates_to")
  end

  let(:integrity_duplicate) do
    relation = MemoryRelation.new(from_entity: to_entity, to_entity: from_entity, relation_type: "relates_to")
    relation.save!(validate: false)
    relation
  end

  let(:integrity_row) do
    payload = {
      "issue_kind" => "reverse_pair",
      "payload" => {
        "kind" => "reverse_pair",
        "keep_id" => integrity_keep.id,
        "delete_id" => integrity_duplicate.id,
        "keep" => { "id" => integrity_keep.id },
        "delete" => { "id" => integrity_duplicate.id }
      }
    }

    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "integrity-1",
      kind: "relation_integrity",
      status: "active",
      signature: described_class.signature_for("relation_integrity", payload),
      payload: payload
    )
  end

  describe ".latest_report" do
    it "returns the latest compaction review report" do
      expect(described_class.latest_report).to eq(report)
    end
  end

  describe ".items" do
    it "paginates active items with root nodes first" do
      items = described_class.items

      expect(items.count).to eq(3)
      expect(items.first.kind).to eq("orphan_parent")
    end

    it "filters ignored items" do
      described_class.ignore("merge-1")

      items = described_class.items(status: "active")
      expect(items.count).to eq(2)
      expect(items.map(&:row_uuid)).not_to include("merge-1")
    end

    it "filters by status" do
      described_class.ignore("merge-1")
      expect(described_class.items(status: "ignored").map(&:row_uuid)).to include("merge-1")
    end
  end

  describe ".find_item" do
    it "locates a row by uuid" do
      item = described_class.find_item("merge-1")
      expect(item).to eq(merge_row)
    end

    it "returns nil for an unknown uuid" do
      expect(described_class.find_item("missing")).to be_nil
    end
  end

  describe ".ignore" do
    it "marks the row as ignored" do
      expect(described_class.ignore("merge-1")[:success]).to be true
      expect(described_class.find_item("merge-1").status).to eq("ignored")
    end
  end

  describe ".edit_item" do
    it "stores editable payload overrides" do
      result = described_class.edit_item("merge-1", { "source_id" => target.id, "target_id" => source.id })

      expect(result[:success]).to be true
      merge_row.reload
      expect(merge_row.edited_payload["source_id"]).to eq(target.id)
      expect(merge_row.edited_payload["target_id"]).to eq(source.id)
    end

    it "rejects edits to non-existent entities" do
      result = described_class.edit_item("merge-1", { "source_id" => 0 })

      expect(result[:success]).to be false
      expect(result[:error]).to match(/Entity.*does not exist/)
    end
  end

  describe ".apply" do
    it "merges two task entities" do
      result = described_class.apply("merge-1", { "source_id" => source.id, "target_id" => target.id })

      expect(result[:success]).to be true
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
      expect(MemoryEntity.find_by(id: target.id)).to be_present
      expect(described_class.find_item("merge-1").status).to eq("approved")
    end

    it "creates a relationship between two entities" do
      result = described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })

      expect(result[:success]).to be true
      expect(MemoryRelation.find_by(from_entity_id: from_entity.id, to_entity_id: to_entity.id, relation_type: "solves")).to be_present
      expect(described_class.find_item("relation-1").status).to eq("approved")
    end

    it "applies a relation integrity repair and tolerates stale deleted relations" do
      integrity_row
      result = described_class.apply("integrity-1")

      expect(result[:success]).to be true
      expect(result[:deleted_relation_ids]).to eq([ integrity_duplicate.id ])
      expect(MemoryRelation.find_by(id: integrity_keep.id)).to be_present
      expect(MemoryRelation.find_by(id: integrity_duplicate.id)).to be_nil
      expect(described_class.find_item("integrity-1").status).to eq("approved")

      stale_row = integrity_row.dup
      stale_row.row_uuid = "integrity-stale"
      stale_row.status = "active"
      stale_row.save!
      expect(described_class.apply("integrity-stale")[:success]).to be true
    end

    it "refuses to apply a dismissed or approved row" do
      row = described_class.find_item("relation-1")

      row.update!(status: "dismissed", dismissed_at: Time.current)
      expect(described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })[:success]).to be false

      row.update!(status: "approved", applied_at: Time.current)
      expect(described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })[:success]).to be false
    end

    it "rolls the edge back when membership sync fails — failure must not orphan the row" do
      part_of_edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity,
                                            relation_type: "part_of")
      delete_row = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-rel-1",
        kind: "delete_relation",
        status: "active",
        signature: described_class.signature_for("delete_relation", { relation_id: part_of_edge.id }),
        payload: { "relation_id" => part_of_edge.id }
      )
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::Collision, "name clash")

      result = described_class.apply(delete_row.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.find_by(id: part_of_edge.id)).to be_present
    end

    it "applying a part_of relationship_proposal syncs the child's project scope" do
      project = MemoryEntity.create!(name: "PropProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-1",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      result = described_class.apply(proposal.row_uuid)

      expect(result[:success]).to be true
      expect(orphan.reload.project_id).to eq(project.id)
    end

    it "a part_of proposal under a held lock fails the apply and writes nothing" do
      stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
      project = MemoryEntity.create!(name: "PropLockProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropLockOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-lock",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      conn = ActiveRecord::Base.connection
      name = ProjectMembership.lock_name(conn)
      holder = stub_const("PropLockHolder",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

      result = described_class.apply(proposal.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.exists?(from_entity: orphan, to_entity: project,
                                    relation_type: "part_of")).to be false
      expect(orphan.reload.project_id).to be_nil
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
    end

    it "rolls the edge back on a LockTimeout — a busy lock is a failed apply, not a partial write" do
      part_of_edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity,
                                            relation_type: "part_of")
      delete_row = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-rel-lock",
        kind: "delete_relation",
        status: "active",
        signature: described_class.signature_for("delete_relation", { relation_id: part_of_edge.id }),
        payload: { "relation_id" => part_of_edge.id }
      )
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::LockTimeout, "lock held")

      result = described_class.apply(delete_row.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.find_by(id: part_of_edge.id)).to be_present
    end
  end

  describe "relation integrity review rows" do
    it "uses a stable signature for every selected duplicate relation" do
      payload = {
        issue_kind: "merge_collision",
        payload: { keep_id: 10, delete_ids: [ 13, 11, 12 ] }
      }

      expect(described_class.signature_for("relation_integrity", payload))
        .to eq("relation_integrity|merge_collision|10|11-12-13")
    end

    it "can dismiss and restore a queued integrity repair" do
      integrity_row

      expect(described_class.dismiss("integrity-1")[:success]).to be(true)
      expect(integrity_row.reload.status).to eq("dismissed")
      expect(described_class.restore("integrity-1")[:success]).to be(true)
      expect(integrity_row.reload.status).to eq("active")
    end
  end

  describe ".dismiss" do
    it "marks the row dismissed and records a suppression signature" do
      expect(described_class.dismiss("merge-1")[:success]).to be true

      merge_row.reload
      expect(merge_row.status).to eq("dismissed")
      expect(MaintenanceReportSuppression.suppressed?("compaction_review", merge_row.signature)).to be true
    end
  end

  describe ".restore" do
    it "sets the row back to active" do
      described_class.dismiss("merge-1")
      expect(described_class.restore("merge-1")[:success]).to be true
      expect(described_class.find_item("merge-1").status).to eq("active")
    end
  end

  describe ".seed_report" do
    let!(:seed_source) { MemoryEntity.create!(name: "Seed Source", entity_type: "Task") }
    let!(:seed_target) { MemoryEntity.create!(name: "Seed Target", entity_type: "Task") }

    it "creates rows for new suggestions and skips duplicates" do
      items = [
        {
          id: "new-1",
          kind: "entity_merge",
          entity_a: { entity_id: seed_source.id, name: seed_source.name, entity_type: seed_source.entity_type },
          entity_b: { entity_id: seed_target.id, name: seed_target.name, entity_type: seed_target.entity_type },
          cosine_distance: 0.15,
          score: 0.85
        }
      ]

      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows.size).to eq(1)

      # re-seeding the same pair is skipped because an active row already exists
      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows).to be_empty
    end

    it "skips suppressed suggestions" do
      described_class.dismiss("merge-1")
      merge_row.destroy!

      items = [
        {
          id: "new-2",
          kind: "entity_merge",
          entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
          entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type },
          cosine_distance: 0.12,
          score: 0.88
        }
      ]

      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows).to be_empty
    end
  end

  describe ".apply_action" do
    it "returns an error for unknown kinds" do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "unknown-1",
        kind: "entity_error",
        status: "active",
        signature: "entity_error|1",
        payload: { "entity_id" => 1, "error_message" => "boom" }
      )

      result = described_class.apply("unknown-1")
      expect(result[:success]).to be false
    end
  end

  describe ".items with q" do
    it "matches names and ids inside the payload, case-insensitively" do
      expect(described_class.items(q: "source task").map(&:row_uuid)).to include("merge-1")
      expect(described_class.items(q: "SOURCE TASK").map(&:row_uuid)).to include("merge-1")
    end

    it "matches the kind string and returns nothing on a miss" do
      expect(described_class.items(q: "orphan_parent").map(&:row_uuid)).to eq([ "orphan-1" ])
      expect(described_class.items(q: "zzz-no-such-text")).to be_empty
    end
  end

  describe ".kind_counts" do
    it "groups active queue rows by kind" do
      counts = described_class.kind_counts
      expect(counts["entity_merge"]).to eq(1)
      expect(counts["orphan_parent"]).to eq(1)
      expect(counts["relationship_proposal"]).to eq(1)
    end
  end

  describe ".bulk_apply" do
    let!(:proposable_target) { MemoryEntity.create!(name: "Other B", entity_type: "PossibleSolution") }

    it "applies selected actionable rows and skips non-actionable ones" do
      described_class.dismiss("orphan-1")

      result = described_class.bulk_apply([ "merge-1", "orphan-1", "rel-1" ])

      expect(result[:success]).to be true
      expect(result[:message]).to include("skipped")
      expect(described_class.find_item("orphan-1").status).to eq("dismissed")
    end

    it "reports per-row failures without aborting the batch" do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "ghost-1",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|999999",
        payload: { "entity_id" => 999_999, "entity_name" => "Ghost" }
      )

      result = described_class.bulk_apply([ "merge-1", "ghost-1" ])

      expect(result[:success]).to be false
      expect(result[:message]).to include("failed")
      expect(result[:message]).to include("Entity not found")
    end

    it "refuses an empty selection" do
      expect(described_class.bulk_apply([])[:success]).to be false
    end
  end

  describe ".delete_children_info" do
    let!(:parent_entity) { MemoryEntity.create!(name: "Parent C", entity_type: "Class") }
    let!(:queued_child) { MemoryEntity.create!(name: "Queued Child", entity_type: "Method") }
    let!(:lone_child) { MemoryEntity.create!(name: "Lone Child", entity_type: "Method") }
    let!(:delete_row) do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-1",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|#{parent_entity.id}",
        payload: { "entity_id" => parent_entity.id, "entity_name" => parent_entity.name }
      )
    end

    before do
      MemoryRelation.create!(from_entity: queued_child, to_entity: parent_entity, relation_type: "part_of")
      MemoryRelation.create!(from_entity: lone_child, to_entity: parent_entity, relation_type: "part_of")
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-child",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|#{queued_child.id}",
        payload: { "entity_id" => queued_child.id, "entity_name" => queued_child.name }
      )
    end

    it "splits children into queued-for-deletion vs parentless" do
      info = described_class.delete_children_info(report_type: "compaction_review", items: [ delete_row ])

      expect(info[parent_entity.id]).to eq(queued: 1, parentless: 1)
    end

    it "ignores dismissed delete rows when counting queued children" do
      described_class.dismiss("del-child")

      info = described_class.delete_children_info(report_type: "compaction_review", items: [ delete_row ])

      expect(info[parent_entity.id]).to eq(queued: 0, parentless: 2)
    end

    it "returns empty for pages without delete_entity rows" do
      expect(described_class.delete_children_info(report_type: "compaction_review", items: [ merge_row ])).to eq({})
    end
  end
end
