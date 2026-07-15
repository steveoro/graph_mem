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
      schema = described_class.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq([ "observation_id" ])
      expect(schema[:properties]).to have_key(:observation_id)
    end
  end

  describe '#call' do
    context 'marking an existing observation obsolete' do
      it 'retains the observation and returns its lifecycle attributes' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'To delete')
        obs_id = observation.id

        result = tool.call(observation_id: obs_id, reason: 'Outdated')

        expect(result[:observation_id]).to eq(obs_id)
        expect(result[:memory_entity_id]).to eq(entity.id)
        expect(result[:observation_content]).to eq('To delete')
        expect(result).not_to have_key(:content)
        expect(result[:status]).to eq(MemoryObservation::OBSOLETE_STATUS)
        expect(result[:obsoleted_at]).to be_present
        expect(result[:obsolescence_reason]).to eq('Outdated')
        expect(result[:message]).to include('marked obsolete successfully')
        expect(MemoryObservation.find(obs_id)).to be_obsolete
      end

      it 'does not decrement the observation count' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Count test')

        expect {
          tool.call(observation_id: observation.id)
        }.not_to change(MemoryObservation, :count)
      end

      it 'returns ISO 8601 timestamps' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'TS test')
        result = tool.call(observation_id: observation.id)

        expect { Time.iso8601(result[:created_at]) }.not_to raise_error
        expect { Time.iso8601(result[:updated_at]) }.not_to raise_error
        expect { Time.iso8601(result[:obsoleted_at]) }.not_to raise_error
      end

      it 'is idempotent for an already inactive observation' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Already inactive')
        observation.mark_obsolete!(reason: 'Initial')

        result = tool.call(observation_id: observation.id, reason: 'Ignored')

        expect(result[:status]).to eq(MemoryObservation::OBSOLETE_STATUS)
        expect(result[:obsolescence_reason]).to eq('Initial')
      end
    end

    context 'observation not found' do
      it 'raises ResourceNotFound for non-existent observation_id' do
        expect {
          tool.call(observation_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'obsolescence failure' do
      it 'raises OperationFailed when the lifecycle update fails validation' do
        observation = MemoryObservation.create!(memory_entity: entity, content: 'Fail update')
        allow_any_instance_of(MemoryObservation).to receive(:mark_obsolete!).and_raise(
          ActiveRecord::RecordInvalid.new(observation)
        )

        expect {
          tool.call(observation_id: observation.id)
        }.to raise_error(McpGraphMemErrors::OperationFailed, /Failed to mark/)
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
