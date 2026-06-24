# frozen_string_literal: true

require "rails_helper"

RSpec.describe GarbageCollectionJob, type: :job do
  include ActiveJob::TestHelper

  describe "job queueing" do
    it "queues on the default queue" do
      expect {
        described_class.perform_later
      }.to have_enqueued_job(described_class).on_queue("default")
    end
  end

  describe "#perform" do
    it "skips when garbage collector is disabled" do
      AppSettings.enable_garbage_collector = false

      expect(GarbageCollectionRunner).not_to receive(:call)
      described_class.new.perform
    end

    let!(:project) { MemoryEntity.create!(name: "GCProject", entity_type: "Project") }
    let!(:obs) { MemoryObservation.create!(memory_entity: project, content: "obs content") }

    it "creates two maintenance reports (orphans, duplicates)" do
      MaintenanceReport.delete_all

      described_class.new.perform

      expect(MaintenanceReport.count).to eq(2)
      expect(MaintenanceReport.pluck(:report_type).sort).to eq(%w[duplicates orphans])
    end

    describe "orphan detection" do
      it "identifies entities with no observations and no relations" do
        orphan = MemoryEntity.create!(name: "GCOrphan", entity_type: "Task")
        orphan.memory_observations.destroy_all
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "orphans")
        expect(report.data["count"]).to be >= 1
        orphan_ids = report.data["entities"].map { |e| e["id"] }
        expect(orphan_ids).to include(orphan.id)
      end

      it "does not flag entities that have observations" do
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "orphans")
        orphan_ids = report.data["entities"].map { |e| e["id"] }
        expect(orphan_ids).not_to include(project.id)
      end

      it "does not flag entities involved in relations" do
        related = MemoryEntity.create!(name: "GCRelated", entity_type: "Task")
        MemoryRelation.create!(from_entity: project, to_entity: related, relation_type: "part_of")
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "orphans")
        orphan_ids = report.data["entities"].map { |e| e["id"] }
        expect(orphan_ids).not_to include(related.id)
      end
    end

    describe "duplicate observation detection" do
      it "identifies duplicate observations on the same entity" do
        MemoryObservation.create!(memory_entity: project, content: "duplicate content")
        MemoryObservation.create!(memory_entity: project, content: "duplicate content")
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "duplicates")
        expect(report.data["count"]).to be >= 1
      end

      it "does not flag unique observations" do
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "duplicates")
        dup_entity_ids = report.data["observations"].map { |o| o["entity_id"] }
        expect(dup_entity_ids.count(project.id)).to eq(0) unless MemoryObservation.where(memory_entity: project).group(:content).having("COUNT(*) > 1").exists?
      end
    end

    describe "audit log pruning" do
      it "deletes audit logs older than MAX_AGE_DAYS" do
        old_log = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: project.id,
          action: "create", actor: "test", changed_fields: {},
          created_at: 91.days.ago
        )

        described_class.new.perform

        expect(AuditLog.find_by(id: old_log.id)).to be_nil
      end

      it "keeps recent audit logs" do
        recent_log = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: project.id,
          action: "create", actor: "test", changed_fields: {}
        )

        described_class.new.perform

        expect(AuditLog.find_by(id: recent_log.id)).to be_present
      end
    end

    it "caps entity lists to 100 entries per orphan report" do
      MaintenanceReport.delete_all
      105.times do |i|
        MemoryEntity.create!(name: "GCOrphanCap#{i}", entity_type: "Task")
      end

      described_class.new.perform

      report = MaintenanceReport.find_by(report_type: "orphans")
      expect(report.data["entities"].size).to eq(100)
    end
  end
end
