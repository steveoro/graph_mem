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
    GraphMemContext.clear_all!
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
      schema = described_class.input_schema_to_json
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

      it 'returns context_active status with entity details' do
        result = tool.call

        expect(result[:status]).to eq("context_active")
        expect(result[:entity_id]).to eq(project.id)
        expect(result[:entity_name]).to eq('Active Project')
        expect(result[:entity_type]).to eq('Project')
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

    context 'session tracking' do
      it 'reports when the context was set' do
        GraphMemContext.for('cursor-A').set_project!(project.id)
        agent_tool = described_class.new(headers: { 'HTTP_X_MCP_CLIENT' => 'cursor-A' })

        expect(agent_tool.call[:context_set_at]).to be_present
      end

      it 'warns when another session is active under the same client id' do
        GraphMemContext.for('cursor-A').set_project!(project.id)
        AgentContext.record_activity!(client_id: 'cursor-A', tool_name: 'get_context', session_id: 'sess-1')

        agent_tool = described_class.new(headers: { 'HTTP_X_MCP_CLIENT' => 'cursor-A' })
        agent_tool.send(:record_client_activity!)
        allow(agent_tool).to receive(:current_session_id).and_return('sess-2')
        agent_tool.send(:record_client_activity!)

        result = agent_tool.call

        expect(result[:warning]).to include('shared by more than one agent')
        expect(result[:next_move]).to include('X-MCP-Client')
      end

      it 'does not warn for a single session' do
        GraphMemContext.for('cursor-A').set_project!(project.id)
        agent_tool = described_class.new(headers: { 'HTTP_X_MCP_CLIENT' => 'cursor-A' })
        allow(agent_tool).to receive(:current_session_id).and_return('sess-1')
        agent_tool.send(:record_client_activity!)
        agent_tool.send(:record_client_activity!)

        expect(agent_tool.call).not_to have_key(:warning)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors without leaking the original message' do
        GraphMemContext.current_project_id = project.id
        allow(MemoryEntity).to receive(:find_by).and_raise(StandardError.new("secret-db-failure"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
          expect(error.message).not_to include("secret-db-failure")
        end
      end

      it 're-raises Timeout::Error so ToolError can map it to timeout' do
        GraphMemContext.current_project_id = project.id
        allow(MemoryEntity).to receive(:find_by).and_raise(Timeout::Error.new("execution expired"))

        expect { tool.call }.to raise_error(Timeout::Error, /execution expired/)
      end
    end
  end
end
