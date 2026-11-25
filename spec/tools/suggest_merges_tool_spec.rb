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
      schema = described_class.input_schema_to_json
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

    # An unembedded entity holds the zero vector (spec/support/zero_vector_helpers.rb).
    context 'with an unembedded entity' do
      include_context 'zero-vector placeholders'

      it 'never compares it, as an anchor or as a candidate' do
        left = assign_test_embedding!(MemoryEntity.create!(name: 'SynthEntity1', entity_type: 'Task'), 1.0, 0.0)
        right = assign_test_embedding!(MemoryEntity.create!(name: 'SynthEntity2', entity_type: 'Task'), 0.99, Math.sqrt(1 - (0.99**2)))
        pending_entity = unembedded { MemoryEntity.create!(name: 'SynthEntity3', entity_type: 'Task') }

        result = nil
        sql = vector_distance_sql { result = tool.call(threshold: 0.3) }

        pairs = result[:suggestions].map { |suggestion| [ suggestion[:entity_a][:entity_id], suggestion[:entity_b][:entity_id] ] }
        expect(pairs).to eq([ [ left.id, right.id ] ])
        expect(sql.size).to eq(2)
        expect(sql).to all(match(/embedded_at`? IS NOT NULL/))
        expect(sql.grep(/WHERE id = #{pending_entity.id}\b/)).to be_empty
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
      it 'raises InternalServerError on unexpected errors without leaking the original message' do
        allow(MemoryEntity).to receive(:with_embedding).and_raise(StandardError.new("DB error"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
          expect(error.message).not_to include("DB error")
        end
      end

      it 're-raises Timeout::Error so the envelope can map category timeout' do
        allow(MemoryEntity).to receive(:with_embedding).and_raise(Timeout::Error.new("execution expired"))

        expect {
          tool.call
        }.to raise_error(Timeout::Error, "execution expired")
      end
    end
  end
end
