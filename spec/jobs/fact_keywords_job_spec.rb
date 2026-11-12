# frozen_string_literal: true

require "rails_helper"

# 1.77.0: FactKeywordsJob computes pending active facts in batches; writes request one run.
RSpec.describe FactKeywordsJob do
  include ActiveJob::TestHelper

  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:widget) do
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Class", project_id: root.id).tap do |entity|
      MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: root.id, relation_type: "part_of")
    end
  end

  before { described_class.reset_request! }
  after { AppSettings.where(var: "fact_keywords_enabled").delete_all }

  it "computes every pending active fact in batches, leaves inactive ones and is idempotent" do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    facts = Array.new(5) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }
    retired = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget retired fact.")
    retired.mark_obsolete!(reason: "spec")

    expect(described_class.perform_now).to eq(5)
    expect(facts.map { |fact| fact.reload.keywords }).to all(eq([ "Gadget Project", "SynthWidget" ]))
    expect(retired.reload.keywords_at).to be_nil
    expect(described_class.perform_now).to eq(0)
  end

  it "stops between batches when a scheduled run asks it to, leaving the rest pending (1.81.0)" do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    Array.new(5) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }
    asked = 0
    stub_const("CooperativeStop::INTERVAL", 0.seconds) # ask on every call

    computed = CooperativeStop.with(-> { (asked += 1) > 1 }) { described_class.perform_now }

    expect(computed).to eq(2)
    expect(MemoryObservation.keywords_pending.count).to eq(3)
  end

  it "never stops outside a scheduled run" do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    Array.new(5) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }

    expect(described_class.perform_now).to eq(5)
  end

  # 1.83.0: after the paths, the LLM words of the facts that name no entity.
  context "with LLM words" do
    let(:provider) do
      FakeProvider.new do |prompt, **|
        ids = JSON.parse(prompt.to_s[/STATEMENTS:\n(\[.*\])/m, 1]).map { |entry| entry["id"].to_s }
        { ok: true, done_reason: "stop", error: nil, latency_ms: 1.0, text: ids.to_h { |id| [ id, %w[frame] ] }.to_json }
      end
    end

    it "computes the words of the facts that name no entity, after their paths" do
      fact = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders frames.")

      with_llm_provider(provider) { described_class.perform_now }

      expect(fact.reload).to have_attributes(keywords_at: be_present, llm_keywords: %w[frame], llm_keywords_at: be_present)
    end

    it "moves past a batch that stamps nothing, and stops after three in a row (final review)" do
      stub_const("FactKeywords::LlmWords::BATCH_SIZE", 2)
      facts = Array.new(6) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }
      FactKeywords.compute!(MemoryObservation.where(id: facts.map(&:id)).includes(:memory_entity))
      head = facts.first(2).map(&:id).map(&:to_s)
      picky = FakeProvider.new do |prompt, **|
        ids = JSON.parse(prompt.to_s[/STATEMENTS:\n(\[.*\])/m, 1]).map { |entry| entry["id"].to_s }
        next { ok: false, text: nil, error: "refused", latency_ms: 1.0 } if (ids & head).any?

        { ok: true, done_reason: "stop", error: nil, latency_ms: 1.0, text: ids.to_h { |id| [ id, %w[frame] ] }.to_json }
      end

      with_llm_provider(picky) { described_class.perform_now }

      expect(MemoryObservation.where(id: facts.last(4).map(&:id)).where.not(llm_keywords_at: nil).count).to eq(4)
      expect(MemoryObservation.where(id: facts.first(2).map(&:id)).llm_words_pending.count).to eq(2)
    end

    it "walks past batches the cloud gate refuses, however many, and words the rest (Graphy)" do
      stub_const("FactKeywords::LlmWords::BATCH_SIZE", 2)
      facts = Array.new(8) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }
      FactKeywords.compute!(MemoryObservation.where(id: facts.map(&:id)).includes(:memory_entity))
      refused = facts.first(6).map(&:id).map(&:to_s)
      gate = FakeProvider.new do |prompt, **|
        ids = JSON.parse(prompt.to_s[/STATEMENTS:\n(\[.*\])/m, 1]).map { |entry| entry["id"].to_s }
        next { ok: false, text: nil, error: "cloud_not_allowed", latency_ms: 0.0 } if (ids & refused).any?

        { ok: true, done_reason: "stop", error: nil, latency_ms: 1.0, text: ids.to_h { |id| [ id, %w[frame] ] }.to_json }
      end

      with_llm_provider(gate) { described_class.perform_now }

      expect(MemoryObservation.where(id: facts.last(2).map(&:id)).where.not(llm_keywords_at: nil).count).to eq(2)
      expect(MemoryObservation.where(id: facts.first(6).map(&:id)).llm_words_pending.count).to eq(6)
    end

    it "stops between LLM batches when a scheduled run asks it to" do
      stub_const("FactKeywords::LlmWords::BATCH_SIZE", 2)
      stub_const("CooperativeStop::INTERVAL", 0.seconds)
      Array.new(5) { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") }
      asked = 0

      # Two checks around the path batches, one before the first LLM batch, then the stop.
      with_llm_provider(provider) { CooperativeStop.with(-> { (asked += 1) > 3 }) { described_class.perform_now } }

      expect(MemoryObservation.where.not(llm_keywords_at: nil).count).to eq(2)
    end
  end

  it "does nothing with the setting off" do
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact.")
    AppSettings.fact_keywords_enabled = false

    expect(described_class.perform_now).to eq(0)
    expect(MemoryObservation.keywords_pending.count).to eq(1)
  end

  it "enqueues one delayed run per burst of writes, and none with the setting off" do
    clear_enqueued_jobs

    expect { 3.times { |i| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget fact #{i}.") } }
      .to have_enqueued_job(described_class).exactly(:once)

    described_class.reset_request!
    AppSettings.fact_keywords_enabled = false
    expect(described_class.request!).to be(false)
  end
end
