# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GetContextTool, type: :model do
  let(:tool) { described_class.new }

  let!(:project) do
    MemoryEntity.create!(
      name: 'Active Project',
      entity_type: 'Project',
      description: 'A project with context'
    )
  end

  after(:each) do
    GraphMemContext.clear!
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('get_context')
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
    it 'returns an empty-properties schema (no arguments)' do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:properties]).to eq({})
    end
  end

  describe '#call' do
    context 'when no context is set' do
      it 'returns no_context status' do
        result = tool.call

        expect(result[:status]).to eq("no_context")
        expect(result[:message]).to include("No project context")
      end
    end

    context 'when context is active' do
      before { GraphMemContext.current_project_id = project.id }

      it 'returns context_active status with project details' do
        result = tool.call

        expect(result[:status]).to eq("context_active")
        expect(result[:project_id]).to eq(project.id)
        expect(result[:project_name]).to eq('Active Project')
        expect(result[:project_type]).to eq('Project')
        expect(result[:description]).to eq('A project with context')
      end
    end

    context 'when context entity no longer exists' do
      it 'clears stale context and returns context_cleared status' do
        GraphMemContext.current_project_id = 999_999

        result = tool.call

        expect(result[:status]).to eq("context_cleared")
        expect(result[:message]).to include("no longer exists")
        expect(GraphMemContext.current_project_id).to be_nil
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        GraphMemContext.current_project_id = project.id
        allow(MemoryEntity).to receive(:find_by).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
