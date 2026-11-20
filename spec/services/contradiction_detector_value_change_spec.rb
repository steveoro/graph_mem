# frozen_string_literal: true

require "rails_helper"

# 1.92.0: value changes pair as contradictions without a negative word. Two facts of one entity,
# with the same source and perspective, that differ only in a value (FactKeywords::TokenDiff).
RSpec.describe ContradictionDetector, "value changes", :with_test_embeddings do
  let(:root) { MemoryEntity.create!(name: "Synth Project", entity_type: "Project") }
  let(:service_entity) { member("SynthService") }
  let(:near_vector) { Array.new(768, 0.1) }
  let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }

  before do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
    allow(service).to receive(:embed).and_return(near_vector)
  end

  after { AppSettings.where(var: "fact_keywords_enabled").delete_all }

  def member(name)
    MemoryEntity.create!(name: name, entity_type: "Service", project_id: root.id).tap do |entity|
      MemoryRelation.create!(from_entity: entity, to_entity: root, relation_type: "part_of")
    end
  end

  def fact(content, entity: service_entity, **attributes) = MemoryObservation.create!(memory_entity: entity, content: content, **attributes)

  def pairs = described_class.scan(service_entity.id, persist: false)

  it "pairs \"Port: 3000\" / \"Port: 3001\" on one entity, with exactly today's payload keys" do
    older = fact("Port: 3000")
    newer = fact("Port: 3001")
    found = pairs

    expect(found.fallback).to be_empty
    pair = found.pairs.sole
    expect([ pair.observation_id_1, pair.observation_id_2 ]).to match_array([ older.id, newer.id ])
    expect(described_class.review_item(pair).keys).to eq(
      %i[kind observation_id_1 entity_id_1 entity_name_1 content_1 observation_id_2 entity_id_2 entity_name_2 content_2
         distance confidence detected_at]
    )
    expect(described_class.value_change(older, newer)).to eq(class: :key_value, key: "port", from: "3000", to: "3001", count: 1)
  end

  it "pairs a key-value change with fact keywords off too" do
    AppSettings.fact_keywords_enabled = false
    fact("Port: 3000")
    fact("Port: 3001")

    expect(pairs.pairs.size).to eq(1)
  end

  it "doesn't pair different keys, a changed unit, a list, or two dated events" do
    fact("Port: 3000")
    fact("Timeout: 3000")
    fact("Wait: 5s")
    fact("Wait: 5m")
    fact("Ports: 3000, 3001")
    fact("Ports: 3000, 3002")
    fact("[2026-08-26] Workers: 2")
    fact("[2026-08-27] Workers: 3")

    expect(pairs.pairs).to be_empty
  end

  it "doesn't pair by value across two entities, sources or perspectives" do
    other = member("SynthWorker")
    MemoryRelation.create!(from_entity: other, to_entity: service_entity, relation_type: "relates_to")
    fact("Port: 3000")
    fact("Port: 3001", entity: other)
    fact("Retries: 3", source: "synth-scan")
    fact("Retries: 4", source: "synth-agent")
    fact("Workers: 2", perspective: "world")
    fact("Workers: 3", perspective: "experience")

    expect(pairs.pairs).to be_empty
  end

  it "keeps the keyword gate for a free-text value change: facts that mention no entity go to the fallback" do
    fact("It listens on port 3000")
    fact("It listens on port 3001")
    found = pairs

    expect(found.pairs).to be_empty
    expect(found.fallback.size).to eq(1)
  end

  it "pairs a free-text value change about the same subject" do
    member("SynthQueue")
    fact("It polls SynthQueue every 5s")
    fact("It polls SynthQueue every 9s")

    expect(pairs.pairs.size).to eq(1)
  end

  describe ".still_pairable?" do
    it "is true for a value change, and false once one side is retired or the key no longer matches" do
      older = fact("Port: 3000")
      newer = fact("Port: 3001")
      expect(described_class.still_pairable?(older, newer)).to be(true)

      other = fact("Timeout: 3000")
      expect(described_class.still_pairable?(older, other)).to be(false)

      older.mark_obsolete!(reason: "synth")
      expect(described_class.still_pairable?(older, newer)).to be(false)
    end
  end
end
