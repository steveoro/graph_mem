# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SetContextTool, type: :model do
  let(:tool) { described_class.new }

  let!(:project) { MemoryEntity.create!(name: 'My Project', entity_type: 'Project') }

  after(:each) do
    GraphMemContext.clear_all!
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
      schema = described_class.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:required]).to eq([ "entity_id" ])
      expect(schema[:properties]).to have_key(:entity_id)
      expect(Array(schema[:properties][:entity_id][:type])).to include("integer", "null")
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

      it 'sets graph_mem_context.current_project_id' do
        tool.call(entity_id: project.id)
        expect(tool.graph_mem_context.current_project_id).to eq(project.id)
      end

      it 'scopes context to the X-MCP-Client header' do
        agent_tool = described_class.new(headers: { "HTTP_X_MCP_CLIENT" => "cursor-A" })
        agent_tool.call(entity_id: project.id)

        expect(GraphMemContext.for("cursor-A").current_project_id).to eq(project.id)
        expect(GraphMemContext.for("default").current_project_id).to be_nil
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
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/) do |error|
          expect(error.category).to eq("not_found")
          expect(error.next_move).to include("search")
          expect(error.next_move).to include("set_context")
        end
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

    context 'with a null entity_id' do
      it 'clears the active context through set_context' do
        tool.call(entity_id: project.id)

        result = tool.call(entity_id: nil)

        expect(result).to eq(status: "context_cleared", was_active: true)
        expect(tool.graph_mem_context.current_project_id).to be_nil
      end

      it 'reports when no context was active' do
        expect(tool.call(entity_id: nil)).to eq(status: "context_cleared", was_active: false)
      end
    end

    context 'when the client id looks shared' do
      let!(:other_project) { MemoryEntity.create!(name: 'Other Project', entity_type: 'Project') }

      it 'warns when it overwrites a project set moments ago' do
        tool.call(entity_id: project.id)

        result = tool.call(entity_id: other_project.id)

        expect(result[:warning]).to include('shared by more than one agent')
        expect(result[:warning]).to include('My Project')
        expect(result[:next_move]).to include('X-MCP-Client')
      end

      it 'does not warn on a first set' do
        result = tool.call(entity_id: project.id)

        expect(result).not_to have_key(:warning)
      end

      it 'does not warn when re-setting the same project' do
        tool.call(entity_id: project.id)

        expect(tool.call(entity_id: project.id)).not_to have_key(:warning)
      end

      it 'does not warn once the conflict window has passed' do
        tool.call(entity_id: project.id)
        AgentContext.find_by!(client_id: 'default')
                    .update!(context_set_at: (AgentContext::CONFLICT_WINDOW + 1.minute).ago)

        expect(tool.call(entity_id: other_project.id)).not_to have_key(:warning)
      end

      it 'does not warn across different client ids' do
        described_class.new(headers: { 'HTTP_X_MCP_CLIENT' => 'cursor-A' }).call(entity_id: project.id)

        result = described_class.new(headers: { 'HTTP_X_MCP_CLIENT' => 'cursor-B' })
                                .call(entity_id: other_project.id)

        expect(result).not_to have_key(:warning)
      end

      it 'still sets the context when it warns' do
        tool.call(entity_id: project.id)
        tool.call(entity_id: other_project.id)

        expect(GraphMemContext.current_project_id).to eq(other_project.id)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors without leaking the original message' do
        allow(MemoryEntity).to receive(:find_by).and_raise(StandardError.new("secret-db-failure"))

        expect {
          tool.call(entity_id: project.id)
        }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
          expect(error.message).not_to include("secret-db-failure")
        end
      end

      it 're-raises Timeout::Error so ToolError can map it to timeout' do
        allow(MemoryEntity).to receive(:find_by).and_raise(Timeout::Error.new("execution expired"))

        expect { tool.call(entity_id: project.id) }.to raise_error(Timeout::Error, /execution expired/)
      end
    end
  end
end
