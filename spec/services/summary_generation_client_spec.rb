# frozen_string_literal: true

require "rails_helper"

RSpec.describe SummaryGenerationClient do
  around do |example|
    original = ENV.to_h.slice("SUMMARY_URL", "SUMMARY_MODEL", "SUMMARY_PROVIDER", "SUMMARY_TIMEOUT", "SUMMARY_MAX_TOKENS")
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
