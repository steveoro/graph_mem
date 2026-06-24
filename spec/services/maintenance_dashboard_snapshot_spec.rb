# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceDashboardSnapshot do
  after { CompactionRun.delete_all; MaintenanceReport.delete_all }

  describe ".call" do
    it "returns compaction, graph stats, reports, and schedules" do
      MemoryEntity.create!(name: "SnapEntity", entity_type: "Project")

      result = described_class.call

      expect(result).to include(:refreshed_at, :compaction, :graph_stats, :latest_reports, :schedules, :cursor_entity)
      expect(result[:graph_stats][:totals][:entities]).to be >= 1
      expect(result[:compaction]).to include(:dream_state)
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
  end
end
