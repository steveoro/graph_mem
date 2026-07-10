# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Per-client MCP context isolation", type: :integration do
  let!(:project_a) { MemoryEntity.create!(name: "Agent A Project", entity_type: "Project") }
  let!(:project_b) { MemoryEntity.create!(name: "Agent B Project", entity_type: "Project") }

  let(:agent_a_headers) { { "x-mcp-client" => "cursor-A" } }
  let(:agent_b_headers) { { "X-MCP-Client" => "cursor-B" } }

  let(:set_context_a) { SetContextTool.new(headers: agent_a_headers) }
  let(:set_context_b) { SetContextTool.new(headers: agent_b_headers) }
  let(:get_context_a) { GetContextTool.new(headers: agent_a_headers) }
  let(:get_context_b) { GetContextTool.new(headers: agent_b_headers) }
  let(:clear_context_a) { ClearContextTool.new(headers: agent_a_headers) }

  after { GraphMemContext.clear_all! }

  it "isolates set_context between agents using normalized HTTP header shapes" do
    set_context_a.call(entity_id: project_a.id)
    set_context_b.call(entity_id: project_b.id)

    expect(get_context_a.call[:entity_id]).to eq(project_a.id)
    expect(get_context_b.call[:entity_id]).to eq(project_b.id)
  end

  it "falls back to the default client when X-MCP-Client is absent" do
    default_tool = SetContextTool.new
    default_get = GetContextTool.new

    default_tool.call(entity_id: project_a.id)

    expect(default_get.call[:entity_id]).to eq(project_a.id)
    expect(GraphMemContext.for("default").current_project_id).to eq(project_a.id)
    expect(GraphMemContext.for("cursor-A").current_project_id).to be_nil
  end

  it "does not expose one agent's context to another via get_context" do
    set_context_a.call(entity_id: project_a.id)

    expect(get_context_b.call[:status]).to eq("no_context")
  end

  it "clears only the requesting agent's context" do
    set_context_a.call(entity_id: project_a.id)
    set_context_b.call(entity_id: project_b.id)

    clear_context_a.call

    expect(get_context_a.call[:status]).to eq("no_context")
    expect(get_context_b.call[:entity_id]).to eq(project_b.id)
  end
end
