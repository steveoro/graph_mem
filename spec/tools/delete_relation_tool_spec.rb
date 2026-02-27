# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DeleteRelationTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: 'Entity A', entity_type: 'Project') }
  let!(:entity_b) { MemoryEntity.create!(name: 'Entity B', entity_type: 'Task') }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('delete_relation')
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
      expect(schema[:required]).to eq([ "relation_id" ])
      expect(schema[:properties]).to have_key(:relation_id)
    end
  end

  describe '#call' do
    context 'deleting an existing relation' do
      it 'deletes the relation and returns its attributes' do
        relation = MemoryRelation.create!(
          from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on'
        )
        rel_id = relation.id

        result = tool.call(relation_id: rel_id)

        expect(result[:relation_id]).to eq(rel_id)
        expect(result[:from_entity_id]).to eq(entity_a.id)
        expect(result[:to_entity_id]).to eq(entity_b.id)
        expect(result[:relation_type]).to eq('depends_on')
        expect(result[:message]).to include("deleted successfully")
        expect(MemoryRelation.find_by(id: rel_id)).to be_nil
      end

      it 'decrements the relation count' do
        relation = MemoryRelation.create!(
          from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'part_of'
        )

        expect {
          tool.call(relation_id: relation.id)
        }.to change(MemoryRelation, :count).by(-1)
      end

      it 'returns ISO 8601 timestamps' do
        relation = MemoryRelation.create!(
          from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'relates_to'
        )
        result = tool.call(relation_id: relation.id)

        expect { Time.iso8601(result[:created_at]) }.not_to raise_error
        expect { Time.iso8601(result[:updated_at]) }.not_to raise_error
      end
    end

    context 'relation not found' do
      it 'raises ResourceNotFound for non-existent relation_id' do
        expect {
          tool.call(relation_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'destroy failure' do
      it 'raises OperationFailed when destroy! fails' do
        relation = MemoryRelation.create!(
          from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on'
        )
        allow_any_instance_of(MemoryRelation).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new("Cannot delete")
        )

        expect {
          tool.call(relation_id: relation.id)
        }.to raise_error(McpGraphMemErrors::OperationFailed, /Failed to delete/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        relation = MemoryRelation.create!(
          from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on'
        )
        allow(MemoryRelation).to receive(:find).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(relation_id: relation.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
