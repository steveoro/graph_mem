# frozen_string_literal: true

require "rails_helper"

# UI-4b W6: the preview must describe exactly what merge_into does, and write nothing.
RSpec.describe EntityMergePreview do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:source) { MemoryEntity.create!(name: "SynthWidget A", entity_type: "Component", aliases: "widget a", project_id: alpha.id) }
  let!(:target) { MemoryEntity.create!(name: "SynthWidget B", entity_type: "Component", project_id: gadget.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: alpha.id) }
  let!(:cache) { MemoryEntity.create!(name: "Synth Cache", entity_type: "Service", project_id: alpha.id) }
  let!(:child) { MemoryEntity.create!(name: "Synth Part", entity_type: "Component", project_id: alpha.id) }
  let!(:grandchild) { MemoryEntity.create!(name: "Synth Bolt", entity_type: "Component", project_id: alpha.id) }

  let!(:repointed_out) { MemoryRelation.create!(from_entity: source, to_entity: router, relation_type: "depends_on") }
  let!(:duplicate_out) { MemoryRelation.create!(from_entity: source, to_entity: cache, relation_type: "depends_on") }
  let!(:target_out) { MemoryRelation.create!(from_entity: target, to_entity: cache, relation_type: "depends_on") }
  let!(:between) { MemoryRelation.create!(from_entity: source, to_entity: target, relation_type: "relates_to") }
  let!(:child_edge) { MemoryRelation.create!(from_entity: child, to_entity: source, relation_type: "part_of") }
  let!(:grandchild_edge) { MemoryRelation.create!(from_entity: grandchild, to_entity: child, relation_type: "part_of") }
  let!(:observations) do
    [ MemoryObservation.create!(memory_entity: source, content: "SynthWidget A renders tiles."),
      MemoryObservation.create!(memory_entity: source, content: "SynthWidget A was slow.", status: "obsolete", obsoleted_at: Time.current) ]
  end

  def counts = [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count, AuditLog.count, ChangeSet.count ]

  it "lists what the merge then does, and writes nothing" do
    before_counts = counts
    preview = described_class.new(source.id, target.id).call
    expect(counts).to eq(before_counts)

    expect(preview.blockers).to eq([])
    expect(preview.observation_count).to eq(2) # any status, like transfer_observations!
    expect(preview.repointed.map(&:id)).to contain_exactly(repointed_out.id, child_edge.id)
    expect(preview.dropped.map(&:id)).to contain_exactly(duplicate_out.id, between.id)
    expect(preview.aliases_gained).to eq([ "widget a", "SynthWidget A" ])
    expect(preview.children).to eq([ child ])
    expect(preview.project_moves.sole).to have_attributes(from_name: "Alpha Service", to_name: "Gadget Project", count: 2)

    NodeOperationsStrategy.new.merge_into(source.id, target.id)

    expect(MemoryObservation.where(id: observations.map(&:id)).pluck(:memory_entity_id).uniq).to eq([ target.id ])
    expect(repointed_out.reload.from_entity_id).to eq(target.id)
    expect(child_edge.reload.to_entity_id).to eq(target.id)
    expect(MemoryRelation.where(id: [ duplicate_out.id, between.id ])).to be_empty
    expect(target.reload.aliases.split(",")).to eq([ "widget a", "SynthWidget A" ])
    expect([ child.reload.project_id, grandchild.reload.project_id ]).to eq([ gadget.id, gadget.id ])
  end

  it "changes its digest when the graph does, and only then" do
    digest = described_class.new(source.id, target.id).call.digest
    expect(described_class.new(source.id, target.id).call.digest).to eq(digest)

    MemoryObservation.create!(memory_entity: source, content: "SynthWidget A added later.")

    expect(described_class.new(source.id, target.id).call.digest).not_to eq(digest)
  end

  it "reports blockers" do
    expect(described_class.new(source.id, router.id).call.blockers.sole).to include("different types")
    expect(described_class.new(source.id, source.id).call.blockers).to eq([ "Cannot merge a node into itself" ])
    expect(described_class.new(alpha.id, gadget.id).call.blockers).to include(NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR)
    missing = described_class.new(0, target.id).call
    expect([ missing.blockers, missing.digest ]).to eq([ [ "Source node not found" ], nil ])
  end
end
