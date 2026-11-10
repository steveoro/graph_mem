# frozen_string_literal: true

require "rails_helper"

# 1.77.0: a fact's keyword path on the model: pending until computed, pending again when its text
# changes, never embedded.
RSpec.describe MemoryObservation, "keywords" do
  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Class", project_id: root.id) }
  let(:fact) { described_class.create!(memory_entity: widget, content: "SynthWidget keeps a FrameBuffer.") }

  def computed!(observation, path)
    observation.update_columns(keywords: path, keywords_at: Time.current)
    observation.reload
  end

  it "starts pending with an empty path, and accepts only an array of strings" do
    expect(fact).to have_attributes(keywords: [], keywords_at: nil)
    expect(described_class.keywords_pending).to include(fact)

    fact.keywords = [ "Gadget Project", 3 ]
    expect(fact).not_to be_valid
    expect(fact.errors[:keywords]).to be_present
  end

  it "is pending again when its text changes, not when only its confidence does" do
    computed!(fact, [ "Gadget Project", "SynthWidget", "FrameBuffer" ])

    fact.update!(confidence: 0.5)
    expect(fact.reload.keywords_at).to be_present

    fact.update!(content: "SynthWidget renders frames.")
    expect(fact.reload.keywords_at).to be_nil
  end

  it "is pending again when it moves to another entity, as an entity merge moves facts" do
    other = MemoryEntity.create!(name: "AlphaService", entity_type: "Service", project_id: root.id)
    computed!(fact, [ "Gadget Project", "SynthWidget", "FrameBuffer" ])

    fact.update!(memory_entity: other)

    expect(fact.reload.keywords_at).to be_nil
  end

  it "starts a superseding fact pending" do
    computed!(fact, [ "Gadget Project", "SynthWidget", "FrameBuffer" ])

    replacement = fact.supersede!({ content: "SynthWidget keeps two FrameBuffers." }, reason: "spec")

    expect(replacement).to have_attributes(keywords: [], keywords_at: nil)
  end

  it "lists the mentions after its own entity, and none while pending" do
    expect(fact.keyword_mentions).to eq([])

    computed!(fact, [ "Gadget Project", "SynthWidget", "FrameBuffer", "AlphaService" ])
    expect(fact.keyword_mentions).to eq(%w[FrameBuffer AlphaService])
  end

  it "keeps keywords out of the embedded fields and of the REST output" do
    computed!(fact, [ "Gadget Project", "SynthWidget" ])

    expect(described_class::EMBEDDING_FIELDS).not_to include("keywords")
    expect(fact.as_json.keys).not_to include("keywords", "keywords_at")
  end
end
