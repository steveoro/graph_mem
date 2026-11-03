# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::OllamaProvider do
  subject(:provider) { described_class.new }

  let(:result) { { ok: true, text: "ok", error: nil, latency_ms: 1.0, prompt_tokens: 3, done_reason: "stop" } }

  before { allow(SummaryGenerationClient).to receive(:generate).and_return(result) }

  it "calls SummaryGenerationClient at class level, with options: only when given, and returns its Hash" do
    expect(provider.generate("Describe SynthWidget.", style: "concise")).to equal(result)
    provider.generate("Describe SynthWidget.", style: "detailed", options: { num_predict: 64 })

    expect(SummaryGenerationClient).to have_received(:generate).with("Describe SynthWidget.", style: "concise").ordered
    expect(SummaryGenerationClient).to have_received(:generate).with("Describe SynthWidget.", style: "detailed", options: { num_predict: 64 }).ordered
  end

  it "is named ollama, local, available when summarization is usable, and reports the configured model" do
    allow(SummarizationConfig).to receive(:llm_usable?).and_return(false)
    allow(SummarizationConfig).to receive(:resolved_config).and_return(model: "synth-model")

    expect(provider).to have_attributes(name: "ollama", cloud?: false, available?: false, model: "synth-model")
  end
end
