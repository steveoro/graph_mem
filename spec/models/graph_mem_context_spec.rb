# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMemContext do
  after { described_class.clear! }

  describe ".current_project_id" do
    it "returns nil by default" do
      expect(described_class.current_project_id).to be_nil
    end

    it "stores and retrieves a project ID" do
      described_class.current_project_id = 42
      expect(described_class.current_project_id).to eq(42)
    end
  end

  describe ".active?" do
    it "returns false when no context is set" do
      expect(described_class.active?).to be false
    end

    it "returns true when a project ID is set" do
      described_class.current_project_id = 1
      expect(described_class.active?).to be true
    end
  end

  describe ".clear!" do
    it "resets the project ID to nil" do
      described_class.current_project_id = 99
      described_class.clear!
      expect(described_class.current_project_id).to be_nil
    end

    it "makes active? return false" do
      described_class.current_project_id = 99
      described_class.clear!
      expect(described_class.active?).to be false
    end
  end

  describe ".scoped_entity_ids" do
    it "returns nil when no context is active" do
      expect(described_class.scoped_entity_ids).to be_nil
    end

    it "returns the project ID alone when no part_of relations exist" do
      project = MemoryEntity.create!(name: "ScopedProject", entity_type: "Project")
      described_class.current_project_id = project.id

      ids = described_class.scoped_entity_ids
      expect(ids).to eq([project.id])
    end

    it "includes entities related via part_of to the project" do
      project = MemoryEntity.create!(name: "ParentProject", entity_type: "Project")
      child = MemoryEntity.create!(name: "ChildTask", entity_type: "Task")
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")
      described_class.current_project_id = project.id

      ids = described_class.scoped_entity_ids
      expect(ids).to contain_exactly(project.id, child.id)
    end

    it "does not include entities with non-part_of relations" do
      project = MemoryEntity.create!(name: "OnlyPartOf", entity_type: "Project")
      other = MemoryEntity.create!(name: "Related", entity_type: "Task")
      MemoryRelation.create!(from_entity: other, to_entity: project, relation_type: "depends_on")
      described_class.current_project_id = project.id

      ids = described_class.scoped_entity_ids
      expect(ids).to eq([project.id])
    end

    it "deduplicates IDs" do
      project = MemoryEntity.create!(name: "DedupeProject", entity_type: "Project")
      described_class.current_project_id = project.id

      ids = described_class.scoped_entity_ids
      expect(ids).to eq(ids.uniq)
    end
  end

  describe "cross-thread visibility" do
    it "context set on one thread is visible from another thread" do
      described_class.current_project_id = 777

      value_from_other_thread = Thread.new { described_class.current_project_id }.value
      expect(value_from_other_thread).to eq(777)
    end

    it "clear! on one thread clears context for all threads" do
      described_class.current_project_id = 888
      Thread.new { described_class.clear! }.join

      expect(described_class.current_project_id).to be_nil
    end
  end
end
