# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DetectContradictionsTool, type: :model do
  let(:tool) { described_class.new }
  let!(:entity) { MemoryEntity.create!(name: 'Contradiction Entity', entity_type: 'Project') }

  describe '.tool_name' do
    it 'returns the correct tool name' do
      expect(described_class.tool_name).to eq('detect_contradictions')
    end
  end

  describe '#input_schema_to_json' do
    it 'includes entity_id and optional parameters' do
      schema = described_class.input_schema_to_json
      expect(schema[:required]).to eq([ 'entity_id' ])
      expect(schema[:properties]).to have_key(:max_distance)
      expect(schema[:properties]).to have_key(:max_results)
    end
  end

  describe '#call' do
    it 'raises ResourceNotFound for a missing entity' do
      expect {
        tool.call(entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound)
    end

    it 'returns an empty candidate list when no contradictions exist' do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

      result = tool.call(entity_id: entity.id)

      expect(result[:entity_id]).to eq(entity.id)
      expect(result[:candidate_count]).to eq(0)
      expect(result[:candidates]).to eq([])
    end
  end
end
