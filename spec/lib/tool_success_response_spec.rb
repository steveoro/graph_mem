# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolSuccessResponse do
  let(:active_context) { instance_double(GraphMemContext, active?: true) }
  let(:inactive_context) { instance_double(GraphMemContext, active?: false) }

  describe ".call" do
    it "adds version, a tool hint, and MCP metadata" do
      payload, metadata = described_class.call(
        tool_name: "search",
        result: { mode: "summary", results: [] },
        context: active_context
      )

      expect(payload).to include(
        version: GraphMem::VERSION,
        next_move: include("get_entities")
      )
      expect(payload).not_to have_key(:context)
      expect(metadata).to eq(
        graphMemVersion: GraphMem::VERSION,
        contextStatus: "active"
      )
    end

    it "adds a no-context banner without replacing an existing next_move" do
      payload, = described_class.call(
        tool_name: "graph_write",
        result: { status: "possible_duplicate", next_move: "Keep this hint" },
        context: inactive_context
      )

      expect(payload[:next_move]).to eq("Keep this hint")
      expect(payload[:context]).to include(status: "none", next_move: include("set_context"))
    end

    it "does not add a redundant context banner to context tools" do
      payload, = described_class.call(
        tool_name: "get_context",
        result: { status: "no_context" },
        context: inactive_context
      )

      expect(payload).not_to have_key(:context)
      expect(payload[:next_move]).to include("set_context")
    end

    it "wraps non-Hash results for forward compatibility" do
      payload, = described_class.call(
        tool_name: "custom",
        result: [ 1, 2 ],
        context: active_context
      )

      expect(payload).to include(result: [ 1, 2 ], version: GraphMem::VERSION)
    end
  end
end
