# frozen_string_literal: true

require "rails_helper"

RSpec.describe GarbageCollectionRunner do
  describe ".call" do
    let!(:project) { MemoryEntity.create!(name: "GCRunnerProject", entity_type: "Project") }

    before { MemoryObservation.create!(memory_entity: project, content: "obs") }

    it "creates two maintenance reports and returns summaries" do
      MaintenanceReport.delete_all

      result = described_class.call

      expect(MaintenanceReport.count).to eq(2)
      expect(result[:reports].size).to eq(2)
      expect(result[:reports].map { |r| r[:report_type] }).to match_array(%w[orphans duplicates])
    end

    it "prunes old audit logs" do
      old_log = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: project.id,
        action: "create", actor: "test", changed_fields: {},
        created_at: 91.days.ago
      )

      result = described_class.call

      expect(AuditLog.find_by(id: old_log.id)).to be_nil
      expect(result[:audit_logs_pruned]).to be >= 1
    end

    it "deletes duplicate observations and keeps the lowest id" do
      entity = MemoryEntity.create!(name: "DupEntity", entity_type: "Task")
      first = MemoryObservation.create!(memory_entity: entity, content: "dup note")
      MemoryObservation.create!(memory_entity: entity, content: "dup note")
      MemoryObservation.create!(memory_entity: entity, content: "dup note")

      entity.update_column(:memory_observations_count, 5)

      described_class.call

      expect(entity.memory_observations.pluck(:id)).to contain_exactly(first.id)
      expect(entity.reload.memory_observations_count).to eq(1)
    end

    it "reports deleted duplicate observations in the duplicates report" do
      entity = MemoryEntity.create!(name: "DupReportEntity", entity_type: "Task")
      MemoryObservation.create!(memory_entity: entity, content: "report dup")
      MemoryObservation.create!(memory_entity: entity, content: "report dup")

      result = described_class.call
      duplicates_report = result[:reports].find { |r| r[:report_type] == "duplicates" }

      expect(duplicates_report[:count]).to eq(1)
      expect(duplicates_report[:report_type]).to eq("duplicates")
    end
  end
end
