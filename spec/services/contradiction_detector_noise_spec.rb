# frozen_string_literal: true

require "rails_helper"

# 1.85.0 (review queue noise, A5): of 22 production contradiction rows, 17 were false. Two dated
# events, facts of two Project roots, and a shared mention of another project no longer pair; the
# `:unknown` fallback (two close facts that mention no entity) no longer makes contradiction rows:
# ContradictionDetector.scan hands those pairs over as `fallback` (FactSupersede::ContradictionFallback).
RSpec.describe ContradictionDetector, "noise rules", :with_test_embeddings do
  let!(:main) { MemoryEntity.create!(name: "suite_web", entity_type: "Project") }
  # The production data smell: a Project root part_of another one.
  let!(:db) do
    MemoryEntity.create!(name: "suite_core", entity_type: "Project").tap do |root|
      MemoryRelation.create!(from_entity: root, to_entity: main, relation_type: "part_of")
    end
  end
  let!(:page) { member(main, "ScorePage") }
  let!(:player) { member(main, "Player") }
  let!(:db_user) { member(db, "CoreLib::User") }
  let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }

  before do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
    allow(service).to receive(:embed).and_return(Array.new(768, 0.1))
  end

  def member(root, name)
    MemoryEntity.create!(name: name, entity_type: "Component", project_id: root.id).tap do |entity|
      MemoryRelation.create!(from_entity: entity, to_entity: root, relation_type: "part_of")
    end
  end

  # A fact with its keyword path set by hand: the project root, the owner, then the mentions.
  def fact(entity, content, mentions: [])
    head = entity.project_root? ? [ entity.name ] : [ MemoryEntity.find(entity.project_id).name, entity.name ]
    MemoryObservation.create!(memory_entity: entity, content: content).tap do |observation|
      observation.update_columns(keywords: head + mentions, keywords_at: Time.current)
    end
  end

  def ids(results) = results.map { |result| [ result.observation_id_1, result.observation_id_2 ].sort }

  it "still pairs two facts about the same subject of their own project" do
    first = fact(page, "It lists Player scores.", mentions: %w[Player])
    second = fact(page, "It no longer lists Player scores.", mentions: %w[Player])

    expect(ids(described_class.detect(page.id, persist: false))).to eq([ [ first.id, second.id ].sort ])
    expect(described_class.still_pairable?(first, second)).to be(true)
  end

  it "skips two dated events: two events don't contradict" do
    first = fact(page, "[2026-08-26] It lists Player scores.", mentions: %w[Player])
    second = fact(page, "[2026-09-02] It no longer lists Player scores.", mentions: %w[Player])

    scan = described_class.scan(page.id, persist: false)

    expect(scan.pairs).to be_empty
    expect(scan.fallback).to be_empty
    expect(described_class.still_pairable?(first, second)).to be(false)
  end

  it "skips two dated release notes held by two Project roots (the operator's example)" do
    fact(db, "[2026-08-26] suite_core v0.10.40 phase 1: added CoreLib::ScoreComponent.")
    fact(main, "[2026-08-26] suite_web v0.10.40 phase 3: removed the local ScoreComponent.")

    scan = described_class.scan(main.id, persist: false)

    expect([ scan.pairs, scan.fallback ]).to all(be_empty)
  end

  it "doesn't pair or hand over two undated facts of two Project roots" do
    first = fact(db, "Scores are computed per season.")
    second = fact(main, "Scores are not computed per season.")

    scan = described_class.scan(main.id, persist: false)

    expect([ scan.pairs, scan.fallback ]).to all(be_empty)
    expect(described_class.still_pairable?(first, second)).to be(false)
  end

  it "hands one owner's two facts about another project's root to the judge instead of pairing them (Graphy, #172)" do
    first = fact(page, "It reads scores from suite_core.", mentions: %w[suite_core])
    second = fact(page, "It does not read scores from suite_core.", mentions: %w[suite_core])

    scan = described_class.scan(page.id, persist: false)

    expect(scan.pairs).to be_empty
    expect(ids(scan.fallback)).to eq([ [ first.id, second.id ].sort ])
    expect(described_class.still_pairable?(first, second)).to be(false)
    expect(described_class.foreign_only?(first, second)).to be(true)
  end

  it "hands over a shared mention of an entity owned by another project the same way" do
    first = fact(page, "It shows the CoreLib::User name.", mentions: %w[CoreLib::User])
    second = fact(page, "It never shows the CoreLib::User name.", mentions: %w[CoreLib::User])

    scan = described_class.scan(page.id, persist: false)

    expect(scan.pairs).to be_empty
    expect(ids(scan.fallback)).to eq([ [ first.id, second.id ].sort ])
  end

  it "still pairs on an own-project mention next to another project's one" do
    first = fact(page, "It reads Player scores from suite_core.", mentions: %w[Player suite_core])
    second = fact(page, "It does not read Player scores from suite_core.", mentions: %w[Player suite_core])

    pair = described_class.detect(page.id, persist: false).sole

    expect([ pair.observation_id_1, pair.observation_id_2 ].sort).to eq([ first.id, second.id ].sort)
    expect(pair.shared_keywords).to eq(%w[Player])
    expect(described_class.foreign_only?(first, second)).to be(false)
  end

  it "hands the `:unknown` fallback over instead of making a contradiction pair (Steve, decision 2)" do
    first = fact(page, "Deploy by running the rake task by hand.")
    second = fact(page, "Do not deploy by running the rake task by hand.")

    scan = described_class.scan(page.id, persist: true)

    expect(scan.pairs).to be_empty
    expect(ids(scan.fallback)).to eq([ [ first.id, second.id ].sort ])
    expect(scan.fallback.sole.distance).to be <= described_class::STRICT_MAX_DISTANCE
    expect(described_class.detect(page.id, persist: false)).to be_empty
    expect(MaintenanceReport.where(report_type: "contradictions")).to be_empty
    expect(described_class.still_pairable?(first, second)).to be(false)
  end

  describe ".still_pairable?" do
    it "is false once either side is inactive, or for the same polarity" do
      first = fact(page, "It lists Player scores.", mentions: %w[Player])
      second = fact(page, "It no longer lists Player scores.", mentions: %w[Player])
      same = fact(page, "It sorts Player scores.", mentions: %w[Player])

      expect(described_class.still_pairable?(first, same)).to be(false)
      second.mark_obsolete!(reason: "synthetic")
      expect(described_class.still_pairable?(first, second)).to be(false)
    end

    it "computes pending keyword paths first" do
      first = MemoryObservation.create!(memory_entity: page, content: "It lists Player scores.")
      second = MemoryObservation.create!(memory_entity: page, content: "It no longer lists Player scores.")

      expect(described_class.still_pairable?(first, second)).to be(true)
      expect(first.reload.keywords_at).to be_present
    end
  end
end
