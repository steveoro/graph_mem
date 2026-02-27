# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeleteObservationTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity) do
    MemoryEntity.create!(name: 'Host Entity', entity_type: 'Project')
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('delete_observation')
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
      expect(schema[:required]).to eq([ "observation_id" ])
      expect(schema[:properties]).to have_key(:observation_id)
    end
  end

  describe '#call' do
    context 'deleting an existing observation' do
      it 'deletes the observation and returns its attributes' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'To delete')
        obs_id = observation.id

        result = tool.call(observation_id: obs_id)

        expect(result[:observation_id]).to eq(obs_id)
        expect(result[:memory_entity_id]).to eq(entity.id)
        expect(result[:content]).to eq('To delete')
        expect(result[:message]).to include("deleted successfully")
        expect(MemoryObservation.find_by(id: obs_id)).to be_nil
      end

      it 'decrements the observation count' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Count test')

        expect {
          tool.call(observation_id: observation.id)
        }.to change(MemoryObservation, :count).by(-1)
      end

      it 'returns ISO 8601 timestamps' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'TS test')
        result = tool.call(observation_id: observation.id)

        expect { Time.iso8601(result[:created_at]) }.not_to raise_error
        expect { Time.iso8601(result[:updated_at]) }.not_to raise_error
      end
    end

    context 'observation not found' do
      it 'raises ResourceNotFound for non-existent observation_id' do
        expect {
          tool.call(observation_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'destroy failure' do
      it 'raises OperationFailed when destroy! fails' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Fail destroy')
        allow_any_instance_of(MemoryObservation).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new("Cannot delete")
        )

        expect {
          tool.call(observation_id: observation.id)
        }.to raise_error(McpGraphMemErrors::OperationFailed, /Failed to delete/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Error test')
        allow(MemoryObservation).to receive(:find).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(observation_id: observation.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
