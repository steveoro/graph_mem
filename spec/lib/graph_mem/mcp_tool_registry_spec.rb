# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpToolRegistry do
  describe ".register_with!" do
    let(:server) { instance_double(FastMcp::Server, register_tools: nil, register_resources: nil) }

    it "loads all *_tool.rb classes before registering" do
      expect(described_class).to receive(:load_all!).and_call_original
      expect(server).to receive(:register_tools) do |*tools|
        names = tools.map(&:tool_name)
        expect(names).to include("merge_entities", "dream_state_status")
      end

      described_class.register_with!(server)
    end
  end

  describe ".tool_classes" do
    it "includes all production MCP tools" do
      described_class.load_all!
      names = described_class.tool_classes.map(&:tool_name)

      expect(names).to include("merge_entities", "dream_state_status", "get_maintenance_reports")
      expect(names.size).to be >= 24
    end
  end
end
