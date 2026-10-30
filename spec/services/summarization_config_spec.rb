# frozen_string_literal: true

require "rails_helper"

RSpec.describe SummarizationConfig do
  around do |example|
    original = {
      SUMMARY_URL: ENV["SUMMARY_URL"],
      SUMMARY_MODEL: ENV["SUMMARY_MODEL"],
      SUMMARY_PROVIDER: ENV["SUMMARY_PROVIDER"],
      SUMMARY_TIMEOUT: ENV["SUMMARY_TIMEOUT"],
      SUMMARY_MAX_TOKENS: ENV["SUMMARY_MAX_TOKENS"],
      SUMMARY_NUM_CTX: ENV["SUMMARY_NUM_CTX"],
      SUMMARY_OBSERVATIONS_PER_ENTITY: ENV["SUMMARY_OBSERVATIONS_PER_ENTITY"],
      OLLAMA_URL: ENV["OLLAMA_URL"]
    }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key.to_s) : ENV[key.to_s] = value }
  end

  before do
    AppSettings.clear_cache
    AppSettings.summary_url = ""
    AppSettings.summary_model = ""
    AppSettings.summary_provider = ""
    AppSettings.summary_timeout = 0
    AppSettings.summary_max_tokens = 0
    AppSettings.summary_num_ctx = 0
    AppSettings.summary_observations_per_entity = 0
    AppSettings.enable_llm_summarization = false
  end

  after { AppSettings.clear_cache }

  describe ".resolved_config" do
    it "returns defaults when AppSettings and ENV are blank" do
      ENV.delete("SUMMARY_URL")
      ENV.delete("OLLAMA_URL")
      ENV.delete("SUMMARY_MODEL")
      ENV.delete("SUMMARY_PROVIDER")
      ENV.delete("SUMMARY_TIMEOUT")
      ENV.delete("SUMMARY_MAX_TOKENS")
      ENV.delete("SUMMARY_NUM_CTX")

      config = described_class.resolved_config

      expect(config[:url]).to eq("http://localhost:11434")
      expect(config[:model]).to eq("qwen3:8b")
      expect(config[:provider]).to eq("ollama")
      expect(config[:timeout]).to eq(30)
      expect(config[:max_tokens]).to eq(256)
      expect(config[:num_ctx]).to eq(8192)
      expect(config[:observations_per_entity]).to eq(3)
      expect(config[:llm_enabled]).to be false
    end

    it "prefers AppSettings over ENV" do
      AppSettings.summary_model = "gemma3:4b"
      ENV["SUMMARY_MODEL"] = "env-model"

      expect(described_class.resolved_config[:model]).to eq("gemma3:4b")
      expect(described_class.config_sources[:model]).to eq(:app_settings)
    end

    it "resolves observations_per_entity from AppSettings, ENV, then defaults" do
      expect(described_class.resolved_config[:observations_per_entity]).to eq(3)

      ENV["SUMMARY_OBSERVATIONS_PER_ENTITY"] = "5"
      expect(described_class.resolved_config[:observations_per_entity]).to eq(5)
      expect(described_class.config_sources[:observations_per_entity]).to eq(:env)

      AppSettings.summary_observations_per_entity = 7
      expect(described_class.resolved_config[:observations_per_entity]).to eq(7)
      expect(described_class.config_sources[:observations_per_entity]).to eq(:app_settings)
    end

    it "resolves num_ctx from AppSettings, SUMMARY_NUM_CTX, then 8192" do
      ENV["SUMMARY_NUM_CTX"] = "32768"
      expect(described_class.resolved_config[:num_ctx]).to eq(32_768)
      expect(described_class.config_sources[:num_ctx]).to eq(:env)

      AppSettings.summary_num_ctx = 4096
      expect(described_class.resolved_config[:num_ctx]).to eq(4096)
      AppSettings.summary_num_ctx = 0
      ENV["SUMMARY_NUM_CTX"] = "999999"
      expect(described_class.resolved_config[:num_ctx]).to eq(131_072)
      ENV["SUMMARY_NUM_CTX"] = "512"
      expect(described_class.resolved_config[:num_ctx]).to eq(2048)
      ENV["SUMMARY_NUM_CTX"] = "32768"
      AppSettings.summary_num_ctx = 4096
      expect(described_class.fallback_for(:num_ctx)).to eq(value: 32_768, source: :env)
    end

    it "falls back to OLLAMA_URL when SUMMARY_URL is blank" do
      ENV["OLLAMA_URL"] = "http://ollama-fallback.test:11434"

      expect(described_class.resolved_config[:url]).to eq("http://ollama-fallback.test:11434")
      expect(described_class.config_sources[:url]).to eq(:env)
    end

    it "strips leading and trailing spaces from the summary model" do
      AppSettings.summary_model = "  qwen3:8b  "

      expect(described_class.resolved_config[:model]).to eq("qwen3:8b")
    end

    it "treats a whitespace-only summary model as blank" do
      AppSettings.summary_model = "   "
      ENV["SUMMARY_MODEL"] = "gemma3:4b"

      expect(described_class.resolved_config[:model]).to eq("gemma3:4b")
      expect(described_class.config_sources[:model]).to eq(:env)
    end
  end

  describe ".llm_usable?" do
    it "returns false when disabled" do
      AppSettings.enable_llm_summarization = false
      AppSettings.summary_model = "qwen3:8b"

      expect(described_class.llm_usable?).to be false
    end

    it "returns true when enabled and configured" do
      AppSettings.enable_llm_summarization = true
      AppSettings.summary_url = "http://summary.test:11434"
      AppSettings.summary_model = "qwen3:8b"
      AppSettings.summary_provider = "ollama"

      expect(described_class.llm_usable?).to be true
    end
  end

  describe ".valid_provider?" do
    it "accepts allowed providers and blank" do
      expect(described_class.valid_provider?("ollama")).to be true
      expect(described_class.valid_provider?("openai_compatible")).to be true
      expect(described_class.valid_provider?("")).to be true
    end

    it "rejects unknown providers" do
      expect(described_class.valid_provider?("unknown")).to be false
    end
  end
end
