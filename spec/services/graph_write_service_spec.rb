# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphWriteService do
  let(:vector_strategy) { instance_double(VectorSearchStrategy, search: []) }

  before { allow(VectorSearchStrategy).to receive(:new).and_return(vector_strategy) }

  describe ".call" do
    it "executes dependency-ordered mixed operations atomically" do
      result = described_class.call(
        operations: [
          { type: "create_relation", from_entity_id: "New parent", to_entity_id: "New child", relation_type: "part_of" },
          { type: "create_entity", name: "New child", entity_type: "Task" },
          { type: "create_entity", name: "New parent", entity_type: "Project" },
          { type: "create_observation", entity_name: "New child", text_content: "Created in batch" }
        ]
      )

      expect(result).to include(mode: "batch", status: "ok")
      expect(result[:results].pluck(:index)).to eq([ 0, 1, 2, 3 ])
      expect(result[:summary]).to include(
        operations: 4,
        entities_created: 2,
        observations_created: 1,
        relations_created: 1
      )
      child = MemoryEntity.find_by!(name: "New child")
      expect(child.memory_observations.pluck(:content)).to include("Created in batch")
    end

    it "rolls back the whole batch when a later operation fails" do
      expect {
        described_class.call(
          operations: [
            { type: "create_entity", name: "Rolled back", entity_type: "Task" },
            { type: "create_observation", entity_id: 999_999, text_content: "Invalid" }
          ]
        )
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /create_observation\[1\]/)

      expect(MemoryEntity.find_by(name: "Rolled back")).to be_nil
    end

    it "returns a possible-duplicate response without writing any operation" do
      existing = MemoryEntity.create!(name: "Existing candidate", entity_type: "Task")
      candidate = Struct.new(:entity, :distance).new(existing, 0.1)
      allow(vector_strategy).to receive(:search).and_return([ candidate ])

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Near candidate", entity_type: "Task" },
          { type: "create_entity", name: "Must not persist", entity_type: "Task" }
        ]
      )

      expect(result).to include(
        status: "possible_duplicate",
        kind: "entity",
        operation_index: 0
      )
      expect(result.dig(:candidates, 0, :entity_id)).to eq(existing.id)
      expect(MemoryEntity.find_by(name: "Must not persist")).to be_nil
    end

    it "preflights canonicalized duplicate relations before writing" do
      from = MemoryEntity.create!(name: "Relation source", entity_type: "Task")
      to = MemoryEntity.create!(name: "Relation target", entity_type: "Task")
      existing = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "depends_on")
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Must also not persist", entity_type: "Task" },
          {
            type: "create_relation",
            from_entity_id: from.id,
            to_entity_id: to.id,
            relation_type: "REQUIRES"
          }
        ]
      )

      expect(result).to include(
        status: "possible_duplicate",
        kind: "relation",
        operation_index: 1
      )
      expect(result.dig(:candidates, 0, :relation_id)).to eq(existing.id)
      expect(MemoryEntity.find_by(name: "Must also not persist")).to be_nil
    end

    it "canonicalizes entity types before duplicate probing" do
      existing = MemoryEntity.create!(name: "Mapped project", entity_type: "Project")
      EntityTypeMapping.create!(canonical_type: "Project", variant: "workspace")
      candidate = Struct.new(:entity, :distance).new(existing, 0.1)

      expect(vector_strategy).to receive(:search)
        .with("Project: Mapped workspace", limit: 1, entity_type: "Project")
        .and_return([ candidate ])

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Mapped workspace", entity_type: "workspace" }
        ]
      )

      expect(result[:status]).to eq("possible_duplicate")
    end

    it "returns non-blocking close-match type hints" do
      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Misspelled type", entity_type: "Projct" }
        ]
      )

      expect(result.dig(:results, 0, :result, :type_hint)).to eq(
        submitted: "Projct",
        suggested: "Project"
      )
      expect(MemoryEntity.find_by!(name: "Misspelled type").entity_type).to eq("Projct")
    end

    it "validates operation type and batch size" do
      expect {
        described_class.call(operations: [ { type: "unknown" } ])
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /unknown type/)

      operations = 51.times.map { |index| { type: "create_entity", name: "E#{index}", entity_type: "Task" } }
      expect {
        described_class.call(operations: operations)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /at most 50/)
    end
  end
end
