# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CreateRelationTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: 'Entity A', entity_type: 'Project') }
  let!(:entity_b) { MemoryEntity.create!(name: 'Entity B', entity_type: 'Task') }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('create_relation')
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
      expect(schema[:required]).to contain_exactly("from_entity_id", "to_entity_id", "relation_type")
      expect(schema[:properties].keys).to contain_exactly(:from_entity_id, :to_entity_id, :relation_type)
    end
  end

  describe '#call' do
    context 'with valid parameters' do
      it 'creates a relation between two entities' do
        expect {
          tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')
        }.to change(MemoryRelation, :count).by(1)
      end

      it 'returns the relation attributes' do
        result = tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')

        expect(result[:relation_id]).to be_a(Integer)
        expect(result[:from_entity_id]).to eq(entity_a.id)
        expect(result[:to_entity_id]).to eq(entity_b.id)
        expect(result[:relation_type]).to eq('depends_on')
        expect(result[:created_at]).to be_a(String)
        expect(result[:updated_at]).to be_a(String)
      end

      it 'allows different relation types' do
        %w[depends_on part_of relates_to implements].each_with_index do |rel_type, i|
          from = MemoryEntity.create!(name: "From #{i}", entity_type: 'Task')
          to = MemoryEntity.create!(name: "To #{i}", entity_type: 'Task')
          result = tool.call(from_entity_id: from.id, to_entity_id: to.id, relation_type: rel_type)
          expect(result[:relation_type]).to eq(rel_type)
        end
      end
    end

    context 'entity not found' do
      it 'raises ResourceNotFound when from_entity does not exist' do
        expect {
          tool.call(from_entity_id: 999_999, to_entity_id: entity_b.id, relation_type: 'depends_on')
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end

      it 'raises ResourceNotFound when to_entity does not exist' do
        expect {
          tool.call(from_entity_id: entity_a.id, to_entity_id: 999_999, relation_type: 'depends_on')
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'duplicate relation' do
      it 'raises an error for duplicate from/to/type combination' do
        tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')

        expect {
          tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end

      it 'allows same entities with different relation_type' do
        tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')

        expect {
          tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'relates_to')
        }.not_to raise_error
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:find).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
