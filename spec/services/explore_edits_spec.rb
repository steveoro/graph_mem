# frozen_string_literal: true

require "rails_helper"

# UI-4b: each Explore edit opens one change set of its kind, and undoing it restores the before
# state through ChangeSetUndo. Synthetic data.
RSpec.describe ExploreEdits do
  subject(:edits) { described_class.new }

  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:part) { MemoryEntity.create!(name: "Synth Part", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
  let!(:fact) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.") }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    MemoryRelation.create!(from_entity: part, to_entity: widget, relation_type: "part_of")
    Current.actor = "operator:synth@127.0.0.1"
  end

  after { Current.reset }

  def undo(result)
    ChangeSetUndo.call(result.fetch(:change_set_uuid), actor: "operator:synth@127.0.0.1")
  end

  def expect_one_set(result, kind)
    expect(result).to include(success: true, undoable: true)
    expect(ChangeSet.where(uuid: result[:change_set_uuid]).sole).to have_attributes(kind: kind, actor: "operator:synth@127.0.0.1")
  end

  it "entity edit → undo restores the name" do
    result = edits.update_entity(widget, name: "SynthWidget 2")
    expect_one_set(result, "explore.entity_edit")

    expect(undo(result)).to be_ok
    expect(widget.reload.name).to eq("SynthWidget")
  end

  it "observation add → undo removes it" do
    result = edits.add_observation(widget, content: "SynthWidget caches tiles.")
    expect_one_set(result, "explore.observation_add")

    expect(undo(result)).to be_ok
    expect(widget.memory_observations.active.pluck(:content)).to eq([ fact.content ])
  end

  it "observation edit → undo makes the old one active again" do
    result = edits.update_observation(fact, content: "SynthWidget renders tiles fast.")
    expect_one_set(result, "explore.observation_edit")
    expect(fact.reload.status).to eq("superseded")

    expect(undo(result)).to be_ok
    expect(fact.reload.status).to eq("active")
    expect(widget.memory_observations.active.pluck(:content)).to eq([ fact.content ])
  end

  it "observation retire → undo makes it active again" do
    result = edits.retire_observation(fact)
    expect_one_set(result, "explore.observation_retire")

    expect(undo(result)).to be_ok
    expect(fact.reload.status).to eq("active")
  end

  it "relation add → undo removes it" do
    result = edits.add_relation(widget, router, "depends_on")
    expect_one_set(result, "explore.relation_add")

    expect(undo(result)).to be_ok
    expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: router.id)).to be_empty
  end

  it "relation remove → undo re-creates the same id" do
    relation = MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on")
    result = edits.remove_relation(relation)
    expect_one_set(result, "explore.relation_remove")

    expect(undo(result)).to be_ok
    expect(MemoryRelation.find(relation.id).relation_type).to eq("depends_on")
  end

  it "move → undo restores the old parent and project, subtree included" do
    result = edits.move(widget, gadget)
    expect_one_set(result, "explore.move")
    expect([ widget.reload.project_id, part.reload.project_id ]).to eq([ gadget.id, gadget.id ])

    expect(undo(result)).to be_ok
    expect(MemoryRelation.where(from_entity_id: widget.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ alpha.id ])
    expect([ widget.reload.project_id, part.reload.project_id ]).to eq([ alpha.id, alpha.id ])
  end

  it "keeps project roots to rename only, and unmovable, writing nothing" do
    expect(edits.update_entity(alpha, entity_type: "Component")).to include(success: false, error: described_class::ROOT_RENAME_ONLY)
    expect(edits.update_entity(alpha, aliases: "alpha")).to include(success: false, error: described_class::ROOT_RENAME_ONLY)
    expect(edits.move(alpha, gadget)).to include(success: false, error: described_class::ROOT_MOVE)
    expect(ChangeSet.count).to eq(0)
  end
end
