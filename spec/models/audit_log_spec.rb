# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditLog, type: :model do
  let!(:entity) { MemoryEntity.create!(name: "AuditEntity", entity_type: "Project") }

  describe "validations" do
    it "requires action to be present" do
      log = AuditLog.new(auditable_type: "MemoryEntity", auditable_id: 1, action: nil)
      expect(log).not_to be_valid
      expect(log.errors[:action]).to be_present
    end

    it "only allows create, update, delete actions" do
      %w[create update delete].each do |action|
        log = AuditLog.new(auditable_type: "MemoryEntity", auditable_id: 1, action: action)
        log.valid?
        expect(log.errors[:action]).to be_empty
      end

      log = AuditLog.new(auditable_type: "MemoryEntity", auditable_id: 1, action: "invalid")
      expect(log).not_to be_valid
    end
  end

  describe "associations" do
    it "belongs to auditable (polymorphic, optional)" do
      log = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: entity.id,
        action: "create", changed_fields: {}
      )
      expect(log.auditable).to eq(entity)
    end

    it "allows nil auditable (for deleted records)" do
      log = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: 999999,
        action: "delete", changed_fields: {}
      )
      expect(log.auditable).to be_nil
      expect(log).to be_persisted
    end
  end

  describe "scopes" do
    let!(:log1) { AuditLog.create!(auditable_type: "MemoryEntity", auditable_id: entity.id, action: "create", changed_fields: {}) }
    let!(:log2) { AuditLog.create!(auditable_type: "MemoryEntity", auditable_id: entity.id, action: "update", changed_fields: {}) }

    describe ".recent" do
      it "orders by created_at desc" do
        logs = AuditLog.recent
        expect(logs.first.created_at).to be >= logs.last.created_at
      end
    end

    describe ".for_record" do
      it "filters by auditable_type and auditable_id" do
        logs = AuditLog.for_record("MemoryEntity", entity.id)
        expect(logs).to include(log1, log2)
      end

      it "excludes logs for other records" do
        other = AuditLog.create!(auditable_type: "MemoryObservation", auditable_id: 1, action: "create", changed_fields: {})
        logs = AuditLog.for_record("MemoryEntity", entity.id)
        expect(logs).not_to include(other)
      end
    end
  end

  describe ".prune!" do
    it "deletes logs older than MAX_AGE_DAYS" do
      old = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: 1,
        action: "create", changed_fields: {},
        created_at: (AuditLog::MAX_AGE_DAYS + 1).days.ago
      )
      recent = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: 1,
        action: "create", changed_fields: {}
      )

      count = AuditLog.prune!

      expect(count).to be >= 1
      expect(AuditLog.find_by(id: old.id)).to be_nil
      expect(AuditLog.find_by(id: recent.id)).to be_present
    end

    it "returns 0 when nothing to prune" do
      AuditLog.where("created_at < ?", AuditLog::MAX_AGE_DAYS.days.ago).delete_all
      expect(AuditLog.prune!).to eq(0)
    end
  end

  describe "changed_fields serialization" do
    it "stores and retrieves JSON data" do
      data = { "name" => { "from" => "old", "to" => "new" } }
      log = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: 1,
        action: "update", changed_fields: data
      )
      log.reload
      expect(log.changed_fields).to eq(data)
    end

    it "handles nil changed_fields" do
      log = AuditLog.create!(
        auditable_type: "MemoryEntity", auditable_id: 1,
        action: "create", changed_fields: nil
      )
      log.reload
      expect(log.changed_fields).to be_nil
    end
  end

  describe "MAX_AGE_DAYS" do
    it "is 90 days" do
      expect(AuditLog::MAX_AGE_DAYS).to eq(90)
    end
  end
end
