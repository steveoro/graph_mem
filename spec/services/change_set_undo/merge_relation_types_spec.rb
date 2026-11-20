# frozen_string_literal: true

require "rails_helper"

# R1a: the undo of an entity merge brings relations back with their stored type, and a restored or
# re-pointed row counts as a part_of edge only when SQL reads it as part_of (case-only spellings).
RSpec.describe ChangeSetUndo::Merge do
  let(:operator) { "operator:synth@127.0.0.1" }
  let(:source) { MemoryEntity.create!(name: "SynthWidget Old", entity_type: "Component") }
  let(:target) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let(:other) { MemoryEntity.create!(name: "SynthService", entity_type: "Service") }

  def stored(from, to, type)
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(3)}")
    relation.update_column(:relation_type, type)
    relation
  end

  def merge! = NodeOperationsStrategy.new.merge_into(source.id, target.id).fetch(:change_set_uuid)

  it "restores a dropped variant with its stored type, next to its canonical twin" do
    variant = stored(source, other, "requires")
    MemoryRelation.create!(from_entity: source, to_entity: other, relation_type: "depends_on")
    stored(target, other, "requires")

    uuid = merge!
    expect(MemoryRelation.exists?(variant.id)).to be(false)

    result = ChangeSetUndo.call(uuid, actor: operator)

    expect(result).to be_ok
    expect(MemoryRelation.find(variant.id).relation_type).to eq("requires")
    expect(MemoryRelation.where(from_entity_id: source.id, to_entity_id: other.id).pluck(:relation_type))
      .to contain_exactly("requires", "depends_on")
  end

  it "syncs membership for a case-only Part_Of edge, both ways" do
    alpha = MemoryEntity.create!(name: "Alpha Project", entity_type: "Project")
    beta = MemoryEntity.create!(name: "Beta Project", entity_type: "Project")
    MemoryRelation.create!(from_entity: source, to_entity: alpha, relation_type: "part_of")
    MemoryRelation.create!(from_entity: target, to_entity: beta, relation_type: "part_of")
    child = MemoryEntity.create!(name: "SynthGear", entity_type: "Component")
    edge = stored(child, source, "Part_Of")
    [ source, target, child ].each { |entity| ProjectMembership.sync!(entity) }
    expect(child.reload.project_id).to eq(alpha.id)

    uuid = merge!
    expect(edge.reload).to have_attributes(relation_type: "Part_Of", to_entity_id: target.id)
    expect(child.reload.project_id).to eq(beta.id)

    expect(ChangeSetUndo.call(uuid, actor: operator)).to be_ok
    expect(edge.reload.to_entity_id).to eq(source.id)
    expect(child.reload.project_id).to eq(alpha.id)
  end

  it "leaves membership alone for a spaced Part Of variant, which SQL doesn't read as part_of" do
    alpha = MemoryEntity.create!(name: "Alpha Project", entity_type: "Project")
    MemoryRelation.create!(from_entity: target, to_entity: alpha, relation_type: "part_of")
    ProjectMembership.sync!(target)
    child = MemoryEntity.create!(name: "SynthGear", entity_type: "Component")
    edge = stored(child, source, "Part Of")

    uuid = merge!
    expect(edge.reload).to have_attributes(relation_type: "Part Of", to_entity_id: target.id)
    expect(child.reload.project_id).to be_nil

    expect(ChangeSetUndo.call(uuid, actor: operator)).to be_ok
    expect(edge.reload).to have_attributes(relation_type: "Part Of", to_entity_id: source.id)
  end
end
