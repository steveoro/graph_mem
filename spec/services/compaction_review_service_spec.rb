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
end
