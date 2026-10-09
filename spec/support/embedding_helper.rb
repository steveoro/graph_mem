# frozen_string_literal: true

require "digest"

module EmbeddingHelper
  DEFAULT_TEST_DIMS = 768

  def deterministic_embedding(content, dims: DEFAULT_TEST_DIMS)
    canonical_content = content.to_s.delete_prefix("Restated: ")
    index = Digest::SHA256.hexdigest(canonical_content).to_i(16) % dims
    Array.new(dims, 0.0).tap { |vector| vector[index] = 1.0 }
  end

  def configure_test_embeddings!(dims: DEFAULT_TEST_DIMS)
    service = EmbeddingService.new(
      config: { url: "http://test", model: "test", provider: "ollama", dims: dims }
    )
    allow(service).to receive(:embed).and_return(nil)
    allow(service).to receive(:embed!).and_return(nil)
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
  end
end

RSpec.configure do |config|
  config.include EmbeddingHelper

  config.before(:each) do |example|
    if example.metadata[:with_test_embeddings]
      configure_test_embeddings!
    else
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
    end
  end

  config.after(:suite) do
    EmbeddingService.reset_vector_cache!
  end
end
