# frozen_string_literal: true

require "rails_helper"

RSpec.describe GarbageCollectionRunner do
  describe ".call" do
    let!(:project) { MemoryEntity.create!(name: "GCRunnerProject", entity_type: "Project") }

    before { MemoryObservation.create!(memory_entity: project, content: "obs") }

    it "creates three maintenance reports and returns summaries" do
      MaintenanceReport.delete_all

      result = described_class.call

      expect(MaintenanceReport.count).to eq(3)
      expect(result[:reports].size).to eq(3)
      expect(result[:reports].map { |r| r[:report_type] }).to match_array(%w[orphans stale duplicates])
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
  end
end
