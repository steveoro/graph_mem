# frozen_string_literal: true

require "rails_helper"

RSpec.describe TraverseGraphTool, type: :model do
  let(:tool) { described_class.new }

  let!(:a) { MemoryEntity.create!(name: "Node A", entity_type: "Project") }
  let!(:b) { MemoryEntity.create!(name: "Node B", entity_type: "Task") }
  let!(:c) { MemoryEntity.create!(name: "Node C", entity_type: "Task") }

  let!(:r_ab) { MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of", weight: 1.5) }
  let!(:r_bc) { MemoryRelation.create!(from_entity: b, to_entity: c, relation_type: "depends_on") }

  before do
    MemoryObservation.create!(memory_entity: a, content: "Observation on A")
  end

  describe ".tool_name" do
    it "returns the correct tool name" do
      expect(described_class.tool_name).to eq("traverse_graph")
    end
  end

  describe "#input_schema_to_json" do
    it "exposes the traversal parameters" do
      schema = described_class.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq([ "start_entity_id" ])
      expect(schema[:properties].keys).to include(:start_entity_id, :max_depth, :direction, :relation_types, :max_entities)
    end
  end

  describe "#tool_output_schema" do
    it "describes traversal entities, relations, and metadata" do
      schema = tool.tool_output_schema
      expect(schema[:properties].keys).to contain_exactly(:entities, :relations, :traversal)
    end
  end

  describe "#call" do
    it "returns entities, relations, and traversal metadata" do
      result = tool.call(start_entity_id: a.id, max_depth: 2, direction: "outgoing")

      expect(result[:entities].map { |e| e[:entity_id] }).to eq([ a.id, b.id, c.id ])
      expect(result[:relations].map { |r| r[:relation_id] }).to contain_exactly(r_ab.id, r_bc.id)
      expect(result[:traversal]).to include(
        start_entity_id: a.id, max_depth: 2, direction: "outgoing", visited_depth: 2, truncated: false
      )
    end

    it "serializes observations and relation metadata" do
      result = tool.call(start_entity_id: a.id, max_depth: 1, direction: "outgoing")

      start_entity = result[:entities].find { |e| e[:entity_id] == a.id }
      expect(start_entity[:observations].first[:content]).to eq("Observation on A")

      relation = result[:relations].find { |r| r[:relation_id] == r_ab.id }
      expect(relation[:weight]).to eq(1.5)
      expect(relation).to have_key(:confidence)
      expect(relation).to have_key(:properties)
    end

    it "raises ResourceNotFound for a missing start entity" do
      expect {
        tool.call(start_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound)
    end

    it "raises InternalServerError on unexpected errors" do
      allow_any_instance_of(GraphTraversalService).to receive(:expand).and_raise(StandardError.new("boom"))

      expect {
        tool.call(start_entity_id: a.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
    end
  end
end
