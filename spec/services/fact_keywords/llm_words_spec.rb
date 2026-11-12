# frozen_string_literal: true

require "rails_helper"

# 1.83.0: 1–3 words naming what a fact that mentions no entity is about, from the summary LLM
# (faked here at the provider boundary).
RSpec.describe FactKeywords::LlmWords do
  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Class", project_id: root.id) }
  let(:answers) { {} }
  let(:provider) do
    FakeProvider.new do |prompt, **|
      ids = JSON.parse(prompt.to_s[/STATEMENTS:\n(\[.*\])/m, 1]).map { |entry| entry["id"].to_s }
      { ok: true, done_reason: "stop", error: nil, latency_ms: 1.0, text: answers.slice(*ids).to_json }
    end
  end

  after { AppSettings.where(var: %w[llm_keywords_enabled]).delete_all }

  def fact(content, path: [ "Gadget Project", "SynthWidget" ])
    MemoryObservation.create!(memory_entity: widget, content: content).tap do |observation|
      observation.update_columns(keywords: path, keywords_at: Time.current)
    end
  end

  def compute(*facts) = with_llm_provider(provider) { described_class.compute!(facts.flatten) }

  it "asks for what each fact is about, never its value, with the facts as data" do
    rails = fact("Developed using Rails 8.0")
    answers[rails.id.to_s] = %w[Rails version]

    compute(rails)

    prompt = provider.calls.sole.prompt.to_s
    expect(prompt).to include("name what it is about, not what it says about it", "never its value", %("id":#{rails.id}))
    expect(rails.reload).to have_attributes(llm_keywords: %w[rails version], llm_keywords_at: be_present)
  end

  it "stamps a fact with mentions without asking, and leaves a fact whose path is pending alone" do
    named = fact("It belongs to a User.", path: [ "Gadget Project", "SynthWidget", "User" ])
    pending = MemoryObservation.create!(memory_entity: widget, content: "Validates presence of name.")

    compute(named, pending)

    expect(provider.calls).to be_empty
    expect(named.reload).to have_attributes(llm_keywords: [], llm_keywords_at: be_present)
    expect(pending.reload.llm_keywords_at).to be_nil
  end

  it "parses strictly: an id it wasn't asked about is ignored, a missing one stays pending" do
    asked = fact("Validates presence of name.")
    missing = fact("Validates presence of email.")
    answers[asked.id.to_s] = %w[name presence]
    answers["999999"] = %w[hijack]

    compute(asked, missing)

    expect(asked.reload.llm_keywords).to eq(%w[name presence])
    expect(missing.reload.llm_keywords_at).to be_nil
  end

  it "batches the calls" do
    facts = Array.new(described_class::BATCH_SIZE + 1) { |i| fact("Fact number #{i} about naming.") }
    facts.each { |observation| answers[observation.id.to_s] = %w[naming] }

    compute(facts)

    expect(provider.calls.size).to eq(2)
  end

  it "stamps nothing and raises nothing with the LLM down or the setting off" do
    down = fact("Validates presence of name.")
    with_llm_provider(FakeProvider.new(result: { ok: false, text: nil, error: "connection refused", latency_ms: 1.0 })) do
      described_class.compute!([ down ])
    end
    expect(down.reload.llm_keywords_at).to be_nil

    AppSettings.llm_keywords_enabled = false
    compute(down)
    expect(provider.calls).to be_empty
  end

  it "normalizes: case, separators, values dropped, sorted, at most 3, generic-only means none" do
    # Stored as written ("rails", not Rails' own singular "rail"); plurals are folded by .keys.
    expect(described_class.normalize([ "Rails 8", "Versions" ])).to eq(%w[rails versions])
    expect(described_class.normalize(%w[version Versions])).to eq(%w[version])
    expect(described_class.normalize([ "email address" ])).to eq(%w[address email])
    expect(described_class.normalize(%w[delta alpha charlie bravo])).to eq(%w[alpha charlie delta]) # the first 3, sorted
    expect(described_class.normalize(%w[config value])).to eq([])
    expect(described_class.normalize([ "config", "timeout" ])).to eq(%w[config timeout])
  end

  it "compares words by their keys: case and plurals folded" do
    expect(described_class.keys(%w[rails versions])).to eq(described_class.keys(%w[Rails version]))
    expect(described_class.keys(%w[email presence])).not_to eq(described_class.keys(%w[name presence]))
  end
end
