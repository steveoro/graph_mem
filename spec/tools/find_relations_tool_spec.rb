# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FindRelationsTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: 'Entity A', entity_type: 'Project') }
  let!(:entity_b) { MemoryEntity.create!(name: 'Entity B', entity_type: 'Task') }
  let!(:entity_c) { MemoryEntity.create!(name: 'Entity C', entity_type: 'Issue') }

  let!(:rel_ab) do
    MemoryRelation.create!(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')
  end

  let!(:rel_bc) do
    MemoryRelation.create!(from_entity_id: entity_b.id, to_entity_id: entity_c.id, relation_type: 'part_of')
  end

  let!(:rel_ac) do
    MemoryRelation.create!(from_entity_id: entity_a.id, to_entity_id: entity_c.id, relation_type: 'depends_on')
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('find_relations')
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
      expect(schema[:properties].keys).to contain_exactly(:from_entity_id, :to_entity_id, :relation_type)
    end
  end

  describe '#call' do
    context 'with no filters' do
      it 'returns all relations' do
        results = tool.call

        expect(results).to be_an(Array)
        expect(results.length).to eq(3)
      end

      it 'returns correct relation format' do
        results = tool.call
        rel = results.first

        expect(rel).to have_key(:relation_id)
        expect(rel).to have_key(:from_entity_id)
        expect(rel).to have_key(:to_entity_id)
        expect(rel).to have_key(:relation_type)
        expect(rel).to have_key(:created_at)
        expect(rel).to have_key(:updated_at)
      end
    end

    context 'filtering by from_entity_id' do
      it 'returns only relations from the specified entity' do
        results = tool.call(from_entity_id: entity_a.id)

        expect(results.length).to eq(2)
        expect(results.map { |r| r[:from_entity_id] }).to all(eq(entity_a.id))
      end
    end

    context 'filtering by to_entity_id' do
      it 'returns only relations to the specified entity' do
        results = tool.call(to_entity_id: entity_c.id)

        expect(results.length).to eq(2)
        expect(results.map { |r| r[:to_entity_id] }).to all(eq(entity_c.id))
      end
    end

    context 'filtering by relation_type' do
      it 'returns only relations of the specified type' do
        results = tool.call(relation_type: 'depends_on')

        expect(results.length).to eq(2)
        expect(results.map { |r| r[:relation_type] }).to all(eq('depends_on'))
      end

      it 'returns single result for unique type' do
        results = tool.call(relation_type: 'part_of')
        expect(results.length).to eq(1)
        expect(results.first[:relation_id]).to eq(rel_bc.id)
      end
    end

    context 'combining filters' do
      it 'filters by from_entity_id and relation_type' do
        results = tool.call(from_entity_id: entity_a.id, relation_type: 'depends_on')

        expect(results.length).to eq(2)
      end

      it 'filters by from_entity_id and to_entity_id' do
        results = tool.call(from_entity_id: entity_a.id, to_entity_id: entity_b.id)

        expect(results.length).to eq(1)
        expect(results.first[:relation_id]).to eq(rel_ab.id)
      end

      it 'filters by all three criteria' do
        results = tool.call(
          from_entity_id: entity_a.id,
          to_entity_id: entity_c.id,
          relation_type: 'depends_on'
        )

        expect(results.length).to eq(1)
        expect(results.first[:relation_id]).to eq(rel_ac.id)
      end
    end

    context 'no matching results' do
      it 'returns empty array when no relations match' do
        results = tool.call(relation_type: 'nonexistent_type')
        expect(results).to eq([])
      end

      it 'returns empty array for non-existent entity filter' do
        results = tool.call(from_entity_id: 999_999)
        expect(results).to eq([])
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryRelation).to receive(:all).and_raise(StandardError.new("DB error"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
