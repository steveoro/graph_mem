# frozen_string_literal: true

require "rails_helper"

RSpec.describe Auditable, type: :model do
  describe "audit on create" do
    it "creates an audit log entry when an entity is created" do
      expect {
        MemoryEntity.create!(name: "AuditableCreate", entity_type: "Project")
      }.to change(AuditLog, :count).by_at_least(1)

      log = AuditLog.recent.first
      expect(log.action).to eq("create")
      expect(log.auditable_type).to eq("MemoryEntity")
      expect(log.changed_fields).to have_key("name")
    end

    it "records the actor from Current.actor" do
      Current.actor = "test:create_spec"
      entity = MemoryEntity.create!(name: "AuditableActor", entity_type: "Project")

      log = AuditLog.for_record("MemoryEntity", entity.id).recent.first
      expect(log.actor).to eq("test:create_spec")
    ensure
      Current.actor = nil
    end

    it "creates an audit log for observations" do
      entity = MemoryEntity.create!(name: "AuditableObsParent", entity_type: "Project")

      expect {
        MemoryObservation.create!(memory_entity: entity, content: "auditable obs")
      }.to change { AuditLog.where(auditable_type: "MemoryObservation").count }.by(1)
    end

    it "creates an audit log for relations" do
      e1 = MemoryEntity.create!(name: "AuditRelFrom", entity_type: "Project")
      e2 = MemoryEntity.create!(name: "AuditRelTo", entity_type: "Task")

      expect {
        MemoryRelation.create!(from_entity: e1, to_entity: e2, relation_type: "part_of")
      }.to change { AuditLog.where(auditable_type: "MemoryRelation").count }.by(1)
    end
  end

  describe "audit on update" do
    let!(:entity) { MemoryEntity.create!(name: "AuditableUpdate", entity_type: "Project") }

    it "creates an audit log entry when an entity is updated" do
      expect {
        entity.update!(name: "AuditableUpdated")
      }.to change { AuditLog.where(action: "update").count }.by(1)
    end

    it "records the old and new values in changed_fields" do
      entity.update!(name: "AuditableRenamed")

      log = AuditLog.for_record("MemoryEntity", entity.id).where(action: "update").recent.first
      expect(log.changed_fields["name"]["from"]).to eq("AuditableUpdate")
      expect(log.changed_fields["name"]["to"]).to eq("AuditableRenamed")
    end

    it "skips audit when only updated_at changes" do
      original_count = AuditLog.where(action: "update").count
      entity.update_columns(updated_at: Time.current)
      entity.reload
      entity.save!

      expect(AuditLog.where(action: "update").count).to eq(original_count)
    end
  end

  describe "audit on destroy" do
    it "creates an audit log entry when an entity is destroyed" do
      entity = MemoryEntity.create!(name: "AuditableDestroy", entity_type: "Project")

      expect {
        entity.destroy!
      }.to change { AuditLog.where(action: "delete").count }.by_at_least(1)
    end

    it "records a snapshot of the destroyed record" do
      entity = MemoryEntity.create!(name: "AuditableDestroySnap", entity_type: "Task")
      entity_id = entity.id
      entity.destroy!

      log = AuditLog.for_record("MemoryEntity", entity_id).where(action: "delete").first
      expect(log.changed_fields["name"]).to eq("AuditableDestroySnap")
      expect(log.changed_fields["entity_type"]).to eq("Task")
    end

    it "excludes the embedding field from snapshots" do
      entity = MemoryEntity.create!(name: "AuditNoEmbed", entity_type: "Project")
      entity.destroy!

      log = AuditLog.for_record("MemoryEntity", entity.id).where(action: "delete").first
      expect(log.changed_fields).not_to have_key("embedding")
    end
  end

  describe "error resilience" do
    it "does not raise when audit write fails" do
      allow(AuditLog).to receive(:create!).and_raise(StandardError, "DB down")

      expect {
        MemoryEntity.create!(name: "AuditFail", entity_type: "Project")
      }.not_to raise_error
    end

    it "logs a warning when audit write fails" do
      allow(AuditLog).to receive(:create!).and_raise(StandardError, "DB down")

      expect(Rails.logger).to receive(:warn).with(/Audit write failed/)
      MemoryEntity.create!(name: "AuditFailLog", entity_type: "Project")
    end
  end
end
