# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GetSubgraphByIdsTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: 'Entity A', entity_type: 'Project') }
  let!(:entity_b) { MemoryEntity.create!(name: 'Entity B', entity_type: 'Task') }
  let!(:entity_c) { MemoryEntity.create!(name: 'Entity C', entity_type: 'Issue') }

  let!(:obs_a) { MemoryObservation.create!(memory_entity: entity_a, content: 'Obs for A') }
  let!(:obs_b) { MemoryObservation.create!(memory_entity: entity_b, content: 'Obs for B') }

  let!(:rel_ab) do
    MemoryRelation.create!(from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on')
  end

  let!(:rel_ac) do
    MemoryRelation.create!(from_entity_id: entity_a.id, to_entity_id: entity_c.id, relation_type: 'part_of')
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('get_subgraph_by_ids')
      end
    end

    describe '.description' do
      it 'returns a non-empty description' do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe '#call' do
    context 'with valid entity_ids' do
      it 'returns entities with their observations' do
        result = tool.call(entity_ids: [ entity_a.id, entity_b.id ])

        expect(result[:entities]).to be_an(Array)
        expect(result[:entities].length).to eq(2)

        entity_a_data = result[:entities].find { |e| e[:entity_id] == entity_a.id }
        expect(entity_a_data[:name]).to eq('Entity A')
        expect(entity_a_data[:entity_type]).to eq('Project')
        expect(entity_a_data[:created_at]).to be_a(String)
        expect(entity_a_data[:updated_at]).to be_a(String)
      end

      it 'includes only relations between the requested entities' do
        result = tool.call(entity_ids: [ entity_a.id, entity_b.id ])

        expect(result[:relations].length).to eq(1)
        expect(result[:relations].first[:relation_id]).to eq(rel_ab.id)
      end

      it 'excludes relations to entities outside the requested set' do
        result = tool.call(entity_ids: [ entity_a.id, entity_b.id ])

        relation_ids = result[:relations].map { |r| r[:relation_id] }
        expect(relation_ids).not_to include(rel_ac.id)
      end

      it 'returns all inter-set relations when all entities are requested' do
        result = tool.call(entity_ids: [ entity_a.id, entity_b.id, entity_c.id ])

        expect(result[:relations].length).to eq(2)
      end
    end

    context 'deduplication' do
      it 'deduplicates entity_ids' do
        result = tool.call(entity_ids: [ entity_a.id, entity_a.id, entity_b.id ])

        entity_ids = result[:entities].map { |e| e[:entity_id] }
        expect(entity_ids.length).to eq(entity_ids.uniq.length)
      end
    end

    context 'non-existent IDs' do
      it 'returns only existing entities for mixed valid/invalid IDs' do
        result = tool.call(entity_ids: [ entity_a.id, 999_999 ])

        expect(result[:entities].length).to eq(1)
        expect(result[:entities].first[:entity_id]).to eq(entity_a.id)
      end

      it 'returns empty arrays for all non-existent IDs' do
        result = tool.call(entity_ids: [ 999_998, 999_999 ])

        expect(result[:entities]).to eq([])
        expect(result[:relations]).to eq([])
      end
    end

    context 'empty entity_ids' do
      it 'raises InvalidArgumentsError for empty array' do
        expect {
          tool.call(entity_ids: [])
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /cannot be empty/)
      end
    end

    context 'single entity' do
      it 'returns the entity with no relations' do
        result = tool.call(entity_ids: [ entity_c.id ])

        expect(result[:entities].length).to eq(1)
        expect(result[:relations]).to eq([])
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:where).and_raise(StandardError.new("DB error"))

        expect {
          tool.call(entity_ids: [ entity_a.id ])
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
