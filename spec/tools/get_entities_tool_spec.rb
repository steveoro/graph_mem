# frozen_string_literal: true

require "rails_helper"

RSpec.describe GetEntitiesTool, type: :model do
  let(:tool) { described_class.new }
  let!(:first) { MemoryEntity.create!(name: "Known first", entity_type: "Project") }
  let!(:second) { MemoryEntity.create!(name: "Known second", entity_type: "Task") }

  describe ".input_schema_to_json" do
    it "advertises entity_ids and relation projection options" do
      schema = described_class.input_schema_to_json

      expect(schema[:required]).to eq([ "entity_ids" ])
      expect(schema[:properties]).to include(:entity_ids, :relations, :include_obsolete, :include_ranked)
    end
  end

  describe "#call" do
    it "returns the canonical envelope" do
      result = tool.call(entity_ids: [ second.id, first.id ])

      expect(result[:entities].pluck(:entity_id)).to eq([ second.id, first.id ])
      expect(result).to include(
        relations: [],
        missing_entity_ids: [],
        relation_scope: "internal"
      )
      expect(result[:entities].first[:observations]).to eq([])
    end

    it "returns partial multi-ID results with missing IDs" do
      result = tool.call(entity_ids: [ first.id, 999_999 ])

      expect(result[:entities].pluck(:entity_id)).to eq([ first.id ])
      expect(result[:missing_entity_ids]).to eq([ 999_999 ])
    end

    it "maps one missing ID to a canonical not-found error" do
      expect {
        tool.call(entity_ids: [ 999_999 ])
      }.to raise_error(McpGraphMemErrors::ResourceNotFound) do |error|
        expect(error.next_move).to include("search")
        expect(error.next_move).to include("get_entities")
      end
    end
  end
end
