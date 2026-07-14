# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingService do
  let(:dims) { 4 }
  let(:fake_vector) { [ 0.1, 0.2, 0.3, 0.4 ] }
  let(:ollama_response_body) { { "embeddings" => [ fake_vector ] }.to_json }

  let(:service) do
    described_class.new(
      config: {
        url: "http://ollama.test:11434",
        model: "test-model",
        provider: "ollama",
        dims: dims
      }
    )
  end

  def stub_successful_embed
    response = instance_double(Net::HTTPSuccess, body: ollama_response_body)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
    http
  end

  def stub_failed_embed(code: "500", body: "Internal Server Error")
    response = instance_double(Net::HTTPInternalServerError, code: code, body: body)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
    http
  end

  describe ".config_snapshot" do
    it "returns env-based configuration" do
      snapshot = described_class.config_snapshot

      expect(snapshot).to include(:url, :model, :provider, :dims)
      expect(snapshot[:dims]).to be_a(Integer)
    end
  end

  describe ".vector_enabled?" do
    before do
      described_class.reset_vector_cache!
      # Unstub the global mock from spec/support/embedding_helper.rb
      allow(described_class).to receive(:vector_enabled?).and_call_original
    end
    after { described_class.reset_vector_cache! }

    it "returns true when the embedding column exists" do
      allow(ActiveRecord::Base.connection).to receive(:column_exists?)
        .with(:memory_entities, :embedding).and_return(true)
      expect(described_class.vector_enabled?).to be true
    end

    it "returns false when the embedding column does not exist" do
      allow(ActiveRecord::Base.connection).to receive(:column_exists?)
        .with(:memory_entities, :embedding).and_return(false)
      expect(described_class.vector_enabled?).to be false
    end

    it "caches the result after the first call" do
      allow(ActiveRecord::Base.connection).to receive(:column_exists?)
        .with(:memory_entities, :embedding).and_return(true)
      described_class.vector_enabled?
      described_class.vector_enabled?
      expect(ActiveRecord::Base.connection).to have_received(:column_exists?).once
    end

    it "returns false on connection error" do
      allow(ActiveRecord::Base.connection).to receive(:column_exists?).and_raise(StandardError)
      expect(described_class.vector_enabled?).to be false
    end
  end

  describe ".reset_vector_cache!" do
    before do
      allow(described_class).to receive(:vector_enabled?).and_call_original
    end

    it "clears the cached vector_enabled? value" do
      allow(ActiveRecord::Base.connection).to receive(:column_exists?)
        .with(:memory_entities, :embedding).and_return(true)
      described_class.vector_enabled?
      described_class.reset_vector_cache!
      allow(ActiveRecord::Base.connection).to receive(:column_exists?)
        .with(:memory_entities, :embedding).and_return(false)
      expect(described_class.vector_enabled?).to be false
    end
  end

  describe "#embed" do
    it "returns a vector array on success" do
      stub_successful_embed
      result = service.embed("hello world")
      expect(result).to eq(fake_vector)
    end

    it "returns nil for blank text" do
      expect(service.embed("")).to be_nil
      expect(service.embed(nil)).to be_nil
    end

    it "retries on failure up to MAX_RETRIES times" do
      allow(service).to receive(:sleep)
      http = stub_failed_embed
      result = service.embed("test")
      expect(result).to be_nil
      expect(http).to have_received(:request).exactly(described_class::MAX_RETRIES + 1).times
    end

    it "succeeds after transient failures" do
      allow(service).to receive(:sleep)
      fail_resp = instance_double(Net::HTTPInternalServerError, code: "500", body: "error")
      allow(fail_resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      ok_resp = instance_double(Net::HTTPSuccess, body: ollama_response_body)
      allow(ok_resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(fail_resp, ok_resp)

      result = service.embed("test")
      expect(result).to eq(fake_vector)
    end

    it "raises dimension mismatch as part of retry cycle" do
      allow(service).to receive(:sleep)
      wrong_vec = [ 0.1, 0.2 ]
      resp = instance_double(Net::HTTPSuccess, body: { "embeddings" => [ wrong_vec ] }.to_json)
      allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(resp)

      expect(service.embed("test")).to be_nil
    end
  end

  describe "#embed!" do
    it "returns a vector array on success" do
      stub_successful_embed

      expect(service.embed!("hello world")).to eq(fake_vector)
    end

    it "raises the final embedding error on failure" do
      allow(service).to receive(:sleep)
      stub_failed_embed(code: "503", body: "unavailable")

      expect {
        service.embed!("test")
      }.to raise_error(described_class::EmbeddingError, /HTTP 503/)
      expect(service.last_error).to be_a(described_class::EmbeddingError)
    end
  end

  describe "#embed (openai_compatible provider)" do
    let(:openai_service) do
      described_class.new(
        config: {
          url: "http://openai.test",
          model: "text-embed",
          provider: "openai_compatible",
          dims: dims
        }
      )
    end

    it "uses the /embeddings endpoint and extracts from data[0].embedding" do
      resp_body = { "data" => [ { "embedding" => fake_vector } ] }.to_json
      resp = instance_double(Net::HTTPSuccess, body: resp_body)
      allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(resp)

      result = openai_service.embed("test")
      expect(result).to eq(fake_vector)
    end
  end

  describe "#embed_entity" do
    let(:entity) { MemoryEntity.create!(name: "TestEmbed", entity_type: "Project", description: "A project") }

    it "is a no-op when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      expect(service.embed_entity(entity)).to be_nil
    end

    it "composes entity text and calls store_vector on success" do
      allow(described_class).to receive(:vector_enabled?).and_return(true)
      stub_successful_embed
      allow(service).to receive(:store_vector)
      service.embed_entity(entity)
      expect(service).to have_received(:store_vector).with(entity, fake_vector)
    end
  end

  describe "#embed_observation" do
    let(:entity) { MemoryEntity.create!(name: "ObsParent", entity_type: "Project") }
    let(:observation) { MemoryObservation.create!(memory_entity: entity, content: "test observation") }

    it "is a no-op when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      expect(service.embed_observation(observation)).to be_nil
    end

    it "embeds observation content and calls store_vector on success" do
      allow(described_class).to receive(:vector_enabled?).and_return(true)
      stub_successful_embed
      allow(service).to receive(:store_vector)
      service.embed_observation(observation)
      expect(service).to have_received(:store_vector).with(observation, fake_vector)
    end
  end

  describe "#embed_entity_binary" do
    let(:entity) { MemoryEntity.create!(name: "BinEntity", entity_type: "Task") }

    it "returns nil when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      expect(service.embed_entity_binary(entity)).to be_nil
    end

    it "returns packed binary floats when embedding succeeds" do
      allow(described_class).to receive(:vector_enabled?).and_return(true)
      stub_successful_embed
      result = service.embed_entity_binary(entity)
      expect(result).to eq(fake_vector.pack("e*"))
      expect(result.bytesize).to eq(dims * 4)
    end

    it "returns nil when embed returns nil" do
      allow(described_class).to receive(:vector_enabled?).and_return(true)
      allow(service).to receive(:embed).and_return(nil)
      expect(service.embed_entity_binary(entity)).to be_nil
    end
  end

  describe "#embed_observation_binary" do
    let(:entity) { MemoryEntity.create!(name: "BinObsParent", entity_type: "Task") }
    let(:observation) { MemoryObservation.create!(memory_entity: entity, content: "binary test") }

    it "returns nil when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      expect(service.embed_observation_binary(observation)).to be_nil
    end

    it "returns packed binary floats when embedding succeeds" do
      allow(described_class).to receive(:vector_enabled?).and_return(true)
      stub_successful_embed
      result = service.embed_observation_binary(observation)
      expect(result).to eq(fake_vector.pack("e*"))
    end
  end

  describe "compose_entity_text (private)" do
    it "includes entity_type and name" do
      entity = double("Entity", name: "MyApp", entity_type: "Project", aliases: nil, description: nil)
      text = service.send(:compose_entity_text, entity)
      expect(text).to eq("Project: MyApp")
    end

    it "includes aliases when present" do
      entity = double("Entity", name: "MyApp", entity_type: "Project", aliases: "app1|app2", description: nil)
      text = service.send(:compose_entity_text, entity)
      expect(text).to include("Aliases: app1|app2")
    end

    it "includes description when present" do
      entity = double("Entity", name: "MyApp", entity_type: "Project", aliases: nil, description: "A web app")
      text = service.send(:compose_entity_text, entity)
      expect(text).to include("A web app")
    end

    it "joins all parts with period-space" do
      entity = double("Entity", name: "MyApp", entity_type: "Project", aliases: "alias1", description: "desc1")
      text = service.send(:compose_entity_text, entity)
      expect(text).to eq("Project: MyApp. Aliases: alias1. desc1")
    end
  end

  describe "compose_observation_text (private)" do
    it "includes content, source, and tags" do
      observation = double(
        "Observation",
        content: "The deployment succeeded",
        source: "ci",
        tags: %w[deployment verified]
      )

      text = service.send(:compose_observation_text, observation)

      expect(text).to eq("The deployment succeeded\nSource: ci\nTags: deployment, verified")
    end
  end

  describe "validate_dimensions! (private)" do
    it "does not raise for matching dimensions" do
      expect { service.send(:validate_dimensions!, fake_vector) }.not_to raise_error
    end

    it "raises EmbeddingError for mismatched dimensions" do
      expect {
        service.send(:validate_dimensions!, [ 0.1, 0.2 ])
      }.to raise_error(described_class::EmbeddingError, /Dimension mismatch/)
    end
  end

  describe "#check_connection" do
    it "returns ok with dims and latency when embed succeeds" do
      stub_successful_embed

      result = service.check_connection

      expect(result[:ok]).to be true
      expect(result[:dims]).to eq(dims)
      expect(result[:latency_ms]).to be_a(Numeric)
      expect(result[:error]).to be_nil
    end

    it "returns failure when embed! returns nil" do
      allow(service).to receive(:embed!).and_return(nil)

      result = service.check_connection

      expect(result[:ok]).to be false
      expect(result[:error]).to include("nil")
    end

    it "returns the underlying embedding error details" do
      allow(service).to receive(:sleep)
      stub_failed_embed(code: "503", body: "unavailable")

      result = service.check_connection

      expect(result[:ok]).to be false
      expect(result[:error]).to include("EmbeddingService::EmbeddingError")
      expect(result[:error]).to include("HTTP 503")
    end

    it "returns failure on dimension mismatch" do
      allow(service).to receive(:embed!).and_return([ 0.1, 0.2 ])

      result = service.check_connection

      expect(result[:ok]).to be false
      expect(result[:error]).to match(/Dimension mismatch/)
    end
  end

  describe "#regenerate_all" do
    it "returns zeros when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      result = service.regenerate_all
      expect(result).to eq({ entities: 0, observations: 0 })
    end
  end

  describe "#backfill_all" do
    it "returns zeros when vector is disabled" do
      allow(described_class).to receive(:vector_enabled?).and_return(false)
      result = service.backfill_all
      expect(result).to eq({ entities: 0, observations: 0 })
    end
  end

  describe ".reset_instance!" do
    it "clears the singleton so the next instance uses fresh config" do
      first = described_class.instance
      described_class.reset_instance!
      second = described_class.instance

      expect(second).not_to equal(first)
    end
  end

  describe ".config_snapshot" do
    it "delegates to EmbeddingConfig" do
      expect(EmbeddingConfig).to receive(:resolved_config).and_return(url: "http://test", model: "m", provider: "ollama", dims: 4)

      expect(described_class.config_snapshot[:url]).to eq("http://test")
    end
  end
end
