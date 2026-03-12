# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SetContextTool, type: :model do
  let(:tool) { described_class.new }

  let!(:project) { MemoryEntity.create!(name: 'My Project', entity_type: 'Project') }

  after(:each) do
    GraphMemContext.clear!
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('set_context')
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
      it 'sets the context and returns entity info' do
        result = tool.call(entity_id: project.id)

        expect(result[:status]).to eq("context_set")
        expect(result[:entity_id]).to eq(project.id)
        expect(result[:entity_name]).to eq('My Project')
        expect(result[:entity_type]).to eq('Project')
      end

      it 'sets GraphMemContext.current_project_id' do
        tool.call(entity_id: project.id)
        expect(GraphMemContext.current_project_id).to eq(project.id)
      end

      it 'can overwrite an existing context' do
        other_project = MemoryEntity.create!(name: 'Other Project', entity_type: 'Project')

        tool.call(entity_id: project.id)
        expect(GraphMemContext.current_project_id).to eq(project.id)

        tool.call(entity_id: other_project.id)
        expect(GraphMemContext.current_project_id).to eq(other_project.id)
      end

      it 'works with non-Project entity types' do
        task = MemoryEntity.create!(name: 'A Task', entity_type: 'Task')
        result = tool.call(entity_id: task.id)

        expect(result[:status]).to eq("context_set")
        expect(result[:entity_type]).to eq('Task')
      end
    end

    context 'entity not found' do
      it 'raises ResourceNotFound for non-existent entity_id' do
        expect {
          tool.call(entity_id: 999_999)
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
      end

      it 'does not modify context when entity is not found' do
        GraphMemContext.current_project_id = project.id

        begin
          tool.call(entity_id: 999_999)
        rescue McpGraphMemErrors::ResourceNotFound
          # expected
        end

        expect(GraphMemContext.current_project_id).to eq(project.id)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:find_by).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call(entity_id: project.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
