# frozen_string_literal: true

require "rails_helper"

# 1.78.0: contradiction pairs need facts about the same thing, by their keyword paths. Before, two
# close facts on one entity with one negative word were paired whatever they were about.
RSpec.describe ContradictionDetector, "keyword paths", :with_test_embeddings do
  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:grant) { member("AdminGrant") }
  let(:near_vector) { Array.new(768, 0.1) }
  # Cosine distance about 0.20 from near_vector.
  let(:apart_vector) { Array.new(492, 0.1) + Array.new(276, 0.0) }
  let(:vectors) { {} }
  let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }

  before do
    member("User")
    member("Team")
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
    allow(service).to receive(:embed) { |text| vectors.find { |content, _| text.start_with?(content) }&.last || near_vector }
  end

  after { AppSettings.where(var: "fact_keywords_enabled").delete_all }

  def member(name)
    MemoryEntity.create!(name: name, entity_type: "Model", project_id: root.id).tap do |entity|
      MemoryRelation.create!(from_entity: entity, to_entity: root, relation_type: "part_of")
    end
  end

  def fact(content) = MemoryObservation.create!(memory_entity: grant, content: content)

  it "doesn't pair two close facts on one entity that are about different things" do
    fact("It belongs to a User.")
    fact("It is not linked to a Team.")

    expect(described_class.detect(grant.id, persist: false)).to be_empty
  end

  it "pairs facts about the same thing, with what they share, and computes pending paths first" do
    first = fact("It belongs to a User.")
    second = fact("It does not belong to a User.")
    expect(first.reload.keywords_at).to be_nil

    pair = described_class.detect(grant.id, persist: false).sole

    expect(pair).to have_attributes(shared_keywords: %w[User], strong: true)
    # In memory only: the row payload reaches MCP verbatim.
    expect(described_class.review_item(pair).keys).not_to include(:shared_keywords, :strong)
    expect([ first, second ].map { |observation| observation.reload.keywords_at }).to all(be_present)
  end

  # 1.85.0 (Steve, decision 2): never a contradiction pair; very close ones go to the fallback.
  it "hands two facts that mention no entity to the fallback only when they are very close" do
    fact("Not meant to be instantiated directly.")
    vectors["It can be instantiated."] = apart_vector
    fact("It can be instantiated.")
    expect(described_class.scan(grant.id, persist: false)).to have_attributes(pairs: [], fallback: [])

    fact("It can be instantiated directly.")
    scan = described_class.scan(grant.id, persist: false)
    expect(scan.pairs).to be_empty
    expect(scan.fallback.size).to eq(1)
  end

  it "relates a fact with one on a related entity, but not two facts on siblings the graph doesn't join (1.80.0)" do
    deployment = member("Deployment")
    billing = member("Billing")
    MemoryRelation.create!(from_entity: deployment, to_entity: grant, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: billing, to_entity: grant, relation_type: "relates_to")
    deploys = MemoryObservation.create!(memory_entity: deployment, content: "It deploys with Kamal.")
    bills = MemoryObservation.create!(memory_entity: billing, content: "It does not bill monthly.")

    # Deployment and Billing are both AdminGrant's neighbours, but nothing joins them: siblings.
    expect(described_class.detect(grant.id, persist: false)).to be_empty

    own = fact("It is not deployed with Kamal.")
    scan = described_class.scan(grant.id, persist: false)
    pairs = scan.fallback.map { |found| [ found.observation_id_1, found.observation_id_2 ].sort }

    # AdminGrant and Deployment are joined by a relation. (Its fact and Billing's are both negative.)
    # Neither mentions an entity: the `:unknown` fallback, not a contradiction pair (1.85.0).
    expect(scan.pairs).to be_empty
    expect(pairs).to eq([ [ own.id, deploys.id ].sort ])
    expect(pairs.flatten).not_to include(bills.id)
  end

  it "doesn't pair related facts that aren't about the same subject (1.82.0)" do
    member("Season")
    fact("It belongs to a User and a Team.")
    fact("It is not linked to a Team for a Season.")

    expect(described_class.detect(grant.id, persist: false)).to be_empty
  end

  it "pairs as before with fact keywords off" do
    AppSettings.fact_keywords_enabled = false
    fact("It belongs to a User.")
    fact("It is not linked to a Team.")

    pair = described_class.detect(grant.id, persist: false).sole
    expect(pair.shared_keywords).to be_nil
    expect(described_class.review_item(pair)).not_to have_key(:shared_keywords)
  end
end
