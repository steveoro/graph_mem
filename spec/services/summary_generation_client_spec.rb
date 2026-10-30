# frozen_string_literal: true

require "rails_helper"

RSpec.describe SummaryGenerationClient do
  around do |example|
    original = ENV.to_h.slice("SUMMARY_URL", "SUMMARY_MODEL", "SUMMARY_PROVIDER", "SUMMARY_TIMEOUT", "SUMMARY_MAX_TOKENS", "SUMMARY_NUM_CTX")
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    described_class.reset_instance!
  end

  before do
    AppSettings.clear_cache
    AppSettings.summary_url = "http://summary.test:11434"
    AppSettings.summary_model = "qwen3:8b"
    AppSettings.summary_provider = "ollama"
    AppSettings.summary_timeout = 10
    AppSettings.summary_max_tokens = 128
    described_class.reset_instance!
  end

  after { AppSettings.clear_cache }

  describe "#generate" do
    it "requests Ollama generation with the configured model" do
      response = instance_double(Net::HTTPSuccess, body: { response: "Steve uses Ruby." }.to_json)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      expect(http).to receive(:request) do |request|
        payload = JSON.parse(request.body)
        expect(payload["model"]).to eq("qwen3:8b")
        expect(payload["stream"]).to be false
        response
      end

      result = described_class.generate("Summarize these facts.", style: "concise")

      expect(result[:ok]).to be true
      expect(result[:text]).to eq("Steve uses Ruby.")
    end

    context "with the request body captured" do
      let(:bodies) { [] }

      before do
        response = instance_double(Net::HTTPSuccess, body: { response: "[]" }.to_json)
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        http = instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:request) { |request| bodies << JSON.parse(request.body) and response }
      end

      it "sends num_ctx on every Ollama request, from the setting or the 8192 default" do
        described_class.generate("Summarize these facts.")
        expect(bodies.last["options"]).to include("num_ctx" => 8192, "num_predict" => 128)
        expect(bodies.last).not_to have_key("format")

        AppSettings.summary_num_ctx = 16_384
        described_class.reset_instance!
        described_class.generate("Summarize these facts.")
        expect(bodies.last["options"]["num_ctx"]).to eq(16_384)
      ensure
        AppSettings.where(var: "summary_num_ctx").delete_all
      end

      it "merges the options keyword: num_ctx and format json" do
        described_class.generate("Judge these facts.", options: { num_ctx: 4096, num_predict: 1024, format: "json" })

        expect(bodies.last["options"]).to include("num_ctx" => 4096, "num_predict" => 1024)
        expect(bodies.last["format"]).to eq("json")
      end

      it "ignores the Ollama-only options on the OpenAI-compatible path" do
        AppSettings.summary_provider = "openai_compatible"
        described_class.reset_instance!
        described_class.generate("Judge these facts.", options: { num_ctx: 4096, format: "json", truncate: false })

        expect(bodies.last.keys).not_to include("options", "format", "num_ctx", "truncate")
        expect(bodies.last["max_tokens"]).to eq(128)
      end

      it "sends num_predict as max_tokens on the OpenAI-compatible path" do
        AppSettings.summary_provider = "openai_compatible"
        described_class.reset_instance!
        described_class.generate("Extract these files.", options: { num_predict: 2048 })

        expect(bodies.last["max_tokens"]).to eq(2048)
      end

      it "sends truncate top-level only when given" do
        described_class.generate("Extract these files.")
        expect(bodies.last).not_to have_key("truncate")

        described_class.generate("Extract these files.", options: { truncate: false })
        expect(bodies.last["truncate"]).to be false
        expect(bodies.last["options"]).not_to have_key("truncate")
      end

      it "keeps today's payload when no option is given" do
        described_class.generate("Summarize these facts.", style: "detailed")

        expect(bodies.last).to eq(
          "model" => "qwen3:8b", "prompt" => "Summarize these facts.", "stream" => false,
          "options" => { "temperature" => 0.3, "num_predict" => 128, "num_ctx" => 8192 }
        )
      end
    end

    context "with a stubbed HTTP response" do
      let(:http) { instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil) }

      def answer_with(body)
        response = instance_double(Net::HTTPSuccess, body: body.to_json)
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:request).and_return(response)
      end

      it "cuts the answer at MAX_OUTPUT_LENGTH by default and not at all with max_output_length: nil" do
        answer_with(response: "x" * 20_000)

        expect(described_class.generate("Summarize these facts.")[:text].length).to eq(described_class::MAX_OUTPUT_LENGTH)
        expect(described_class.generate("Extract these files.", options: { max_output_length: nil })[:text].length).to eq(20_000)
      end

      it "passes prompt_eval_count and done_reason through" do
        answer_with(response: "{}", prompt_eval_count: 5000, done_reason: "length")

        result = described_class.generate("Extract these files.")

        expect(result).to include(ok: true, prompt_tokens: 5000, done_reason: "length")
      end

      it "returns nil prompt_tokens and done_reason when the provider sends none" do
        answer_with(response: "Synth summary.")

        expect(described_class.generate("Summarize these facts.")).to include(prompt_tokens: nil, done_reason: nil)
      end

      it "maps finish_reason and usage on the OpenAI-compatible path" do
        AppSettings.summary_provider = "openai_compatible"
        described_class.reset_instance!
        answer_with(choices: [ { message: { content: "{}" }, finish_reason: "length" } ], usage: { prompt_tokens: 900 })

        expect(described_class.generate("Extract these files.")).to include(prompt_tokens: 900, done_reason: "length")
      end

      it "uses the timeout option for this request only, the open timeout at most 5 s" do
        answer_with(response: "Synth summary.")

        described_class.generate("Extract these files.", options: { timeout: 120 })
        expect(http).to have_received(:read_timeout=).with(120)
        expect(http).to have_received(:open_timeout=).with(5)

        described_class.generate("Summarize these facts.")
        expect(http).to have_received(:read_timeout=).with(10)
      end
    end

    it "returns a safe error hash on provider failure" do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      result = described_class.generate("Summarize these facts.")

      expect(result[:ok]).to be false
      expect(result[:error]).to eq("provider_unavailable")
    end
  end
end
