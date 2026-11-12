# frozen_string_literal: true

require "rails_helper"

# 1.77.0: FactKeywords stores each fact's keyword path and stamps it, one term index per project.
RSpec.describe FactKeywords do
  def project(name) = MemoryEntity.create!(name: name, entity_type: "Project")

  def entity(name, root, aliases: nil)
    MemoryEntity.create!(name: name, entity_type: "Class", project_id: root.id, aliases: aliases).tap do |created|
      MemoryRelation.create!(from_entity_id: created.id, to_entity_id: root.id, relation_type: "part_of")
    end
  end

  def fact(entity, content) = MemoryObservation.create!(memory_entity: entity, content: content)

  it "stores and stamps each fact's path, with each project's own entities" do
    gadget = project("Gadget Project")
    widget = entity("SynthWidget", gadget)
    entity("FrameBuffer", gadget)
    other = project("Other Project")
    alpha = entity("AlphaService", other)
    entity("FrameBuffer", other, aliases: "Frame Buffer")
    facts = [ fact(widget, "SynthWidget keeps a FrameBuffer."), fact(alpha, "AlphaService reads the frame buffer.") ]

    expect(described_class.compute!(facts, now: Time.zone.parse("2026-11-10 12:00"))).to eq(2)

    expect(facts.map { |observation| observation.reload.keywords })
      .to eq([ [ "Gadget Project", "SynthWidget", "FrameBuffer" ], [ "Other Project", "AlphaService", "FrameBuffer" ] ])
    expect(facts.map(&:keywords_at)).to all(eq(Time.zone.parse("2026-11-10 12:00")))
  end

  it "finds the project through part_of when the entity isn't stamped with it" do
    gadget = project("Gadget Project")
    entity("FrameBuffer", gadget)
    loose = MemoryEntity.create!(name: "SynthWidget", entity_type: "Class")
    MemoryRelation.create!(from_entity_id: loose.id, to_entity_id: gadget.id, relation_type: "part_of")
    loose.update_columns(project_id: nil)
    observation = fact(loose, "SynthWidget keeps a FrameBuffer.")

    described_class.compute!([ observation ])

    expect(observation.reload.keywords).to eq([ "Gadget Project", "SynthWidget", "FrameBuffer" ])
  end

  # 1.84.0: a fact that stopped naming an entity (the entity went away) needs LLM words now.
  it "re-pends the LLM words of a fact whose mentions went from some to none, and only those" do
    gadget = project("Gadget Project")
    widget = entity("SynthWidget", gadget)
    buffer = entity("FrameBuffer", gadget)
    lost = fact(widget, "SynthWidget keeps a FrameBuffer.")
    kept = fact(widget, "SynthWidget renders frames.")
    described_class.compute!([ lost, kept ])
    [ lost, kept ].each { |observation| observation.update_columns(llm_keywords: [], llm_keywords_at: Time.current) }

    buffer.destroy!
    described_class.compute!([ lost.reload, kept.reload ])

    expect(lost.reload).to have_attributes(keywords: [ "Gadget Project", "SynthWidget" ], llm_keywords_at: nil)
    expect(kept.reload.llm_keywords_at).to be_present
  end

  it "leaves the embedding and updated_at alone" do
    gadget = project("Gadget Project")
    observation = fact(entity("SynthWidget", gadget), "SynthWidget renders frames.")
    observation.update_columns(embedded_at: Time.current)
    before = observation.reload.updated_at

    described_class.compute!([ observation ])

    expect(observation.reload).to have_attributes(updated_at: before, embedded_at: be_present)
  end
end
