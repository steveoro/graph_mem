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

  describe ".select_prompts" do
    it "filters prompts by their declared profiles" do
      expect(described_class.select_prompts([ OrientPrompt, RecallPrompt, PersistPrompt ], :readonly))
        .to contain_exactly(OrientPrompt, RecallPrompt)
      expect(described_class.select_prompts([ OrientPrompt, RecallPrompt, PersistPrompt ], :maintenance))
        .to contain_exactly(OrientPrompt, RecallPrompt, PersistPrompt)
    end
  end

  describe "prompt profile contract" do
    before { GraphMem::McpToolRegistry.load_all! }

    let(:classes) { GraphMem::McpToolRegistry.prompt_classes }

    it "has at least one registered prompt" do
      expect(classes).not_to be_empty
    end

    # Convention: every concrete prompt must call mcp_metadata(profiles:)
    # explicitly. Inheritance from ApplicationPrompt is a safety net for
    # ad-hoc subclasses, not a substitute for a declaration.
    it "every concrete prompt explicitly declares its profiles" do
      classes.each do |klass|
        expect(klass.instance_variable_defined?(:@mcp_profiles)).to be(true),
          "#{klass.name} does not explicitly declare mcp_metadata(profiles:)"
        expect(klass.mcp_profiles).to be_present,
          "#{klass.name} has empty mcp_profiles"
      end
    end

    it "readonly shows orient and recall; default and maintenance show all three" do
      expect(described_class.select_prompts(classes, :readonly).map(&:prompt_name))
        .to contain_exactly("orient", "recall")
      %i[default maintenance].each do |profile|
        expect(described_class.select_prompts(classes, profile).map(&:prompt_name))
          .to contain_exactly("orient", "recall", "persist"),
          "expected all three prompts for #{profile}"
      end
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
