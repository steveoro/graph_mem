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

    it "prunes tool invocation telemetry using the configured retention" do
      previous = AppSettings.tool_invocation_retention_days
      AppSettings.tool_invocation_retention_days = 90
      old = ToolInvocation.create!(
        tool_name: "search",
        client_id: "gc-spec",
        outcome: "ok",
        duration_ms: 1,
        argument_keys: [],
        created_at: 91.days.ago
      )

      result = described_class.call

      expect(ToolInvocation.find_by(id: old.id)).to be_nil
      expect(result[:tool_invocations_pruned]).to be >= 1
    ensure
      AppSettings.tool_invocation_retention_days = previous
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

    # 1.86.0 (B3): the production chain: a supersede whose replacement was a byte-identical copy of a
    # same-entity fact. Deleting the copy used to null superseded_by (dependent: :nullify / the FK).
    it "repoints superseded_by and outdated_by links from deleted duplicates to the kept row" do
      gadget = fs_project!("Gadget Project")
      widget = fs_member!(gadget, "SynthWidget")
      fact = fs_fact!(widget, "SynthWidget renders with the canvas backend.")
      fact_twin = fs_fact!(widget, "SynthWidget renders with the canvas backend.")
      old = fs_observe!(widget, "SynthWidget renders with the SVG backend.")
      twin = old.supersede!({ content: fact.content }, reason: "Outdated by source fact ##{fact.id}", outdated_by: fact)
      retired = fs_observe!(widget, "SynthWidget renders with the WebGL backend.").mark_obsolete!(outdated_by: fact_twin)

      described_class.call

      expect(MemoryObservation.where(id: [ twin.id, fact_twin.id ])).to be_empty
      expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: fact.id, outdated_by_id: fact.id)
      expect(retired.reload.outdated_by_id).to eq(fact.id)
      expect(old).to be_valid
      expect(GraphIntegrityService.new.send(:detect_observation_lifecycle_corruption)).to be_empty
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
