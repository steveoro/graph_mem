# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CreateEntityTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('create_entity')
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
      expect(schema[:required]).to contain_exactly("name", "entity_type")
      expect(schema[:properties]).to have_key(:name)
      expect(schema[:properties]).to have_key(:entity_type)
      expect(schema[:properties]).to have_key(:observations)
      expect(schema[:properties]).to have_key(:aliases)
      expect(schema[:properties]).to have_key(:description)
    end
  end

  describe '#call' do
    before do
      allow_any_instance_of(CreateEntityTool).to receive(:find_similar_entity).and_return(nil)
    end

    context 'with required parameters only' do
      it 'creates a new entity' do
        expect {
          tool.call(name: 'TestProject', entity_type: 'Project')
        }.to change(MemoryEntity, :count).by(1)
      end

      it 'returns the created entity attributes' do
        result = tool.call(name: 'TestProject', entity_type: 'Project')

        expect(result[:entity_id]).to be_a(Integer)
        expect(result[:name]).to eq('TestProject')
        expect(result[:entity_type]).to eq('Project')
        expect(result[:created_at]).to be_a(String)
        expect(result[:updated_at]).to be_a(String)
        expect(result[:memory_observations_count]).to eq(0)
      end
    end

    context 'with optional parameters' do
      it 'creates entity with aliases' do
        result = tool.call(name: 'Rails App', entity_type: 'Project', aliases: 'webapp|my-app')
        expect(result[:aliases]).to eq('webapp|my-app')
      end

      it 'creates entity with description' do
        result = tool.call(name: 'Rails App', entity_type: 'Project', description: 'A web application')
        expect(result[:description]).to eq('A web application')
      end

      it 'creates entity with observations' do
        result = tool.call(
          name: 'Rails App',
          entity_type: 'Project',
          observations: [ 'Uses Ruby 3.2', 'Deployed on Heroku' ]
        )

        expect(result[:memory_observations_count]).to eq(2)
        entity = MemoryEntity.find(result[:entity_id])
        expect(entity.memory_observations.pluck(:content)).to contain_exactly(
          'Uses Ruby 3.2', 'Deployed on Heroku'
        )
      end

      it 'creates entity with all optional parameters' do
        result = tool.call(
          name: 'Full Entity',
          entity_type: 'Project',
          aliases: 'fe|full',
          description: 'A fully specified entity',
          observations: [ 'observation one' ]
        )

        expect(result[:name]).to eq('Full Entity')
        expect(result[:aliases]).to eq('fe|full')
        expect(result[:description]).to eq('A fully specified entity')
        expect(result[:memory_observations_count]).to eq(1)
      end
    end

    context 'dedup check' do
      it 'returns a warning when a similar entity exists' do
        existing = MemoryEntity.create!(name: 'Existing Project', entity_type: 'Project')

        similar_result = VectorSearchStrategy::SearchResult.new(
          entity: existing, distance: 0.1
        )
        allow_any_instance_of(CreateEntityTool).to receive(:find_similar_entity).and_return(similar_result)

        result = tool.call(name: 'Existing Project Copy', entity_type: 'Project')

        expect(result).to have_key(:warning)
        expect(result[:existing_entity][:entity_id]).to eq(existing.id)
        expect(result[:existing_entity][:similarity_distance]).to be < CreateEntityTool::DEDUP_DISTANCE_THRESHOLD
      end

      it 'creates entity when no similar entity is found' do
        allow_any_instance_of(CreateEntityTool).to receive(:find_similar_entity).and_return(nil)

        result = tool.call(name: 'Unique Entity', entity_type: 'Project')
        expect(result[:entity_id]).to be_a(Integer)
        expect(result).not_to have_key(:warning)
      end
    end

    context 'validation errors' do
      it 'raises InvalidArgumentsError for duplicate name' do
        MemoryEntity.create!(name: 'Duplicate', entity_type: 'Project')

        expect {
          tool.call(name: 'Duplicate', entity_type: 'Project')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
      end

      it 'raises InvalidArgumentsError when name is blank' do
        expect {
          tool.call(name: '', entity_type: 'Project')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
      end

      it 'raises InvalidArgumentsError when entity_type is blank' do
        expect {
          tool.call(name: 'No Type', entity_type: '')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:create!).and_raise(StandardError.new("DB down"))
        allow_any_instance_of(CreateEntityTool).to receive(:find_similar_entity).and_return(nil)

        expect {
          tool.call(name: 'Fail', entity_type: 'Project')
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
