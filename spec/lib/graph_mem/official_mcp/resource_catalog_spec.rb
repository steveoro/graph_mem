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

  def static(text, uri: "synth://note")
    GraphMem::OfficialMcp::StaticResourceProvider.new([
      { uri: uri, name: "synth_note", title: "Synth note", description: "A synthetic note", mime_type: "text/plain",
        meta: { synth: true }, body: -> { text } }
    ])
  end

  it "asks the providers in order and raises not-found when none matches" do
    providers = [ templates, static("first"), static("second") ]

    expect(described_class.read(providers, "synth://note").sole[:text]).to eq("first")
    expect(described_class.resources(providers).map(&:uri)).to eq(%w[synth://note synth://note])
    expect { described_class.read(providers, "synth://unknown") }.to raise_error(MCP::Server::ResourceNotFoundError)
  end

  describe GraphMem::OfficialMcp::StaticResourceProvider do
    it "lists its entries and reads one by exact URI, with _meta on the content item, building the body once" do
      calls = 0
      provider = described_class.new([
        { uri: "synth://note", name: "synth_note", title: "Synth note", description: "A synthetic note", mime_type: "text/plain",
          meta: { synth: true }, body: -> { calls += 1; "hello" } }
      ])

      expect(provider.resources.sole.to_h).to eq(uri: "synth://note", name: "synth_note", title: "Synth note",
                                                 description: "A synthetic note", mimeType: "text/plain")
      expect(provider.templates).to eq([])
      expect(provider.match?("synth://note")).to be(true)
      expect(provider.match?("synth://note?x=1")).to be(false)
      2.times { expect(provider.read("synth://note")).to eq([ { uri: "synth://note", mimeType: "text/plain", _meta: { synth: true }, text: "hello" } ]) }
      expect(calls).to eq(1)
    end

    it "refuses a missing or unknown key, a body that isn't callable and a duplicate URI" do
      entry = { uri: "synth://a", name: "a", title: nil, description: nil, mime_type: "text/plain", meta: nil, body: -> { "" } }

      expect { described_class.new([ entry.except(:meta) ]) }.to raise_error(ArgumentError, /missing \[:meta\]/)
      expect { described_class.new([ entry.merge(csp: {}) ]) }.to raise_error(ArgumentError, /unknown \[:csp\]/)
      expect { described_class.new([ entry.merge(body: "text") ]) }.to raise_error(ArgumentError, /#call/)
      expect { described_class.new([ entry, entry ]) }.to raise_error(ArgumentError, /duplicate/)
    end
  end
end
