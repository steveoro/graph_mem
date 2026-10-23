# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpInstructions do
  it "fits the 2,048-char limit and names the workflow on write profiles" do
    %i[default maintenance].each do |profile|
      text = described_class.for(profile)

      expect(text.length).to be <= 2048
      expect(text).to include("orient", "search", "persist")
    end
  end

  it "drops the persist sentence on the readonly profile" do
    text = described_class.for(:readonly)

    expect(text.length).to be <= 2048
    expect(text).to include("orient", "search")
    expect(text).not_to include("persist", "graph_write", "graph_edit")
  end

  it "names only tools advertised on each profile" do
    GraphMem::McpToolRegistry.load_all!
    tool_names = GraphMem::McpToolRegistry.tool_classes.map(&:tool_name)

    GraphMem::McpProfile::NAMES.each do |profile|
      advertised = GraphMem::McpToolRegistry.tool_classes_for(profile).select(&:mcp_advertised?).map(&:tool_name)
      named = described_class.for(profile).scan(/`([a-z_]+)`/).flatten & tool_names

      expect(named).to all(be_in(advertised)), "#{profile}: #{(named - advertised).inspect}"
    end
  end

  it "accepts profile strings and rejects unknown profiles" do
    expect(described_class.for("readonly")).to eq(described_class.for(:readonly))
    expect { described_class.for(:bogus) }.to raise_error(GraphMem::McpProfile::InvalidProfile)
  end
end
