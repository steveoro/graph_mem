# frozen_string_literal: true

require "rails_helper"

# D-7 (ui-dashboard-plan §6.D, mcp-sdk-1.9.0 plan step Q): search, get_entities, rank_observations and
# summarize advertise `maxLength: 2048` on `query` and refuse a longer one with the ToolError envelope
# before any query work; a 2,048-character query runs as before. Synthetic data only.
RSpec.describe "The D-7 query length cap" do
  let(:server) { GraphMem::OfficialMcp::ServerFactory.for(:default) }
  let!(:project) { MemoryEntity.create!(name: "Synth Cap Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }

  before { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders frames.") }

  def tool_call(name, arguments)
    reply = JSON.parse(JSON.generate(server.handle({ jsonrpc: "2.0", id: 9, method: "tools/call",
                                                     params: { name: name, arguments: arguments } })))
    reply.fetch("result")
  end

  # Records each instance of the tool class the call builds, so the spec can tell whether #call ran.
  def watch(tool_class)
    built = []
    allow(tool_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |tool|
        allow(tool).to receive(:call).and_call_original
        built << tool
      end
    end
    built
  end

  {
    SearchTool => ->(_ids, query) { { query: query } },
    GetEntitiesTool => ->(ids, query) { { entity_ids: [ ids[:widget] ], query: query } },
    RankObservationsTool => ->(ids, query) { { entity_id: ids[:widget], query: query } },
    SummarizeTool => ->(_ids, query) { { query: query } }
  }.each do |tool_class, arguments|
    describe tool_class.tool_name do
      let(:ids) { { widget: widget.id } }

      it "advertises maxLength 2048 on query" do
        expect(tool_class.input_schema_to_json.dig(:properties, :query, :maxLength)).to eq(ApplicationTool::MAX_QUERY_LENGTH)
        expect(ApplicationTool::MAX_QUERY_LENGTH).to eq(2_048)
      end

      it "refuses a 2,049-character query with the error envelope and runs no query work" do
        built = watch(tool_class)

        result = tool_call(tool_class.tool_name, arguments.call(ids, "q" * 2_049))

        expect(result["isError"]).to be(true)
        expect(JSON.parse(result.dig("content", 0, "text"))).to include(
          "error" => true, "tool" => tool_class.tool_name, "message" => "Query is too long (max 2048 characters)."
        )
        expect(built.sole).not_to have_received(:call)
      end

      it "runs a 2,048-character query as before" do
        built = watch(tool_class)

        result = tool_call(tool_class.tool_name, arguments.call(ids, "SynthWidget #{'q' * 2_036}"))

        expect(result["isError"]).not_to be(true)
        expect(built.sole).to have_received(:call)
      end
    end
  end
end
