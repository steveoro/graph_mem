# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GetEntityTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity) do
    MemoryEntity.create!(
      name: 'Test Entity',
      entity_type: 'Project',
      aliases: 'te|test',
      description: 'A test project'
    )
  end

  let!(:observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: 'This is a test observation'
    )
  end

  let!(:related_entity) do
    MemoryEntity.create!(name: 'Related Entity', entity_type: 'Task')
  end

  let!(:relation_to) do
    MemoryRelation.create!(
      from_entity_id: entity.id,
      to_entity_id: related_entity.id,
      relation_type: 'depends_on'
    )
  end

  let!(:relation_from) do
    MemoryRelation.create!(
      from_entity_id: related_entity.id,
      to_entity_id: entity.id,
      relation_type: 'part_of'
    )
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('get_entity')
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
      expect(schema[:required]).to eq([ "entity_id" ])
      expect(schema[:properties]).to have_key(:entity_id)
    end
  end

  describe '#call' do
    context 'with a valid entity_id' do
      it 'returns entity details' do
        result = tool.call(entity_id: entity.id)

        expect(result[:entity_id]).to eq(entity.id)
        expect(result[:name]).to eq('Test Entity')
        expect(result[:entity_type]).to eq('Project')
        expect(result[:description]).to eq('A test project')
        expect(result[:created_at]).to be_a(String)
        expect(result[:updated_at]).to be_a(String)
      end

      it 'includes observations' do
        result = tool.call(entity_id: entity.id)

        expect(result[:observations]).to be_an(Array)
        expect(result[:observations].length).to eq(1)

        obs = result[:observations].first
        expect(obs[:observation_id]).to eq(observation.id)
        expect(obs[:observation_content]).to eq('This is a test observation')
        expect(obs[:created_at]).to be_a(String)
        expect(obs[:updated_at]).to be_a(String)
      end

      it 'includes relations_from (relations pointing TO this entity)' do
        result = tool.call(entity_id: entity.id)

        expect(result[:relations_from]).to be_an(Array)
        expect(result[:relations_from].length).to eq(1)

        rel = result[:relations_from].first
        expect(rel[:relation_id]).to eq(relation_from.id)
        expect(rel[:relation_type]).to eq('part_of')
      end

      it 'includes relations_to (relations FROM this entity)' do
        result = tool.call(entity_id: entity.id)

        expect(result[:relations_to]).to be_an(Array)
        expect(result[:relations_to].length).to eq(1)

        rel = result[:relations_to].first
        expect(rel[:relation_id]).to eq(relation_to.id)
        expect(rel[:relation_type]).to eq('depends_on')
      end

      it 'returns empty arrays when entity has no observations or relations' do
        bare_entity = MemoryEntity.create!(name: 'Bare Entity', entity_type: 'Task')
        result = tool.call(entity_id: bare_entity.id)

        expect(result[:observations]).to eq([])
        expect(result[:relations_from]).to eq([])
        expect(result[:relations_to]).to eq([])
      end
    end

    context 'with non-existent entity_id' do
      it 'raises ResourceNotFound' do
        expect {
          tool.call(entity_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:includes).and_raise(StandardError.new("DB error"))

        expect {
          tool.call(entity_id: entity.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
