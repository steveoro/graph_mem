# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BulkUpdateTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('bulk_update')
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
    it 'returns the correct schema with entities, observations, and relations' do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq([])
      expect(schema[:properties]).to have_key(:entities)
      expect(schema[:properties]).to have_key(:observations)
      expect(schema[:properties]).to have_key(:relations)
    end
  end

  describe '#call' do
    context 'creating entities' do
      it 'creates multiple entities' do
        result = tool.call(entities: [
          { name: 'Entity 1', entity_type: 'Project' },
          { name: 'Entity 2', entity_type: 'Task' }
        ])

        expect(result[:created_entities].length).to eq(2)
        expect(result[:summary][:entities_created]).to eq(2)
      end

      it 'creates entity with optional fields' do
        result = tool.call(entities: [
          { name: 'Full Entity', entity_type: 'Project', aliases: 'fe', description: 'desc' }
        ])

        entity = MemoryEntity.find(result[:created_entities].first[:entity_id])
        expect(entity.aliases).to eq('fe')
        expect(entity.description).to eq('desc')
      end

      it 'creates entity with inline observations' do
        result = tool.call(entities: [
          { name: 'With Obs', entity_type: 'Project', observations: [ 'obs 1', 'obs 2' ] }
        ])

        entity = MemoryEntity.find(result[:created_entities].first[:entity_id])
        expect(entity.memory_observations.count).to eq(2)
      end
    end

    context 'creating observations' do
      let!(:entity) { MemoryEntity.create!(name: 'Target', entity_type: 'Project') }

      it 'creates observations for existing entities' do
        result = tool.call(observations: [
          { entity_id: entity.id, text_content: 'Observation 1' },
          { entity_id: entity.id, text_content: 'Observation 2' }
        ])

        expect(result[:created_observations].length).to eq(2)
        expect(result[:summary][:observations_created]).to eq(2)
      end
    end

    context 'creating relations' do
      let!(:entity_a) { MemoryEntity.create!(name: 'From Entity', entity_type: 'Project') }
      let!(:entity_b) { MemoryEntity.create!(name: 'To Entity', entity_type: 'Task') }

      it 'creates relations between entities' do
        result = tool.call(relations: [
          { from_entity_id: entity_a.id, to_entity_id: entity_b.id, relation_type: 'depends_on' }
        ])

        expect(result[:created_relations].length).to eq(1)
        expect(result[:summary][:relations_created]).to eq(1)

        rel = result[:created_relations].first
        expect(rel[:from]).to eq(entity_a.id)
        expect(rel[:to]).to eq(entity_b.id)
        expect(rel[:type]).to eq('depends_on')
      end
    end

    context 'mixed operations' do
      let!(:existing) { MemoryEntity.create!(name: 'Existing', entity_type: 'Project') }

      it 'performs all operation types in a single call' do
        result = tool.call(
          entities: [ { name: 'New Entity', entity_type: 'Task' } ],
          observations: [ { entity_id: existing.id, text_content: 'Bulk obs' } ],
          relations: []
        )

        expect(result[:summary][:entities_created]).to eq(1)
        expect(result[:summary][:observations_created]).to eq(1)
        expect(result[:summary][:relations_created]).to eq(0)
      end
    end

    context 'transactional rollback' do
      let!(:existing) { MemoryEntity.create!(name: 'Existing For Rollback', entity_type: 'Project') }

      it 'rolls back all changes when entity creation fails' do
        initial_entity_count = MemoryEntity.count

        expect {
          tool.call(entities: [
            { name: 'Good Entity', entity_type: 'Project' },
            { name: 'Existing For Rollback', entity_type: 'Project' }
          ])
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /rolled back/)

        expect(MemoryEntity.count).to eq(initial_entity_count)
      end

      it 'rolls back entities when observation creation fails' do
        initial_entity_count = MemoryEntity.count
        initial_obs_count = MemoryObservation.count

        expect {
          tool.call(
            entities: [ { name: 'Will Rollback', entity_type: 'Task' } ],
            observations: [ { entity_id: 999_999, text_content: 'Invalid entity' } ]
          )
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /rolled back/)

        expect(MemoryEntity.count).to eq(initial_entity_count)
        expect(MemoryObservation.count).to eq(initial_obs_count)
      end
    end

    context 'validation: no operations' do
      it 'raises InvalidArgumentsError when no operations are provided' do
        expect {
          tool.call(entities: [], observations: [], relations: [])
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one operation/)
      end

      it 'raises InvalidArgumentsError when all arrays are nil/empty' do
        expect {
          tool.call
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one operation/)
      end
    end

    context 'validation: max operations' do
      it 'raises InvalidArgumentsError when exceeding MAX_OPERATIONS' do
        entities = 51.times.map { |i| { name: "Entity #{i}", entity_type: 'Task' } }

        expect {
          tool.call(entities: entities)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Maximum #{BulkUpdateTool::MAX_OPERATIONS}/)
      end

      it 'counts operations across all arrays' do
        entity = MemoryEntity.create!(name: 'Bulk Target', entity_type: 'Project')

        entities = 20.times.map { |i| { name: "Bulk E#{i}", entity_type: 'Task' } }
        observations = 20.times.map { { entity_id: entity.id, text_content: 'obs' } }
        relations_data = 11.times.map { { from_entity_id: entity.id, to_entity_id: entity.id, relation_type: 'relates_to' } }

        expect {
          tool.call(entities: entities, observations: observations, relations: relations_data)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Maximum/)
      end

      it 'accepts exactly MAX_OPERATIONS' do
        entities = BulkUpdateTool::MAX_OPERATIONS.times.map { |i| { name: "Max E#{i}", entity_type: 'Task' } }

        expect {
          tool.call(entities: entities)
        }.not_to raise_error
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(ActiveRecord::Base).to receive(:transaction).and_raise(StandardError.new("DB failure"))

        expect {
          tool.call(entities: [ { name: 'Fail', entity_type: 'Task' } ])
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Bulk operation failed/)
      end
    end
  end
end
