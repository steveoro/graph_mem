# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UpdateEntityTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity) do
    MemoryEntity.create!(
      name: 'Original Name',
      entity_type: 'Project',
      aliases: 'orig',
      description: 'Original description'
    )
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('update_entity')
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
      expect(schema[:properties].keys).to contain_exactly(:entity_id, :name, :entity_type, :aliases, :description)
    end
  end

  describe '#call' do
    context 'updating individual attributes' do
      it 'updates the name' do
        result = tool.call(entity_id: entity.id, name: 'New Name')

        expect(result[:name]).to eq('New Name')
        expect(entity.reload.name).to eq('New Name')
      end

      it 'updates the entity_type' do
        result = tool.call(entity_id: entity.id, entity_type: 'Task')

        expect(result[:entity_type]).to eq('Task')
        expect(entity.reload.entity_type).to eq('Task')
      end

      it 'updates aliases' do
        result = tool.call(entity_id: entity.id, aliases: 'new-alias|another')

        expect(result[:aliases]).to eq('new-alias|another')
        expect(entity.reload.aliases).to eq('new-alias|another')
      end

      it 'updates description' do
        result = tool.call(entity_id: entity.id, description: 'Updated description')

        expect(result[:description]).to eq('Updated description')
        expect(entity.reload.description).to eq('Updated description')
      end

      it 'clears aliases by passing empty string' do
        result = tool.call(entity_id: entity.id, aliases: '')

        expect(result[:aliases]).to eq('')
        expect(entity.reload.aliases).to eq('')
      end

      it 'clears description by passing empty string' do
        result = tool.call(entity_id: entity.id, description: '')

        expect(result[:description]).to eq('')
        expect(entity.reload.description).to eq('')
      end
    end

    context 'updating multiple attributes at once' do
      it 'updates name and entity_type together' do
        result = tool.call(entity_id: entity.id, name: 'Multi Update', entity_type: 'Framework')

        expect(result[:name]).to eq('Multi Update')
        expect(result[:entity_type]).to eq('Framework')
      end
    end

    context 'return format' do
      it 'returns all expected keys' do
        result = tool.call(entity_id: entity.id, name: 'Format Test')

        expect(result).to include(
          :entity_id, :name, :entity_type, :description, :aliases,
          :created_at, :updated_at, :memory_observations_count
        )
        expect(result[:created_at]).to be_a(String)
        expect(result[:updated_at]).to be_a(String)
      end
    end

    context 'validation: at least one attribute required' do
      it 'raises InvalidArgumentsError when no updatable attributes are provided' do
        expect {
          tool.call(entity_id: entity.id)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one attribute/)
      end
    end

    context 'entity not found' do
      it 'raises ResourceNotFound for non-existent entity_id' do
        expect {
          tool.call(entity_id: 999_999, name: 'Missing')
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end
    end

    context 'uniqueness violation' do
      it 'raises InvalidArgumentsError for duplicate name' do
        MemoryEntity.create!(name: 'Taken Name', entity_type: 'Task')

        expect {
          tool.call(entity_id: entity.id, name: 'Taken Name')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:find_by).and_raise(StandardError.new("DB failure"))

        expect {
          tool.call(entity_id: entity.id, name: 'Error')
        }.to raise_error(McpGraphMemErrors::InternalServerError, /internal server error/)
      end
    end
  end
end
