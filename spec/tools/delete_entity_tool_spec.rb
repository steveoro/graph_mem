# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeleteEntityTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('delete_entity')
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
      expect(schema[:required]).to eq([ "entity_id" ])
      expect(schema[:properties]).to have_key(:entity_id)
    end
  end

  describe '#call' do
    context 'deleting an existing entity' do
      it 'deletes the entity and returns its attributes' do
        entity = MemoryEntity.create!(name: 'To Delete', entity_type: 'Task')
        entity_id = entity.id

        result = tool.call(entity_id: entity_id)

        expect(result[:entity_id]).to eq(entity_id)
        expect(result[:name]).to eq('To Delete')
        expect(result[:entity_type]).to eq('Task')
        expect(result[:message]).to include("deleted successfully")
        expect(MemoryEntity.find_by(id: entity_id)).to be_nil
      end

      it 'decrements the entity count' do
        entity = MemoryEntity.create!(name: 'Count Test', entity_type: 'Task')

        expect {
          tool.call(entity_id: entity.id)
        }.to change(MemoryEntity, :count).by(-1)
      end

      it 'cascades deletion to observations' do
        entity = MemoryEntity.create!(name: 'With Obs', entity_type: 'Task')
        MemoryObservation.create!(memory_entity: entity, content: 'obs 1')
        MemoryObservation.create!(memory_entity: entity, content: 'obs 2')

        expect {
          tool.call(entity_id: entity.id)
        }.to change(MemoryObservation, :count).by(-2)
      end

      it 'cascades deletion to relations' do
        entity = MemoryEntity.create!(name: 'With Rels', entity_type: 'Task')
        other = MemoryEntity.create!(name: 'Other', entity_type: 'Project')
        MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: other.id, relation_type: 'depends_on')
        MemoryRelation.create!(from_entity_id: other.id, to_entity_id: entity.id, relation_type: 'part_of')

        expect {
          tool.call(entity_id: entity.id)
        }.to change(MemoryRelation, :count).by(-2)
      end

      it 'rejects deletion of Project root entities' do
        entity = MemoryEntity.create!(name: 'Protected Project', entity_type: 'Project')
        MemoryObservation.create!(memory_entity: entity, content: 'obs 1')

        expect {
          tool.call(entity_id: entity.id)
        }.to raise_error(McpGraphMemErrors::OperationFailed, /Project root entities cannot be deleted or merged away/)

        expect(MemoryEntity.find_by(id: entity.id)).to be_present
        expect(entity.memory_observations.count).to eq(1)
      end

      it 'returns ISO 8601 timestamps' do
        entity = MemoryEntity.create!(name: 'TS Test', entity_type: 'Task')
        result = tool.call(entity_id: entity.id)

        expect { Time.iso8601(result[:created_at]) }.not_to raise_error
        expect { Time.iso8601(result[:updated_at]) }.not_to raise_error
      end

      it 'records the deletion reason in the audit log' do
        entity = MemoryEntity.create!(name: 'Delete With Reason', entity_type: 'Task')

        tool.call(entity_id: entity.id, reason: 'duplicate')

        log = AuditLog.for_record('MemoryEntity', entity.id).where(action: 'delete').first
        expect(log.reason).to eq('duplicate')
      end
    end

    context 'entity not found' do
      it 'raises ResourceNotFound for non-existent entity_id' do
        expect {
          tool.call(entity_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'destroy failure' do
      it 'raises OperationFailed when destroy! fails' do
        entity = MemoryEntity.create!(name: 'Undeletable', entity_type: 'Task')
        allow_any_instance_of(MemoryEntity).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new("Cannot delete")
        )

        expect {
          tool.call(entity_id: entity.id)
        }.to raise_error(McpGraphMemErrors::OperationFailed, /Failed to delete/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        entity = MemoryEntity.create!(name: 'Error Test', entity_type: 'Task')
        allow(MemoryEntity).to receive(:find).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(entity_id: entity.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
