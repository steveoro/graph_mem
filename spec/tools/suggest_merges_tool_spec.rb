# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuggestMergesTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('suggest_merges')
      end
    end

    describe '.description' do
      it 'returns a non-empty description' do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe '#input_schema_to_json' do
    it 'returns the correct schema with all optional parameters' do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq([])
      expect(schema[:properties]).to have_key(:threshold)
      expect(schema[:properties]).to have_key(:limit)
      expect(schema[:properties]).to have_key(:entity_type)
    end
  end

  describe '#call' do
    context 'with no embeddings (default test environment)' do
      before do
        MemoryEntity.create!(name: 'Entity A', entity_type: 'Project')
        MemoryEntity.create!(name: 'Entity B', entity_type: 'Project')
      end

      it 'returns empty suggestions when no entities have embeddings' do
        result = tool.call

        expect(result[:suggestions]).to eq([])
        expect(result[:total]).to eq(0)
        expect(result[:threshold_used]).to eq(SuggestMergesTool::DEFAULT_THRESHOLD)
      end
    end

    context 'parameter defaults' do
      it 'uses default threshold when not specified' do
        result = tool.call
        expect(result[:threshold_used]).to eq(SuggestMergesTool::DEFAULT_THRESHOLD)
      end

      it 'uses custom threshold when specified' do
        result = tool.call(threshold: 0.5)
        expect(result[:threshold_used]).to eq(0.5)
      end

      it 'accepts custom limit parameter' do
        result = tool.call(limit: 5)
        expect(result).to have_key(:suggestions)
      end

      it 'accepts entity_type filter' do
        result = tool.call(entity_type: 'Project')
        expect(result).to have_key(:suggestions)
      end
    end

    context 'return format' do
      it 'returns the expected structure' do
        result = tool.call

        expect(result).to have_key(:suggestions)
        expect(result).to have_key(:total)
        expect(result).to have_key(:threshold_used)
        expect(result[:suggestions]).to be_an(Array)
        expect(result[:total]).to be_a(Integer)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:where).and_raise(StandardError.new("DB error"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Failed to generate merge suggestions/)
      end
    end
  end
end
