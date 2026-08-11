# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceDashboardSnapshot do
  after { CompactionRun.delete_all; MaintenanceReport.delete_all }

  describe ".call" do
    it "returns compaction, graph stats, reports, schedules, and project scans" do
      MemoryEntity.create!(name: "SnapEntity", entity_type: "Project")

      result = described_class.call

      expect(result).to include(:refreshed_at, :compaction, :graph_stats, :latest_reports, :schedules, :cursor_entity, :agent_contexts, :operations, :scan_reviews)
      expect(result[:graph_stats][:totals][:entities]).to be >= 1
      expect(result[:compaction]).to include(:dream_state)
      expect(result[:operations]).to include(:garbage_collection, :project_scans)
      expect(result[:scan_reviews]).to include(:count, :items)
    end

    it "resolves cursor entity when compaction has a cursor" do
      entity = MemoryEntity.create!(name: "CursorNode", entity_type: "Task")
      CompactionRun.create!(
        status: "running",
        phase: "orphans",
        cursor_entity_id: entity.id,
        stats: { "entities_processed" => 0, "merges_auto" => 0, "merges_queued" => 0,
                 "observations_deduped" => 0, "orphans_parented" => 0, "orphans_queued" => 0 }
      )

      result = described_class.call

      expect(result[:cursor_entity]).to eq(
        id: entity.id,
        name: "CursorNode",
        entity_type: "Task"
      )
    end

    it "includes latest maintenance reports by type" do
      MaintenanceReport.create!(report_type: "orphans", data: { count: 2, entities: [] })

      result = described_class.call

      expect(result[:latest_reports]["orphans"][:count]).to eq(2)
    end

    it "returns recent project_scan operations" do
      MemoryEntity.create!(name: "SnapEntity", entity_type: "Project")
      OperationProgress.create!(
        operation_type: "project_scan",
        operation_id: SecureRandom.uuid,
        status: "completed",
        total_count: 5,
        current_count: 5,
        percentage: 100.0,
        phase: "completed",
        details: { project_name: "graph-mem", mode: "initial", fallback: false }
      )

      result = described_class.call

      expect(result[:operations][:project_scans]).to be_an(Array)
      expect(result[:operations][:project_scans].size).to eq(1)
      expect(result[:operations][:project_scans].first).to include(operation: "project_scan", status: "completed")
    end

    it "includes active scan_review items" do
      entity = MemoryEntity.create!(name: "ReviewEntity", entity_type: "Task")
      report = MaintenanceReport.create!(report_type: "scan_review", data: { "source" => "test" })
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "scan_review",
        row_uuid: "scan-review-1",
        kind: "delete_entity",
        status: "active",
        signature: CompactionReviewService.signature_for("delete_entity", { entity_id: entity.id }),
        payload: { "entity_id" => entity.id, "reason" => "not found in project scan" }
      )

      result = described_class.call

      expect(result[:scan_reviews][:count]).to eq(1)
      expect(result[:scan_reviews][:items].map(&:row_uuid)).to include("scan-review-1")
    end
  end
end
