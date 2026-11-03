# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR3, step L: people (Person and User entities) are masked as PER wherever they are in
# the graph, not only as members of a project in scope. Synthetic names only.
RSpec.describe Llm::Anonymizer::Dictionary do
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: gadget.id) }
  let!(:member) { MemoryEntity.create!(name: "Zq7 Ada", entity_type: "Person", project_id: gadget.id) }
  let!(:global_person) { MemoryEntity.create!(name: "Zq7 Bea", entity_type: "Person", aliases: "Zq7bea") }
  let!(:other_user) { MemoryEntity.create!(name: "Zq7 Cid", entity_type: "User", project_id: alpha.id) }
  let!(:global_component) { MemoryEntity.create!(name: "Zq7 Gizmo", entity_type: "Component") }
  let(:session) { Llm::Anonymizer::Session.new(Llm::Scope.for_entities([ widget ])) }
  let(:text) { "Zq7 Ada, Zq7 Bea (zq7bea), Zq7 Cid and Zq7 Gizmo review SynthWidget." }

  it "masks a member, a global Person and another project's User as PER, and leaves a global Component" do
    masked = session.mask(Llm::Prompt.new.data(text))

    expect(masked.text).to match(/\A⟦PER_\h{4}⟧, ⟦PER_\h{4}⟧ \(⟦PER_\h{4}⟧\), ⟦PER_\h{4}⟧ and Zq7 Gizmo review ⟦ENT_\h{4}⟧\.\z/)
    expect(masked.counts).to eq("PER" => 4, "ENT" => 1)
    expect(masked.text.gsub(/⟦[^⟧]*⟧/, "")).not_to include("Ada", "Bea", "bea", "Cid") # token suffixes are hex and may spell "bea"
  end

  it "restores the answer exactly" do
    masked = session.mask(Llm::Prompt.new.data(text))

    expect(session.unmask(masked.text).text).to eq(text)
  end

  it "keeps the type a term got first: a person who is also a scope member stays as before" do
    MemoryEntity.create!(name: "SynthWidget Owner", entity_type: "Component", project_id: gadget.id)
    MemoryEntity.create!(name: "SynthWidget Owner", entity_type: "Person")

    expect(session.mask(Llm::Prompt.new.data("SynthWidget Owner")).text).to match(/\A⟦ENT_\h{4}⟧\z/)
  end

  it "counts the people toward the cap, and refuses when they alone pass it" do
    allowed = described_class.build(Llm::Scope.for_entities([ widget ])).size
    stub_const("Llm::Anonymizer::Dictionary::MAX_TERMS", allowed)
    expect { described_class.build(Llm::Scope.for_entities([ widget ])) }.not_to raise_error

    MemoryEntity.create!(name: "Zq7 Dot", entity_type: "Person")

    expect { described_class.build(Llm::Scope.for_entities([ widget ])) }.to raise_error(Llm::Anonymizer::Refused) do |error|
      expect(error.kind).to eq(:dictionary_cap)
    end
  end
end
