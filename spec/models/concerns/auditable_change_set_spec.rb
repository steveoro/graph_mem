# frozen_string_literal: true

require "rails_helper"

# UI-4a: audit rows carry the open change set.
RSpec.describe Auditable, "change sets", type: :model do
  it "stamps every audit row written inside ChangeSet.record with one set" do
    context = ChangeSet.record(kind: "graph.write", actor: "mcp:graph_write") do |change_set|
      entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
      MemoryObservation.create!(memory_entity: entity, content: "synthetic widget fact")
      change_set
    end

    set = ChangeSet.find_by!(uuid: context.uuid)
    expect(AuditLog.where(change_set_id: set.id).pluck(:auditable_type)).to contain_exactly("MemoryEntity", "MemoryObservation")
    expect(set.audit_logs.count).to eq(2)
    expect(set).to have_attributes(kind: "graph.write", actor: "mcp:graph_write", subject_type: "MemoryEntity")
  end

  it "leaves change_set_id NULL outside a change set" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")

    expect(AuditLog.for_record("MemoryEntity", entity.id).pick(:change_set_id)).to be_nil
    expect(ChangeSet.count).to eq(0)
  end

  it "never blocks the write when the audit row fails, and marks the set audit_incomplete" do
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "synthetic audit failure")

    context = ChangeSet.record(kind: "graph.write") do |change_set|
      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
      change_set
    end

    expect(MemoryEntity.where(name: "SynthWidget")).to exist
    expect(ChangeSet.find_by!(uuid: context.uuid)).to have_attributes(undo_strategy: "none", not_undoable_reason: "audit_incomplete")
  end

  it "still never blocks the write when the change set itself can't be written" do
    allow(ChangeSet).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "synthetic change set failure")

    entity = ChangeSet.record(kind: "graph.write") { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

    expect(MemoryEntity.where(name: "SynthWidget")).to exist
    expect(AuditLog.for_record("MemoryEntity", entity.id).pluck(:action, :change_set_id)).to eq([ [ "create", nil ] ])
  end
end
