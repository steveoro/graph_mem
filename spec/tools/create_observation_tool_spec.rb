# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CreateObservationTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity) do
    MemoryEntity.create!(name: 'Observation Host', entity_type: 'Project')
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('create_observation')
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
    it 'returns the correct schema' do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to contain_exactly("entity_id", "content")
      expect(schema[:properties]).to have_key(:entity_id)
      expect(schema[:properties]).to have_key(:content)
    end
  end

  describe '#call' do
    context 'with valid parameters' do
      it 'creates an observation linked to the entity' do
        expect {
          tool.call(entity_id: entity.id, text_content: 'New observation')
        }.to change(MemoryObservation, :count).by(1)
      end

      it 'returns observation attributes' do
        result = tool.call(entity_id: entity.id, text_content: 'New observation')

        expect(result[:observation_id]).to be_a(Integer)
        expect(result[:memory_entity_id]).to eq(entity.id)
        expect(result[:observation_content]).to eq('New observation')
        expect(result[:created_at]).to be_a(String)
        expect(result[:updated_at]).to be_a(String)
      end

      it 'increments the entity counter cache' do
        expect {
          tool.call(entity_id: entity.id, text_content: 'Counter test')
        }.to change { entity.reload.memory_observations_count }.by(1)
      end

      it 'allows multiple observations on the same entity' do
        tool.call(entity_id: entity.id, text_content: 'First')
        tool.call(entity_id: entity.id, text_content: 'Second')

        expect(entity.memory_observations.count).to eq(2)
      end
    end

    context 'entity not found' do
      it 'raises ResourceNotFound for non-existent entity_id' do
        expect {
          tool.call(entity_id: 999_999, text_content: 'orphan')
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'validation errors' do
      it 'raises InvalidArgumentsError for blank content' do
        expect {
          tool.call(entity_id: entity.id, text_content: '')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:find).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(entity_id: entity.id, text_content: 'will fail')
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
