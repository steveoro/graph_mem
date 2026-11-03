# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Router do
  let(:full_result) do
    { ok: true, text: "Alpha Service answer text.", error: nil, latency_ms: 12.5, prompt_tokens: 40, done_reason: "stop" }
  end
  let(:prompt) { "Summarize SynthWidget in Gadget Project: secret prompt text." }
  let(:lines) { [] }

  before do
    allow(SummaryGenerationClient).to receive(:generate).and_return(full_result)
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first if args.first.to_s.start_with?("[llm]")
      original.call(*args, &block)
    end
  end

  after { Llm::Registry.reset_overrides! }

  def logged = lines.map { |line| JSON.parse(line.delete_prefix("[llm] ")) }

  describe ".generate" do
    it "returns the provider's Hash unchanged except for provider: \"ollama\"" do
      expect(described_class.generate(:summary, prompt, style: "concise")).to eq(full_result.merge(provider: "ollama"))
    end

    it "keeps http_status and the error string of a failed call" do
      failed = { ok: false, text: nil, error: "provider_unavailable", latency_ms: 3.0, http_status: 413 }
      allow(SummaryGenerationClient).to receive(:generate).and_return(failed)

      expect(described_class.generate(:scan, prompt, style: "concise", options: { num_ctx: 4096 })).to eq(failed.merge(provider: "ollama"))
    end

    it "passes options: only when the caller gives them" do
      described_class.generate(:summary, prompt, style: "detailed")
      described_class.generate(:scan, prompt, style: "concise", options: { format: "json" })

      expect(SummaryGenerationClient).to have_received(:generate).with(prompt, style: "detailed").ordered
      expect(SummaryGenerationClient).to have_received(:generate).with(prompt, style: "concise", options: { format: "json" }).ordered
    end

    it "raises for an unknown task without calling a provider" do
      expect { described_class.generate(:chat, prompt, style: "concise") }.to raise_error(ArgumentError, /unknown LLM task: :chat/)
      expect { described_class.usable?("summary") }.to raise_error(ArgumentError)
      expect { described_class.client(:judge_inline) }.to raise_error(ArgumentError)
      expect(SummaryGenerationClient).not_to have_received(:generate)
    end

    it "writes one [llm] line per call with sizes and outcome, never the prompt, the answer or an error" do
      AppSettings.summary_model = "synth-model"
      AppSettings.clear_cache
      described_class.generate(:scan, prompt, style: "concise", options: {})
      allow(SummaryGenerationClient).to receive(:generate).and_return(ok: false, text: nil, error: "prompt is blank")
      described_class.generate(:summary, prompt, style: "concise")

      expect(logged).to eq([
        { "task" => "scan", "provider" => "ollama", "model" => "synth-model", "inline" => false, "prompt_chars" => prompt.length,
          "est_in_tokens" => (prompt.length / 4.0).ceil, "out_chars" => 26, "est_out_tokens" => 7, "latency_ms" => 12.5,
          "outcome" => "ok", "prompt_tokens" => 40 },
        { "task" => "summary", "provider" => "ollama", "model" => "synth-model", "inline" => false, "prompt_chars" => prompt.length,
          "est_in_tokens" => (prompt.length / 4.0).ceil, "out_chars" => 0, "est_out_tokens" => 0, "latency_ms" => nil, "outcome" => "error" }
      ])
      expect(lines.join).not_to include("SynthWidget", "Gadget Project", "secret", "Alpha Service", "prompt is blank")
    ensure
      AppSettings.where(var: "summary_model").delete_all
      AppSettings.clear_cache
    end

    it "logs and re-raises when a provider raises" do
      broken = Class.new(Llm::Provider) do
        def name = "broken"
        def generate(*, **) = raise(IOError, "socket closed")
      end
      Llm::Registry.override(:ollama, broken.new)

      expect { described_class.generate(:judge, prompt, style: "concise") }.to raise_error(IOError)
      expect(logged.sole).to include("task" => "judge", "provider" => "broken", "outcome" => "error", "out_chars" => 0)
    end

    it "returns the result when the logger fails" do
      allow(Rails.logger).to receive(:info).and_raise(IOError, "disk full")

      expect(described_class.generate(:summary, prompt, style: "concise")).to include(ok: true, provider: "ollama")
    end
  end

  describe ".usable?" do
    it "asks the task's provider, which asks SummarizationConfig.llm_usable?" do
      allow(SummarizationConfig).to receive(:llm_usable?).and_return(true, false)

      expect(%i[summary scan].map { |task| described_class.usable?(task) }).to eq([ true, false ])
    end
  end

  describe ".client" do
    it "is a generate(prompt, style:, options:) object bound to the task and the inline flag" do
      client = described_class.client(:judge, inline: true)

      expect(client.generate(prompt, style: "concise", options: { format: "json" })).to eq(full_result.merge(provider: "ollama"))
      expect(SummaryGenerationClient).to have_received(:generate).with(prompt, style: "concise", options: { format: "json" })
      expect(logged.sole).to include("task" => "judge", "inline" => true)
      expect(described_class.client(:judge)).to have_attributes(task: :judge, inline: false)
    end
  end
end
