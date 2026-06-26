# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingConfig do
  around do |example|
    original = {
      OLLAMA_URL: ENV["OLLAMA_URL"],
      EMBEDDING_MODEL: ENV["EMBEDDING_MODEL"],
      EMBEDDING_PROVIDER: ENV["EMBEDDING_PROVIDER"],
      EMBEDDING_DIMS: ENV["EMBEDDING_DIMS"]
    }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key.to_s) : ENV[key.to_s] = value }
  end

  before do
    AppSettings.clear_cache
    AppSettings.embedding_url = ""
    AppSettings.embedding_model = ""
    AppSettings.embedding_provider = ""
    AppSettings.embedding_dims = 0
  end

  after { AppSettings.clear_cache }

  describe ".resolved_config" do
    it "returns defaults when AppSettings and ENV are blank" do
      ENV.delete("OLLAMA_URL")
      ENV.delete("EMBEDDING_MODEL")
      ENV.delete("EMBEDDING_PROVIDER")
      ENV.delete("EMBEDDING_DIMS")

      config = described_class.resolved_config

      expect(config[:url]).to eq("http://localhost:11434")
      expect(config[:model]).to eq("nomic-embed-text")
      expect(config[:provider]).to eq("ollama")
      expect(config[:dims]).to eq(768)
    end

    it "prefers AppSettings over ENV" do
      AppSettings.embedding_url = "http://app-settings.test:11434"
      ENV["OLLAMA_URL"] = "http://env.test:11434"

      expect(described_class.resolved_config[:url]).to eq("http://app-settings.test:11434")
      expect(described_class.config_sources[:url]).to eq(:app_settings)
    end

    it "falls back to ENV when AppSettings is blank" do
      ENV["OLLAMA_URL"] = "http://env.test:11434"
      ENV["EMBEDDING_DIMS"] = "512"

      config = described_class.resolved_config

      expect(config[:url]).to eq("http://env.test:11434")
      expect(config[:dims]).to eq(512)
      expect(described_class.config_sources[:url]).to eq(:env)
    end
  end

  describe ".fallback_for" do
    it "returns ENV value and source when set" do
      ENV["OLLAMA_URL"] = "http://env-fallback.test:11434"

      fallback = described_class.fallback_for(:url)

      expect(fallback[:value]).to eq("http://env-fallback.test:11434")
      expect(fallback[:source]).to eq(:env)
    end

    it "returns default when ENV is blank" do
      ENV.delete("EMBEDDING_MODEL")

      fallback = described_class.fallback_for(:model)

      expect(fallback[:value]).to eq("nomic-embed-text")
      expect(fallback[:source]).to eq(:default)
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
