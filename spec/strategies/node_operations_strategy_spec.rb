# frozen_string_literal: true

require "rails_helper"

RSpec.describe NodeOperationsStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup test data
  let!(:project) do
    MemoryEntity.create!(
      name: "TestProject",
      entity_type: "Project",
      aliases: "test,proj"
    )
  end

  let!(:orphan_node) do
    MemoryEntity.create!(
      name: "OrphanTask",
      entity_type: "Task",
      aliases: "orphan"
    )
  end

  let!(:node_with_children) do
    entity = MemoryEntity.create!(
      name: "ParentNode",
      entity_type: "Task",
      aliases: ""
    )

    # Add some observations
    MemoryObservation.create!(memory_entity: entity, content: "Parent observation")

    entity
  end

  let!(:child_node) do
    entity = MemoryEntity.create!(
      name: "ChildNode",
      entity_type: "Task",
      aliases: ""
    )

    MemoryRelation.create!(
      from_entity: entity,
      to_entity: node_with_children,
      relation_type: "part_of"
    )

    entity
  end

  describe "#move_to_parent" do
    it "creates a part_of relation to the new parent" do
      result = strategy.move_to_parent(orphan_node.id, project.id)

      expect(result[:success]).to be true

      relation = MemoryRelation.find_by(
        from_entity_id: orphan_node.id,
        to_entity_id: project.id,
        relation_type: "part_of"
      )
      expect(relation).to be_present
    end

    it "removes existing parent relations" do
      # First make orphan_node a child of node_with_children
      MemoryRelation.create!(
        from_entity: orphan_node,
        to_entity: node_with_children,
        relation_type: "part_of"
      )

      # Now move it to project
      result = strategy.move_to_parent(orphan_node.id, project.id)

      expect(result[:success]).to be true

      # Old relation should be gone
      old_relation = MemoryRelation.find_by(
        from_entity_id: orphan_node.id,
        to_entity_id: node_with_children.id
      )
      expect(old_relation).to be_nil

      # New relation should exist
      new_relation = MemoryRelation.find_by(
        from_entity_id: orphan_node.id,
        to_entity_id: project.id
      )
      expect(new_relation).to be_present
    end

    it "returns error for non-existent node" do
      result = strategy.move_to_parent(99999, project.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Node not found")
    end

    it "returns error for non-existent parent" do
      result = strategy.move_to_parent(orphan_node.id, 99999)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Parent node not found")
    end

    it "returns error when moving node to itself" do
      result = strategy.move_to_parent(orphan_node.id, orphan_node.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Cannot move a node to itself")
    end

    it "returns error when relation already exists" do
      # Create the relation first
      MemoryRelation.create!(
        from_entity: orphan_node,
        to_entity: project,
        relation_type: "part_of"
      )

      result = strategy.move_to_parent(orphan_node.id, project.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("already a child")
    end

    it "preserves depends_on relations when moving hierarchy parent" do
      MemoryRelation.create!(
        from_entity: orphan_node,
        to_entity: node_with_children,
        relation_type: "depends_on"
      )

      result = strategy.move_to_parent(orphan_node.id, project.id)

      expect(result[:success]).to be true
      expect(MemoryRelation.exists?(from_entity_id: orphan_node.id, to_entity_id: node_with_children.id, relation_type: "depends_on")).to be true
    end

    it "rejects moves that would create a part_of cycle" do
      MemoryRelation.create!(from_entity: project, to_entity: orphan_node, relation_type: "part_of")

      result = strategy.move_to_parent(orphan_node.id, project.id)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/cycle/)
    end
  end

  describe "#merge_into" do
    let!(:source_with_data) do
      entity = MemoryEntity.create!(
        name: "SourceNode",
        entity_type: "Task",
        aliases: "source,src"
      )

      MemoryObservation.create!(memory_entity: entity, content: "Source observation 1")
      MemoryObservation.create!(memory_entity: entity, content: "Source observation 2")

      entity
    end

    let!(:target_node) do
      entity = MemoryEntity.create!(
        name: "TargetNode",
        entity_type: "Task",
        aliases: "target"
      )

      MemoryObservation.create!(memory_entity: entity, content: "Target observation")

      entity
    end

    it "adds source name to target aliases" do
      strategy.merge_into(source_with_data.id, target_node.id)

      target_node.reload
      expect(target_node.aliases).to include("SourceNode")
    end

    it "transfers observations from source to target" do
      strategy.merge_into(source_with_data.id, target_node.id)

      target_node.reload
      expect(target_node.memory_observations.count).to eq(3)
    end

    it "does not re-embed moved observations when vectors are enabled" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:embed_entity)
      expect(EmbeddingService).not_to receive(:embed_observation)
      observations = source_with_data.memory_observations
      stamp = 1.day.ago.change(usec: 0)
      observations.update_all(embedded_at: stamp)
      observation_ids = observations.pluck(:id)

      result = strategy.merge_into(source_with_data.id, target_node.id)

      expect(result[:success]).to be true
      moved = MemoryObservation.where(id: observation_ids)
      expect(moved.pluck(:memory_entity_id).uniq).to eq([ target_node.id ])
      expect(moved.pluck(:embedded_at)).to all(be_within(1.second).of(stamp))
    end

    it "merges when vectors are disabled" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
      observation_ids = source_with_data.memory_observations.pluck(:id)

      result = strategy.merge_into(source_with_data.id, target_node.id)

      expect(result[:success]).to be true
      expect(MemoryObservation.where(id: observation_ids).pluck(:memory_entity_id).uniq).to eq([ target_node.id ])
    end

    it "deletes the source node" do
      source_id = source_with_data.id

      strategy.merge_into(source_id, target_node.id)

      expect(MemoryEntity.find_by(id: source_id)).to be_nil
    end

    it "re-parents children of source to target" do
      # Add a child to source
      child = MemoryEntity.create!(name: "SourceChild", entity_type: "Task")
      MemoryRelation.create!(
        from_entity: child,
        to_entity: source_with_data,
        relation_type: "part_of"
      )

      strategy.merge_into(source_with_data.id, target_node.id)

      # Child should now point to target
      relation = MemoryRelation.find_by(from_entity_id: child.id)
      expect(relation.to_entity_id).to eq(target_node.id)
    end

    it "returns success result" do
      result = strategy.merge_into(source_with_data.id, target_node.id)

      expect(result[:success]).to be true
      expect(result[:message]).to include("Successfully merged")
    end

    it "returns error for non-existent source" do
      result = strategy.merge_into(99999, target_node.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Source node not found")
    end

    it "returns error when merging node into itself" do
      result = strategy.merge_into(target_node.id, target_node.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Cannot merge a node into itself")
    end

    it "rejects merging away a Project root entity" do
      project_source = MemoryEntity.create!(name: "ProtectedProject", entity_type: "Project")

      result = strategy.merge_into(project_source.id, target_node.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Project root entities cannot be deleted or merged away")
      expect(MemoryEntity.find_by(id: project_source.id)).to be_present
    end

    it "succeeds when source and target share colliding child relations" do
      child = MemoryEntity.create!(name: "SharedChild", entity_type: "Task")
      source = MemoryEntity.create!(name: "CollisionSource", entity_type: "Task")
      target = MemoryEntity.create!(name: "CollisionTarget", entity_type: "Task")

      MemoryRelation.create!(from_entity: child, to_entity: source, relation_type: "part_of")
      colliding = MemoryRelation.new(from_entity: child, to_entity: target, relation_type: "part_of")
      colliding.save!(validate: false)

      result = strategy.merge_into(source.id, target.id)

      expect(result[:success]).to be true
      expect(MemoryEntity.exists?(source.id)).to be false
      expect(MemoryRelation.where(from_entity_id: child.id, to_entity_id: target.id, relation_type: "part_of").count).to eq(1)
    end
  end

  describe "#merge_into concurrency handling" do
    it "retries a transient stale-record failure and succeeds" do
      attempts = 0
      allow(strategy).to receive(:merge_into_once) do
        attempts += 1
        raise ActiveRecord::StatementInvalid, "Record has changed since last read in table 'memory_entities'" if attempts == 1

        { success: true, message: "merged" }
      end

      expect(strategy.merge_into(orphan_node.id, project.id)).to eq(success: true, message: "merged")
      expect(attempts).to eq(2)
    end

    it "does not retry unrelated statement errors" do
      attempts = 0
      allow(strategy).to receive(:merge_into_once) do
        attempts += 1
        raise ActiveRecord::StatementInvalid, "syntax error"
      end

      expect { strategy.merge_into(orphan_node.id, project.id) }.to raise_error(ActiveRecord::StatementInvalid, "syntax error")
      expect(attempts).to eq(1)
    end

    it "returns a not-found result when the source disappears before locking" do
      source_id = orphan_node.id
      orphan_node.destroy!

      expect(strategy.merge_into(source_id, project.id)).to eq(
        success: false,
        error: "Source node not found"
      )
    end
  end

  describe "#delete_node" do
    it "deletes the node" do
      node_id = orphan_node.id

      result = strategy.delete_node(node_id)

      expect(result[:success]).to be true
      expect(MemoryEntity.find_by(id: node_id)).to be_nil
    end

    it "deletes associated observations" do
      observation = MemoryObservation.create!(
        memory_entity: orphan_node,
        content: "Test observation"
      )
      observation_id = observation.id

      strategy.delete_node(orphan_node.id)

      expect(MemoryObservation.find_by(id: observation_id)).to be_nil
    end

    it "makes children orphans by default" do
      child_id = child_node.id

      strategy.delete_node(node_with_children.id)

      # Child should still exist
      expect(MemoryEntity.find_by(id: child_id)).to be_present

      # But should have no parent relation
      relation = MemoryRelation.find_by(from_entity_id: child_id, relation_type: "part_of")
      expect(relation).to be_nil
    end

    it "cascade deletes descendants when requested" do
      child_id = child_node.id

      result = strategy.delete_node(node_with_children.id, cascade_delete: true)

      expect(result[:success]).to be true

      # Child should be deleted too
      expect(MemoryEntity.find_by(id: child_id)).to be_nil
    end

    it "returns error for non-existent node" do
      result = strategy.delete_node(99999)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Node not found")
    end

    it "rejects deleting a Project root entity" do
      result = strategy.delete_node(project.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Project root entities cannot be deleted or merged away")
      expect(MemoryEntity.find_by(id: project.id)).to be_present
    end

    it "rejects cascade deletion when a descendant is a Project" do
      project_child = MemoryEntity.create!(name: "ChildProject", entity_type: "Project")
      MemoryRelation.create!(
        from_entity: project_child,
        to_entity: node_with_children,
        relation_type: "part_of"
      )

      result = strategy.delete_node(node_with_children.id, cascade_delete: true)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Project root entities cannot be deleted or merged away")
      expect(MemoryEntity.find_by(id: node_with_children.id)).to be_present
      expect(MemoryEntity.find_by(id: project_child.id)).to be_present
    end
  end

  describe "project-scoped membership" do
    let(:strategy) { described_class.new }
    let(:project_a) { MemoryEntity.create!(name: "OpProjA", entity_type: "Project") }
    let(:project_b) { MemoryEntity.create!(name: "OpProjB", entity_type: "Project") }

    it "move_to_parent re-scopes the node and its member subtree" do
      node = MemoryEntity.create!(name: "Movable", entity_type: "File", project_id: project_a.id)
      child = MemoryEntity.create!(name: "MovableChild", entity_type: "Class", project_id: project_a.id)
      MemoryRelation.create!(from_entity: node, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: child, to_entity: node, relation_type: "part_of")

      result = strategy.move_to_parent(node.id, project_b.id)

      expect(result[:success]).to be true
      expect(node.reload.project_id).to eq(project_b.id)
      expect(child.reload.project_id).to eq(project_b.id)
    end

    it "merge_into re-scopes children re-pointed under the foreign target" do
      source = MemoryEntity.create!(name: "MergeSrc", entity_type: "Class", project_id: project_a.id)
      source_child = MemoryEntity.create!(name: "MergeSrcChild", entity_type: "Method",
                                          project_id: project_a.id)
      target = MemoryEntity.create!(name: "MergeDst", entity_type: "Class", project_id: project_b.id)
      MemoryRelation.create!(from_entity: source, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: source_child, to_entity: source, relation_type: "part_of")
      MemoryRelation.create!(from_entity: target, to_entity: project_b, relation_type: "part_of")

      result = strategy.merge_into(source.id, target.id)

      expect(result[:success]).to be true
      expect(source_child.reload.project_id).to eq(project_b.id)
    end

    it "delete_node un-roots orphaned children" do
      node = MemoryEntity.create!(name: "DelScoped", entity_type: "File", project_id: project_a.id)
      child = MemoryEntity.create!(name: "DelScopedChild", entity_type: "Class",
                                   project_id: project_a.id)
      MemoryRelation.create!(from_entity: node, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: child, to_entity: node, relation_type: "part_of")

      result = strategy.delete_node(node.id)

      expect(result[:success]).to be true
      expect(child.reload.project_id).to be_nil
    end
  end

  # UI-4b W6: Explore's digest check runs inside the merge's lock through before_merge:.
  describe "#merge_into with before_merge:" do
    let!(:source) { MemoryEntity.create!(name: "SynthWidget A #{SecureRandom.hex(3)}", entity_type: "Component") }
    let!(:target) { MemoryEntity.create!(name: "SynthWidget B #{SecureRandom.hex(3)}", entity_type: "Component") }

    before { MemoryObservation.create!(memory_entity: source, content: "SynthWidget A renders tiles.") }

    it "writes nothing and answers :conflict when the hook returns a message" do
      seen = nil
      hook = lambda do |locked_source, locked_target|
        seen = [ locked_source.id, locked_target.id ]
        "synthetic refusal"
      end

      expect do
        result = strategy.merge_into(source.id, target.id, before_merge: hook)
        expect(result).to eq(success: false, status: :conflict, error: "synthetic refusal")
      end.not_to change { [ MemoryEntity.count, ChangeSet.count, AuditLog.count, MemoryObservation.where(memory_entity_id: source.id).count ] }
      expect(seen).to eq([ source.id, target.id ])
    end

    it "merges as before when the hook returns nil" do
      result = strategy.merge_into(source.id, target.id, before_merge: ->(*) { nil })

      expect(result[:success]).to be(true)
      expect(MemoryEntity.exists?(source.id)).to be(false)
    end

    it "isn't called when the existing checks already refuse" do
      other = MemoryEntity.create!(name: "Synth Router #{SecureRandom.hex(3)}", entity_type: "Service")
      hook = ->(*) { raise "should not run" }

      expect(strategy.merge_into(source.id, other.id, before_merge: hook)[:success]).to be(false)
    end
  end
end
