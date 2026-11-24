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
    # Below embed / embed!, so the calls still pass spec/support/embedding_lock_guard.rb.
    allow(service).to receive(:embed_with_retries).and_return(nil)
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
  end

  # With `:with_test_embeddings`: answers each embedding call with deterministic_embedding and
  # records it, below EmbeddingService#embed, so the real path runs and the vector is stored.
  #
  #   calls = record_embedding_calls!
  #   MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
  #   calls.sole # => { text: "Component: SynthWidget", held: false, lock_free: true }
  #
  # @return [Array<Hash>] the calls so far, in order: `text`, `held` (this thread was inside
  #   ProjectMembership.with_membership_lock) and `lock_free` (no session held the lock, read from
  #   MariaDB)
  def record_embedding_calls!
    calls = []
    allow(EmbeddingService.instance).to receive(:embed_with_retries) do |text, **|
      calls << { text: text, held: ProjectMembership.membership_lock_held?, lock_free: membership_lock_free? }
      deterministic_embedding(text)
    end
    calls
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
