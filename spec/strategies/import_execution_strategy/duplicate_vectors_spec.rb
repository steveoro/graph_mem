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

  it "embeds every candidate text before the lock, with no cap" do
    stored = Array.new(4) { |i| "SynthWidget fact #{i}." }
    stored.each { |content| MemoryObservation.create!(memory_entity: widget, content: content) }
    calls.clear

    report = import(*stored.map { |content| "Restated: #{content}" })

    expect(report.success).to be(true)
    expect(widget_facts).to contain_exactly("SynthWidget renders tiles.", *stored)
    expect(calls.map { |call| call[:text] }).to eq(stored.map { |content| "Restated: #{content}" })
    expect(calls).to all(include(held: false, lock_free: true))
  end

  it "fails as before when the embedding service is down: before the lock, writing nothing" do
    attempts = 0
    allow(EmbeddingService.instance).to receive(:embed_with_retries) do
      attempts += 1
      raise EmbeddingService::EmbeddingError, "HTTP 503: synthetic outage"
    end
    lock_name = ProjectMembership.lock_name
    lock_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      lock_sql << payload[:sql] if payload[:sql].to_s.include?(lock_name)
    end

    report = nil
    expect { report = import("Restated: SynthWidget renders tiles.", "SynthWidget caches frames.") }
      .not_to change { [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count ] }

    expect(report.success).to be(false)
    expect(report.errors).to eq([ "Semantic observation de-duplication unavailable: Embedding service is unavailable: HTTP 503: synthetic outage" ])
    expect(attempts).to eq(1) # the first failure stops the import
    expect(lock_sql).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "matches exactly, with one warning, a text the pre-read missed because a fact changed before the lock" do
    # The pre-read sees an unembedded fact (no semantic check, so nothing to embed); the backfill
    # stamps it before the import takes the lock.
    facts = MemoryObservation.where(memory_entity: widget)
    facts.update_all(embedded_at: nil)
    allow_any_instance_of(ImportObservationDuplicateDetector).to receive(:precompute!).and_wrap_original do |original, *args|
      original.call(*args).tap { facts.update_all(embedded_at: Time.current) }
    end

    report = import("Restated: SynthWidget renders tiles.", "Restated: SynthWidget renders tiles, again.")

    expect(report.success).to be(true)
    expect(calls).to be_empty
    expect(widget_facts).to include("Restated: SynthWidget renders tiles.")
    # The fact the fallback added is unembedded, so the detector compares the next text exactly anyway.
    expect(dedup_warnings).to eq([ "ImportExecutionStrategy: Semantic observation de-duplication matched 1 fact(s) exactly only: " \
                                   "1 whose text was not embedded before the import" ])
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
