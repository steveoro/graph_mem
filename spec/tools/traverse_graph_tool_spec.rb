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
      expect(schema[:required]).to eq([])
      expect(schema[:properties].keys).to include(
        :start_entity_id,
        :from_entity_id,
        :to_entity_id,
        :relation_type,
        :relation_types,
        :include,
        :max_depth,
        :direction,
        :max_entities
      )
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
      obsolete = MemoryObservation.create!(memory_entity: a, content: "Historical observation")
      obsolete.mark_obsolete!
      result = tool.call(start_entity_id: a.id, max_depth: 1, direction: "outgoing")

      start_entity = result[:entities].find { |e| e[:entity_id] == a.id }
      expect(start_entity[:observations].first[:content]).to eq("Observation on A")
      expect(start_entity[:observations].first[:status]).to eq(MemoryObservation::ACTIVE_STATUS)
      expect(start_entity[:observations].pluck(:observation_id)).not_to include(obsolete.id)

      relation = result[:relations].find { |r| r[:relation_id] == r_ab.id }
      expect(relation[:weight]).to eq(1.5)
      expect(relation).to have_key(:confidence)
      expect(relation).to have_key(:properties)
    end

    it "supports direct endpoint and global relation queries" do
      endpoint_result = tool.call(from_entity_id: a.id, to_entity_id: b.id)
      global_result = tool.call

      expect(endpoint_result.keys).to eq([ :relations ])
      expect(endpoint_result[:relations].pluck(:relation_id)).to eq([ r_ab.id ])
      expect(global_result[:relations].pluck(:relation_id)).to contain_exactly(r_ab.id, r_bc.id)
    end

    it "uses start and destination IDs as a direct edge filter" do
      result = tool.call(start_entity_id: a.id, to_entity_id: b.id)

      expect(result[:relations].pluck(:relation_id)).to eq([ r_ab.id ])
    end

    it "returns only requested traversal projections" do
      result = tool.call(
        start_entity_id: a.id,
        max_depth: 1,
        direction: "outgoing",
        include: [ "relations" ]
      )

      expect(result.keys).to eq([ :relations ])
      expect(result[:relations].pluck(:relation_id)).to eq([ r_ab.id ])
    end

    it "can include endpoint entities in relation-query mode" do
      result = tool.call(from_entity_id: a.id, include: %w[entities relations])

      expect(result[:entities].pluck(:entity_id)).to include(a.id, b.id)
      expect(result[:relations].pluck(:relation_id)).to eq([ r_ab.id ])
    end

    it "raises ResourceNotFound for a missing start entity" do
      expect {
        tool.call(start_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, "Entity with ID=999999 not found.") do |error|
        expect(error.category).to eq("not_found")
        expect(error.next_move).to include("`search`")
        expect(error.next_move).to include("`traverse_graph`")
      end
    end

    it "raises InternalServerError on unexpected errors" do
      allow_any_instance_of(GraphTraversalService).to receive(:expand).and_raise(StandardError.new("boom"))

      expect {
        tool.call(start_entity_id: a.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
        expect(error.message).not_to include("boom")
      end
    end

    it "re-raises Timeout::Error so the envelope can map category timeout" do
      allow_any_instance_of(GraphTraversalService).to receive(:expand).and_raise(Timeout::Error.new("execution expired"))

      expect {
        tool.call(start_entity_id: a.id)
      }.to raise_error(Timeout::Error, "execution expired")
    end
  end
end
