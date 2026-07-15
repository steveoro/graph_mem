# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RankObservationsTool, type: :model do
  let(:tool) { described_class.new }
  let!(:entity) { MemoryEntity.create!(name: 'Ranked Entity', entity_type: 'Project') }
  let!(:high_trust) do
    MemoryObservation.create!(memory_entity: entity, content: 'high', confidence: 0.95, source: 'official')
  end
  let!(:low_trust) do
    MemoryObservation.create!(memory_entity: entity, content: 'low', confidence: 0.3, source: 'hearsay')
  end

  describe '.tool_name' do
    it 'returns the correct tool name' do
      expect(described_class.tool_name).to eq('rank_observations')
    end
  end

  describe '#input_schema_to_json' do
    it 'includes entity_id and optional flags' do
      schema = described_class.input_schema_to_json
      expect(schema[:required]).to eq([ 'entity_id' ])
      expect(schema[:properties]).to have_key(:include_obsolete)
      expect(schema[:properties]).to have_key(:limit)
    end
  end

  describe '#call' do
    it 'returns observations sorted by trust score descending' do
      result = tool.call(entity_id: entity.id)

      expect(result[:observations].first[:observation_id]).to eq(high_trust.id)
      expect(result[:observations].last[:observation_id]).to eq(low_trust.id)
    end

    it 'limits the result set' do
      result = tool.call(entity_id: entity.id, limit: 1)

      expect(result[:observations].length).to eq(1)
      expect(result[:observations].first[:observation_id]).to eq(high_trust.id)
    end

    it 'raises ResourceNotFound for a missing entity' do
      expect {
        tool.call(entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound)
    end

    it 'includes trust_score in each observation' do
      result = tool.call(entity_id: entity.id)

      expect(result[:observations].first).to have_key(:trust_score)
    end
  end
end
