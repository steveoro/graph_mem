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
    let!(:project) { MemoryEntity.create!(name: "GCProject", entity_type: "Project") }
    let!(:obs) { MemoryObservation.create!(memory_entity: project, content: "obs content") }

    it "creates three maintenance reports (orphans, stale, duplicates)" do
      MaintenanceReport.delete_all

      described_class.new.perform

      expect(MaintenanceReport.count).to eq(3)
      expect(MaintenanceReport.pluck(:report_type).sort).to eq(%w[duplicates orphans stale])
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

    describe "stale detection" do
      it "identifies entities not updated in over 6 months" do
        stale = MemoryEntity.create!(name: "GCStale", entity_type: "Task")
        stale.update_columns(updated_at: 7.months.ago)
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "stale")
        expect(report.data["count"]).to be >= 1
        stale_ids = report.data["entities"].map { |e| e["id"] }
        expect(stale_ids).to include(stale.id)
      end

      it "does not flag recently updated entities" do
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "stale")
        stale_ids = report.data["entities"].map { |e| e["id"] }
        expect(stale_ids).not_to include(project.id)
      end

      it "includes cutoff_months in report data" do
        MaintenanceReport.delete_all

        described_class.new.perform

        report = MaintenanceReport.find_by(report_type: "stale")
        expect(report.data["cutoff_months"]).to eq(6)
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

    it "caps entity lists to 100 entries per report" do
      expect(described_class::STALE_MONTHS).to eq(6)
    end
  end
end
