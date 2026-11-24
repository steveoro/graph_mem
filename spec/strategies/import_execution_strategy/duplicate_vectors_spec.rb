# frozen_string_literal: true

require "rails_helper"

# An import's semantic observation de-duplication embeds its texts before the membership lock
# (ImportExecutionStrategy::DuplicateVectors, ImportObservationDuplicateDetector#precompute!) and
# makes no embedding call under it.
RSpec.describe ImportExecutionStrategy::DuplicateVectors, :with_test_embeddings do
  # deterministic_embedding ignores a "Restated: " prefix, so a restated fact is a paraphrase at
  # distance 0 and any other text is at distance 1.
  let!(:calls) { record_embedding_calls! }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let(:decisions) { [ { node_path: "0", action: "merge", target_id: widget.id } ] }

  let(:warnings) { [] }

  before do
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders tiles.")
    calls.clear
    allow(Rails.logger).to receive(:warn).and_wrap_original do |original, *args, &block|
      warnings << args.first
      original.call(*args, &block)
    end
  end

  def import(*contents)
    payload = { "root_nodes" => [ { "name" => "SynthWidget", "entity_type" => "Component",
                                    "observations" => contents.map { |content| { "content" => content } } } ] }
    ImportExecutionStrategy.new.execute(payload, decisions)
  end

  def widget_facts = widget.memory_observations.active.pluck(:content)

  def dedup_warnings = warnings.grep(/Semantic observation de-duplication/)

  it "drops a paraphrase with its vector computed before the lock, and makes no embedding call under it" do
    report = import("Restated: SynthWidget renders tiles.", "SynthWidget caches frames.", "SynthWidget renders tiles.")

    expect(report.success).to be(true)
    expect(widget_facts).to contain_exactly("SynthWidget renders tiles.", "SynthWidget caches frames.")
    # The stored exact text is skipped by the pre-read; the import's own exact check drops it.
    expect(calls.map { |call| call[:text] }).to eq([ "Restated: SynthWidget renders tiles.", "SynthWidget caches frames." ])
    expect(calls).to all(include(held: false, lock_free: true))
    expect(dedup_warnings).to be_empty
  end

  it "completes with exact matching and one warning when the embedding service is down" do
    attempts = 0
    allow(EmbeddingService.instance).to receive(:embed_with_retries) do
      attempts += 1
      raise EmbeddingService::EmbeddingError, "HTTP 503: synthetic outage"
    end

    report = import("Restated: SynthWidget renders tiles.", "SynthWidget caches frames.", "SynthWidget renders tiles.")

    expect(report.success).to be(true)
    expect(widget_facts).to contain_exactly("SynthWidget renders tiles.", "Restated: SynthWidget renders tiles.", "SynthWidget caches frames.")
    expect(attempts).to eq(1) # the first failure ends the precompute
    # The fact the fallback added is unembedded, so the detector compares the next text exactly anyway.
    expect(dedup_warnings).to eq([ "ImportExecutionStrategy: Semantic observation de-duplication matched 1 fact(s) exactly only: " \
                                   "1 because the embedding service failed before the import (HTTP 503: synthetic outage)" ])
  end

  it "embeds at most MAX_PRECOMPUTED_TEXTS texts and matches the rest exactly, saying so" do
    stub_const("ImportObservationDuplicateDetector::MAX_PRECOMPUTED_TEXTS", 1)

    report = import("Restated: SynthWidget renders tiles.", "Restated: SynthWidget renders tiles, again.")

    expect(report.success).to be(true)
    expect(widget_facts).to contain_exactly("SynthWidget renders tiles.", "Restated: SynthWidget renders tiles, again.")
    expect(calls.map { |call| call[:text] }).to eq([ "Restated: SynthWidget renders tiles." ])
    expect(dedup_warnings).to eq([ "ImportExecutionStrategy: Semantic observation de-duplication matched 1 fact(s) exactly only: " \
                                   "1 beyond the first 1 of 2 distinct texts embedded before the import" ])
  end

  it "embeds nothing for a node that lands on a new entity, or under an excluded node" do
    payload = { "root_nodes" => [
      { "name" => "SynthGear", "entity_type" => "Component", "observations" => [ { "content" => "SynthGear turns." } ] },
      { "name" => "SynthWidget", "entity_type" => "Component", "observations" => [ { "content" => "SynthWidget caches frames." } ] }
    ] }

    report = ImportExecutionStrategy.new.execute(payload, [ { node_path: "0", action: "create" }, { node_path: "1", action: "exclude" } ])

    expect(report.success).to be(true)
    expect(calls).to be_empty
    expect(widget_facts).to eq([ "SynthWidget renders tiles." ])
  end
end
