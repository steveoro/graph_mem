# frozen_string_literal: true

# Item 1 of the part_of membership plan, run through each entity-delete path (REST, graph_delete,
# a delete_entity review row, the data-exchange delete_node). The including group defines:
#
#   delete_through_path(entity) # deletes `entity` the way the path does; returns its outcome
#   refused?(outcome)           # true when that outcome is the path's refusal
#   undo_status                 # :not_undoable when the path records a change set (entity deletes
#                               # are hard deletes), :none when it records none
RSpec.shared_examples "an entity delete that moves part_of children up" do
  let(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let(:mid) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let(:leaf) { MemoryEntity.create!(name: "SynthGadget", entity_type: "Component") }
  let(:leaf_child) { MemoryEntity.create!(name: "SynthSprocket", entity_type: "Component") }

  def attach!(child, parent)
    MemoryRelation.create!(from_entity: child, to_entity: parent, relation_type: "part_of")
    ProjectMembership.sync!(child)
  end

  def parent_ids_of(entity) = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").pluck(:to_entity_id)

  context "when the deleted entity has a parent" do
    before do
      attach!(mid, alpha)
      attach!(leaf, mid)
      attach!(leaf_child, leaf)
    end

    it "moves its children under that parent, with their subtrees, in the same project" do
      outcome = delete_through_path(mid)

      expect(refused?(outcome)).to be(false)
      expect(MemoryEntity.exists?(mid.id)).to be(false)
      expect(parent_ids_of(leaf)).to eq([ alpha.id ])
      expect(parent_ids_of(leaf_child)).to eq([ leaf.id ])
      expect([ leaf.reload.project_id, leaf_child.reload.project_id ]).to eq([ alpha.id, alpha.id ])
    end

    it "keeps the path's undoability: an entity delete is a hard delete" do
      sets_before = ChangeSet.count
      delete_through_path(mid)

      if undo_status == :none
        expect(ChangeSet.count).to eq(sets_before)
      else
        set = ChangeSet.order(:id).last
        expect([ set.undo_strategy, set.not_undoable_reason ]).to eq([ "none", "hard_delete" ])
        expect(ChangeSetUndo.call(set.uuid, actor: "operator:synth").status).to eq(:not_undoable)
        expect(MemoryEntity.exists?(mid.id)).to be(false)
        expect(parent_ids_of(leaf)).to eq([ alpha.id ])
        expect(leaf.reload.project_id).to eq(alpha.id)
      end
    end
  end

  # On a consistent graph the children of a parentless entity are global already, so the move to
  # global can only collide on a drifted one: the parentless mid is stamped into Alpha by hand.
  context "when the deleted entity has no parent" do
    before do
      attach!(leaf, mid)
      attach!(leaf_child, leaf)
      [ mid, leaf, leaf_child ].each { |entity| entity.update_column(:project_id, alpha.id) }
    end

    it "makes its children global" do
      outcome = delete_through_path(mid)

      expect(refused?(outcome)).to be(false)
      expect(parent_ids_of(leaf)).to eq([])
      expect([ leaf.reload.project_id, leaf_child.reload.project_id ]).to eq([ nil, nil ])
    end

    # Drift is this example's point: the refused delete leaves the hand-made stamps in place.
    it "refuses with nothing changed when a child's name is already taken at global scope", membership_drift: :allowed do
      MemoryEntity.create!(name: "SynthSprocket", entity_type: "Component")

      outcome = delete_through_path(mid)

      expect(refused?(outcome)).to be(true)
      expect(MemoryEntity.exists?(mid.id)).to be(true)
      expect(parent_ids_of(leaf)).to eq([ mid.id ])
      expect([ leaf.reload.project_id, leaf_child.reload.project_id ]).to eq([ alpha.id, alpha.id ])
    end
  end
end
