# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ClearContextTool, type: :model do
  let(:tool) { described_class.new }

  after(:each) do
    GraphMemContext.clear!
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('clear_context')
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
    context 'when context is active' do
      it 'clears the context and reports it was active' do
        project = MemoryEntity.create!(name: 'To Clear', entity_type: 'Project')
        GraphMemContext.current_project_id = project.id

        result = tool.call

        expect(result[:status]).to eq("context_cleared")
        expect(result[:was_active]).to be true
        expect(GraphMemContext.current_project_id).to be_nil
      end
    end

    context 'when no context is set' do
      it 'clears (noop) and reports it was not active' do
        result = tool.call

        expect(result[:status]).to eq("context_cleared")
        expect(result[:was_active]).to be false
        expect(GraphMemContext.current_project_id).to be_nil
      end
    end

    context 'idempotency' do
      it 'can be called multiple times safely' do
        project = MemoryEntity.create!(name: 'Idem', entity_type: 'Project')
        GraphMemContext.current_project_id = project.id

        result1 = tool.call
        result2 = tool.call

        expect(result1[:was_active]).to be true
        expect(result2[:was_active]).to be false
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(GraphMemContext).to receive(:current_project_id).and_raise(StandardError.new("unexpected"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
