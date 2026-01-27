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
  end
end
