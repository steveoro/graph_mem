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

  describe ".output_schema_to_json" do
    it "describes the post-envelope ordered path response" do
      schema = described_class.output_schema_to_json
      expect(schema[:properties].keys).to include(
        :found, :hop_count, :direction, :entities, :relations, :version, :next_move, :context
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
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, "Entity with ID=999999 not found.") do |error|
        expect(error.category).to eq("not_found")
        expect(error.next_move).to include("`search`")
        expect(error.next_move).to include("`find_shortest_path`")
      end
    end

    it "raises ResourceNotFound when the target is missing" do
      expect {
        tool.call(from_entity_id: a.id, to_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, "Entity with ID=999999 not found.") do |error|
        expect(error.category).to eq("not_found")
        expect(error.next_move).to include("`search`")
        expect(error.next_move).to include("`find_shortest_path`")
      end
    end

    it "raises InternalServerError on unexpected errors" do
      allow_any_instance_of(GraphTraversalService).to receive(:shortest_path).and_raise(StandardError.new("boom"))

      expect {
        tool.call(from_entity_id: a.id, to_entity_id: c.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
        expect(error.message).not_to include("boom")
      end
    end

    it "re-raises Timeout::Error so the envelope can map category timeout" do
      allow_any_instance_of(GraphTraversalService).to receive(:shortest_path).and_raise(Timeout::Error.new("execution expired"))

      expect {
        tool.call(from_entity_id: a.id, to_entity_id: c.id)
      }.to raise_error(Timeout::Error, "execution expired")
    end
  end
end
