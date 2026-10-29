# frozen_string_literal: true

require "rails_helper"

# Fact supersede F2: candidates come from the fact's project only; other projects are never searched.
RSpec.describe FactSupersede::Candidates do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:legacy) { fs_project!("Legacy Gadget") }
  let!(:legacy_widget) { fs_member!(legacy, "Legacy SynthWidget") }
  let(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }

  def found(**options) = described_class.call(fact, **options).candidates.map { |candidate| candidate.observation.content }

  it "finds the project's observations by the fact's replaces: term, never another project's" do
    fs_observe!(widget, "The MCP server runs on fast-mcp.")
    fs_observe!(legacy_widget, "The MCP server runs on fast-mcp.")
    fs_observe!(legacy, "Legacy Gadget runs on fast-mcp.")
    fs_observe!(widget, "SynthWidget renders synthetic tiles.")

    result = described_class.call(fact)

    expect(result.candidates.map(&:observation)).to contain_exactly(have_attributes(memory_entity_id: widget.id))
    expect(result.candidates.sole).to have_attributes(term: "fast-mcp", score: 0.6, scoped: true, distance: nil)
    expect(result).to have_attributes(vector: false, project_id: gadget.id, terms: [ "fast-mcp" ])
  end

  it "lists related entities without a project as unscoped, and never another project's root" do
    loose = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
    MemoryRelation.create!(from_entity: gadget, to_entity: loose, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: gadget, to_entity: legacy, relation_type: "relates_to")
    unrelated = MemoryEntity.create!(name: "Unrelated Service", entity_type: "Service")
    fs_observe!(loose, "Alpha Service talks to fast-mcp.")
    fs_observe!(legacy, "Legacy Gadget stays on fast-mcp.")
    fs_observe!(unrelated, "Unrelated Service uses fast-mcp.")

    expect(described_class.call(fact).candidates).to contain_exactly(have_attributes(scoped: false, observation: have_attributes(memory_entity_id: loose.id)))
  end

  it "skips the fact, other facts and inactive rows unless asked" do
    fs_fact!(widget, "SynthWidget replaces fast-mcp with the mcp gem.")
    fs_observe!(widget, "The old fast-mcp transport.").mark_obsolete!

    expect(found).to be_empty
    expect(found(include_inactive: true)).to eq([ "The old fast-mcp transport." ])
  end

  it "escapes % and _ in every term, and caps terms at five" do
    fs_observe!(widget, "SynthWidget is 100% done.")
    fs_observe!(widget, "SynthWidget has 1000 rows.")
    fs_observe!(widget, "SynthWidget uses a_b.")
    fs_observe!(widget, "SynthWidget uses axb.")

    expect(found(query: "100%")).to contain_exactly("SynthWidget is 100% done.")
    expect(found(terms: [ "a_b" ])).to contain_exactly("SynthWidget uses a_b.")
    expect(described_class.call(fact, query: "q1", terms: %w[q2 q3 q4 q5 q6]).terms.size).to eq(5)
  end

  it "boosts a polarity flip and returns nothing for a non-fact" do
    fs_observe!(widget, "The MCP server does not use the mcp gem; it runs on fast-mcp.")

    expect(described_class.call(fact).candidates.sole).to have_attributes(score: 0.7, polarity_flip: true)
    plain = fs_observe!(widget, "SynthWidget mentions fast-mcp.")
    expect(described_class.call(plain).candidates).to be_empty
  end

  describe "with vectors", :with_test_embeddings do
    let(:axis) { ->(index) { Array.new(768, 0.0).tap { |vector| vector[index] = 1.0 } } }

    before do
      service = EmbeddingService.instance
      allow(service).to receive(:embed) do |text|
        if text.include?("mcp") then axis.call(0)
        elsif text.include?("tiles") then axis.call(1)
        end
      end
    end

    it "adds the vector neighbours within the max distance, in the project only" do
      near = fs_observe!(widget, "The MCP server is built on a different mcp library.")
      fs_observe!(widget, "SynthWidget renders synthetic tiles.")
      fs_observe!(legacy_widget, "The MCP server is built on a different mcp library.")

      result = described_class.call(fs_fact!(gadget))

      expect(result.vector).to be true
      expect(result.candidates.sole).to have_attributes(observation: near, distance: be_within(0.001).of(0.0), score: 0.99)
    end
  end
end
