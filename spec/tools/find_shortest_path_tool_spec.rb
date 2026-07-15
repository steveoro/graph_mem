# frozen_string_literal: true

require "rails_helper"

RSpec.describe FindShortestPathTool, type: :model do
  let(:tool) { described_class.new }

  let!(:a) { MemoryEntity.create!(name: "Path A", entity_type: "Project") }
  let!(:b) { MemoryEntity.create!(name: "Path B", entity_type: "Task") }
  let!(:c) { MemoryEntity.create!(name: "Path C", entity_type: "Task") }
  let!(:isolated) { MemoryEntity.create!(name: "Path Isolated", entity_type: "Task") }

  let!(:r_ab) { MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of") }
  let!(:r_bc) { MemoryRelation.create!(from_entity: b, to_entity: c, relation_type: "depends_on") }

  describe ".tool_name" do
    it "returns the correct tool name" do
      expect(described_class.tool_name).to eq("find_shortest_path")
    end
  end

  describe "#input_schema_to_json" do
    it "requires both endpoints" do
      schema = described_class.input_schema_to_json
      expect(schema[:required]).to contain_exactly("from_entity_id", "to_entity_id")
    end
  end

  describe "#tool_output_schema" do
    it "describes the ordered path response" do
      schema = tool.tool_output_schema
      expect(schema[:properties].keys).to contain_exactly(
        :found, :hop_count, :direction, :entities, :relations
      )
    end
  end

  describe "#call" do
    it "returns the ordered path between two entities" do
      result = tool.call(from_entity_id: a.id, to_entity_id: c.id, max_depth: 3, direction: "outgoing")

      expect(result[:found]).to be(true)
      expect(result[:hop_count]).to eq(2)
      expect(result[:entities].map { |e| e[:entity_id] }).to eq([ a.id, b.id, c.id ])
      expect(result[:relations].map { |r| r[:relation_id] }).to eq([ r_ab.id, r_bc.id ])
    end

    it "returns found: false with empty collections when no path exists" do
      result = tool.call(from_entity_id: a.id, to_entity_id: isolated.id, max_depth: 5)

      expect(result[:found]).to be(false)
      expect(result[:hop_count]).to be_nil
      expect(result[:entities]).to eq([])
      expect(result[:relations]).to eq([])
    end

    it "raises ResourceNotFound when the source is missing" do
      expect {
        tool.call(from_entity_id: 999_999, to_entity_id: a.id)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /999999/)
    end

    it "raises ResourceNotFound when the target is missing" do
      expect {
        tool.call(from_entity_id: a.id, to_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /999999/)
    end

    it "raises InternalServerError on unexpected errors" do
      allow_any_instance_of(GraphTraversalService).to receive(:shortest_path).and_raise(StandardError.new("boom"))

      expect {
        tool.call(from_entity_id: a.id, to_entity_id: c.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
    end
  end
end
