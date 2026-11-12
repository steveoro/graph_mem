# frozen_string_literal: true

require "rails_helper"

# 1.83.0: a fact's LLM words (FactKeywords::LlmWords), for facts that name no entity: pending until
# computed, pending again when its text changes, never embedded nor in the JSON.
RSpec.describe MemoryObservation, "LLM words" do
  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Class", project_id: root.id) }
  let(:fact) { described_class.create!(memory_entity: widget, content: "Validates presence of name.") }

  after { AppSettings.where(var: "llm_keywords_enabled").delete_all }

  it "starts pending with no words, and accepts only an array of strings" do
    expect(fact).to have_attributes(llm_keywords: [], llm_keywords_at: nil)
    expect(described_class.llm_words_pending).to include(fact)

    fact.llm_keywords = [ "presence", 3 ]
    expect(fact).not_to be_valid
    expect(fact.errors[:llm_keywords]).to be_present
  end

  it "is pending again when its text changes" do
    fact.update_columns(llm_keywords: %w[name presence], llm_keywords_at: Time.current)

    fact.update!(content: "Validates presence of email.")

    expect(fact.reload.llm_keywords_at).to be_nil
  end

  it "stays out of the JSON (REST and MCP output unchanged)" do
    expect(fact.as_json.keys).not_to include("llm_keywords", "llm_keywords_at")
  end

  it "is on by default" do
    expect(AppSettings.llm_keywords_enabled?).to be(true)
  end
end
