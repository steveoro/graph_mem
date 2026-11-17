# frozen_string_literal: true

require "rails_helper"

# MCP Apps step A1 (1.87.0): resources come from an ordered list of providers; the templated
# ApplicationResource classes are one provider, unchanged.
RSpec.describe GraphMem::OfficialMcp::ResourceCatalog do
  let(:templates) { GraphMem::OfficialMcp::TemplateResourceProvider.new(GraphMem::McpToolRegistry.resource_classes) }

  before { GraphMem::McpToolRegistry.load_all! }

  it "lists the templates and no static resources from the template provider" do
    expect(described_class.resources([ templates ])).to eq([])
    expect(described_class.templates([ templates ]).map(&:uri_template))
      .to match_array(GraphMem::McpToolRegistry.resource_classes.select(&:templated?).map(&:uri))
  end

  it "reads a templated URI as before" do
    entity = MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project")

    contents = described_class.read([ templates ], "memory_graph?entity_id=#{entity.id}")

    expect(contents.sole).to include(uri: "memory_graph?entity_id=#{entity.id}", mimeType: "application/json")
    expect(JSON.parse(contents.sole[:text]).to_s).to include("synth-alpha-project")
  end

  it "asks the providers in order and raises not-found when none matches" do
    first = instance_double(GraphMem::OfficialMcp::TemplateResourceProvider, match?: true, read: [ { uri: "synth://x", text: "first" } ])
    second = instance_double(GraphMem::OfficialMcp::TemplateResourceProvider, match?: true, read: [ { uri: "synth://x", text: "second" } ])

    expect(described_class.read([ first, second ], "synth://x").sole[:text]).to eq("first")
    expect { described_class.read([ templates ], "synth://unknown") }.to raise_error(MCP::Server::ResourceNotFoundError)
  end
end
