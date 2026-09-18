# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpProfile do
  describe ".from_path" do
    it "maps streamable and legacy paths to profiles" do
      expect(described_class.from_path("/mcp")).to eq(:default)
      expect(described_class.from_path("/mcp/")).to eq(:default)
      expect(described_class.from_path("/mcp/readonly")).to eq(:readonly)
      expect(described_class.from_path("/mcp/readonly/")).to eq(:readonly)
      expect(described_class.from_path("/mcp/maintenance")).to eq(:maintenance)
      expect(described_class.from_path("/mcp/maintenance/")).to eq(:maintenance)
      expect(described_class.from_path("/mcp/sse")).to eq(:default)
      expect(described_class.from_path("/mcp/messages")).to eq(:default)
    end

    it "rejects unknown paths" do
      expect {
        described_class.from_path("/mcp/unknown")
      }.to raise_error(GraphMem::McpProfile::InvalidProfile, /Unknown MCP profile path/)
    end
  end

  describe ".from_env" do
    it "defaults to the default profile" do
      expect(described_class.from_env({})).to eq(:default)
    end

    it "normalizes known profiles and rejects unknown values" do
      expect(described_class.from_env("GRAPH_MEM_MCP_PROFILE" => " READONLY ")).to eq(:readonly)
      expect {
        described_class.from_env("GRAPH_MEM_MCP_PROFILE" => "unsafe")
      }.to raise_error(GraphMem::McpProfile::InvalidProfile, /expected one of/)
    end
  end

  describe ".select_tools" do
    it "uses class metadata instead of tool-name lists" do
      default_tool = Class.new do
        def self.mcp_profiles = %i[default maintenance]
      end
      readonly_tool = Class.new do
        def self.mcp_profiles = %i[default readonly maintenance]
      end
      maintenance_tool = Class.new do
        def self.mcp_profiles = %i[maintenance]
      end

      tools = [ default_tool, readonly_tool, maintenance_tool ]

      expect(described_class.select_tools(tools, :default)).to contain_exactly(default_tool, readonly_tool)
      expect(described_class.select_tools(tools, :readonly)).to contain_exactly(readonly_tool)
      expect(described_class.select_tools(tools, :maintenance)).to contain_exactly(*tools)
    end
  end
end
