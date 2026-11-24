# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationMembershipWrite::EntityDelete do
  def delete_through_path(entity)
    RelationMembershipWrite.destroy_entity!(entity, reason: "synthetic cleanup")
  rescue ProjectMembership::Collision => e
    e
  end

  def refused?(outcome) = outcome.is_a?(ProjectMembership::Collision)

  def undo_status = :none

  it_behaves_like "an entity delete that moves part_of children up"

  describe "the details" do
    let(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
    let(:mid) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
    let(:leaf) { MemoryEntity.create!(name: "SynthGadget", entity_type: "Component") }

    def attach!(child, parent, properties: {})
      MemoryRelation.create!(from_entity: child, to_entity: parent, relation_type: "part_of", properties: properties)
      ProjectMembership.sync!(child) unless properties["reference_stub"]
    end

    before do
      attach!(mid, alpha)
      attach!(leaf, mid)
    end

    it "takes the membership lock before its transaction" do
      expect(open_transactions_at_get_lock { described_class.new(mid).destroy! }).to eq(0)
      expect(membership_lock_free?).to be(true)
    end

    # Whether it has children is read under the lock, so a child attached meanwhile can't skip it.
    it "takes the membership lock before its transaction for an entity without part_of children too" do
      expect(open_transactions_at_get_lock { described_class.new(leaf).destroy! }).to eq(0)
      expect(membership_lock_free?).to be(true)
      expect(MemoryEntity.exists?(leaf.id)).to be(false)
    end

    it "records the reason on the entity's audit row and audits the new parent edge" do
      described_class.new(mid).destroy!(reason: "synthetic cleanup")

      expect(AuditLog.find_by(auditable_type: "MemoryEntity", auditable_id: mid.id, action: "delete").reason).to eq("synthetic cleanup")
      edge = MemoryRelation.find_by!(from_entity_id: leaf.id, relation_type: "part_of")
      expect(AuditLog.exists?(auditable_type: "MemoryRelation", auditable_id: edge.id, action: "create")).to be(true)
    end

    it "says where the children go, before and after" do
      plan = described_class.new(mid).plan
      expect(plan.summary).to eq("1 child entity moves under 'Alpha Project' (##{alpha.id})")
      expect(plan.collision_name).to be_nil

      expect(described_class.new(mid).destroy!.summary(past: true)).to eq("1 child entity moved under 'Alpha Project' (##{alpha.id})")
    end

    it "reports no children for a leaf" do
      expect(described_class.new(leaf).plan.summary).to be_nil
    end

    it "leaves a parked reference stub where it is" do
      stub = MemoryEntity.create!(name: "SynthStub", entity_type: "Component")
      attach!(stub, mid, properties: { "reference_stub" => true })

      plan = described_class.new(mid).destroy!

      expect(plan.child_ids).to eq([ leaf.id ])
      expect(MemoryRelation.where(from_entity_id: stub.id)).to be_empty
      expect(stub.reload.project_id).to be_nil
    end

    it "treats a parent reached only through a stub edge as no parent" do
      parked = MemoryEntity.create!(name: "SynthParked", entity_type: "Component")
      child = MemoryEntity.create!(name: "SynthParkedChild", entity_type: "Component")
      attach!(parked, alpha, properties: { "reference_stub" => true })
      attach!(child, parked)

      plan = described_class.new(parked).destroy!

      expect(plan.parent).to be_nil
      expect(MemoryRelation.where(from_entity_id: child.id)).to be_empty
      expect(child.reload.project_id).to be_nil
    end

    it "moves a nested Project child up with no change to its scope" do
      nested = MemoryEntity.create!(name: "Beta Project", entity_type: "Project")
      attach!(nested, mid)

      described_class.new(mid).destroy!

      expect(MemoryRelation.where(from_entity_id: nested.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ alpha.id ])
      expect(nested.reload.project_id).to be_nil
    end
  end
end
