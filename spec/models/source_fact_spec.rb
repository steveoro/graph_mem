# frozen_string_literal: true

require "rails_helper"

# Fact supersede F1: the source-fact tag, replaces: hints, outdated_by and who confirmed a fact.
RSpec.describe SourceFact, type: :model do
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: gadget.id) }
  let!(:loose) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") }

  def observe(entity, content, **attrs) = MemoryObservation.create!(memory_entity: entity, content: content, **attrs)
  def fact_on(entity, content = "The MCP server uses the official mcp gem.") = observe(entity, content, tags: [ "source-fact" ], source: "docs:README.md")

  it "is a source fact when active and tagged inside a project (the root included)" do
    expect(fact_on(widget)).to be_source_fact
    expect(fact_on(gadget)).to have_attributes(source_fact?: true, fact_project_id: gadget.id)
    expect(observe(widget, "SynthWidget renders tiles.")).not_to be_source_fact
  end

  it "refuses the tag on an entity outside any project" do
    fact = MemoryObservation.new(memory_entity: loose, content: "Alpha Service uses the mcp gem.", tags: [ "source-fact" ])

    expect(fact).not_to be_valid
    expect(fact.errors[:tags].join).to include("needs an entity inside a project")
  end

  it "reads the replaces: hints, normalized and capped" do
    fact = observe(widget, "Uses mcp.", tags: [ "source-fact", "replaces:fast-mcp", "replaces: Fast-MCP ", "replaces:x", *(1..6).map { |i| "replaces:term#{i}" } ])

    expect(fact.replaces_terms).to eq(%w[fast-mcp term1 term2 term3 term4])
  end

  describe "outdated_by" do
    let!(:fact) { fact_on(gadget) }
    let!(:old) { observe(widget, "The MCP server runs on fast-mcp.") }

    it "is set by mark_obsolete! and supersede! with a fact of the same project" do
      old.mark_obsolete!(reason: "Outdated by source fact ##{fact.id}", outdated_by: fact)
      expect(old.reload).to have_attributes(status: "obsolete", outdated_by_id: fact.id)
      expect(fact.outdated_observations).to contain_exactly(old)

      other = observe(widget, "The MCP server is built on fast-mcp.")
      replacement = other.supersede!({ content: "The MCP server is built on the mcp gem." }, reason: "Outdated by source fact ##{fact.id}", outdated_by: fact)
      expect(other.reload).to have_attributes(status: "superseded", superseded_by_id: replacement.id, outdated_by_id: fact.id)
      expect(replacement.outdated_by_id).to be_nil
    end

    it "is refused on an active row, on itself, for a non-fact and across projects" do
      old.outdated_by = fact
      expect(old).not_to be_valid

      expect { old.mark_obsolete!(outdated_by: observe(widget, "Not a fact.")) }.to raise_error(ActiveRecord::RecordInvalid, /same project/)
      legacy = MemoryEntity.create!(name: "Legacy Gadget", entity_type: "Project")
      expect { old.reload.mark_obsolete!(outdated_by: fact_on(legacy)) }.to raise_error(ActiveRecord::RecordInvalid, /same project/)

      old.reload.mark_obsolete!
      old.outdated_by_id = old.id
      expect(old).not_to be_valid
    end

    it "is cleared when the fact is deleted (ON DELETE SET NULL)" do
      old.mark_obsolete!(outdated_by: fact)
      fact.destroy!

      expect(old.reload.outdated_by_id).to be_nil
    end
  end

  it "counts as operator-confirmed only when an operator actor added the tag" do
    agent_fact = Current.set(actor: "api:synth-agent") { fact_on(widget) }
    expect(agent_fact.operator_confirmed_fact?).to be false

    plain = Current.set(actor: "api:synth-agent") { observe(widget, "SynthWidget is built with Ruby.") }
    Current.set(actor: "operator:synth@127.0.0.1") { plain.update_active!(tags: [ "source-fact" ]) }
    expect(plain.operator_confirmed_fact?).to be true

    Current.set(actor: "api:synth-agent") do
      plain.update_active!(tags: [])
      plain.update_active!(tags: [ "source-fact" ])
    end
    expect(plain.operator_confirmed_fact?).to be false
  end

  it "stops counting as operator-confirmed once an agent rewrites the text in place" do
    fact = Current.set(actor: "operator:synth@127.0.0.1") { fact_on(widget) }
    expect(fact.operator_confirmed_fact?).to be true

    Current.set(actor: "api:synth-agent") { fact.update_active!(content: "The MCP server uses a forked mcp gem.") }
    expect(fact.operator_confirmed_fact?).to be false

    Current.set(actor: "operator:synth@127.0.0.1") { fact.update_active!(content: "The MCP server uses the official mcp gem.") }
    expect(fact.operator_confirmed_fact?).to be true
  end

  it "ranks a source fact as a high-trust source" do
    plain = observe(widget, "SynthWidget uses Ruby.", confidence: 0.8)
    fact = observe(widget, "SynthWidget uses Ruby 3.4.", confidence: 0.8, tags: [ "source-fact" ])

    expect(fact.trust_score).to be > plain.trust_score
  end
end
