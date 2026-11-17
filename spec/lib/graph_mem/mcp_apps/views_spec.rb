# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpApps::Views do
  it "registers the graph view on all three profiles" do
    %i[default readonly maintenance].each { |profile| expect(described_class.uris_for(profile)).to eq([ described_class::GRAPH_URI ]) }
  end

  it "leaves a view out of a profile that doesn't advertise every tool it calls" do
    allow(GraphMem::McpToolRegistry).to receive(:tool_classes_for).and_call_original
    allow(GraphMem::McpToolRegistry).to receive(:tool_classes_for).with(:readonly)
      .and_return(GraphMem::McpToolRegistry.tool_classes_for(:readonly).reject { |klass| klass.tool_name == "get_context" })

    expect(described_class.uris_for(:readonly)).to eq([])
    expect(described_class.provider_for(:readonly).resources).to eq([])
  end

  it "lists the view through MCP::Apps.ui_resource and reads it as text/html;profile=mcp-app" do
    provider = described_class.provider_for(:default)

    expect(provider.resources.sole.to_h).to include(uri: described_class::GRAPH_URI, mimeType: MCP::Apps::RESOURCE_MIME_TYPE)
    expect(provider.read(described_class::GRAPH_URI).sole).to include(mimeType: MCP::Apps::RESOURCE_MIME_TYPE,
                                                                      _meta: { ui: { prefersBorder: true } })
  end
end
