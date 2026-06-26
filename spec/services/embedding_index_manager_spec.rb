# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingIndexManager do
  let(:conn) { ActiveRecord::Base.connection }
  let(:dims) { 4 }

  before do
    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(EmbeddingConfig).to receive(:resolved_config).and_return(
      url: "http://localhost:11434",
      model: "test",
      provider: "ollama",
      dims: dims
    )
    allow(EmbeddingIndexStatus).to receive(:indexes).and_return(
      memory_entities: true,
      memory_observations: true
    )
  end

  describe ".add_indexes!" do
    it "raises when embedding columns are missing" do
      allow(conn).to receive(:column_exists?).with(:memory_entities, :embedding).and_return(false)

      expect {
        described_class.add_indexes!
      }.to raise_error(EmbeddingIndexManager::PrecheckError, /don't exist/)
    end

    it "raises when NULL embeddings remain" do
      allow(conn).to receive(:column_exists?).with(:memory_entities, :embedding).and_return(true)
      allow(MemoryEntity).to receive_message_chain(:where, :count).and_return(2)
      allow(MemoryObservation).to receive_message_chain(:where, :count).and_return(0)

      expect {
        described_class.add_indexes!
      }.to raise_error(EmbeddingIndexManager::PrecheckError, /NULL embeddings/)
    end

    it "creates indexes when prechecks pass" do
      allow(conn).to receive(:column_exists?).with(:memory_entities, :embedding).and_return(true)
      allow(MemoryEntity).to receive_message_chain(:where, :count).and_return(0)
      allow(MemoryObservation).to receive_message_chain(:where, :count).and_return(0)
      expect(conn).to receive(:execute).at_least(:once)
      expect(EmbeddingService).to receive(:reset_vector_cache!)
      expect(EmbeddingService).to receive(:reset_instance!)

      result = described_class.add_indexes!

      expect(result[:success]).to be true
      expect(result[:message]).to include("ANN search enabled")
    end
  end

  describe ".drop_indexes!" do
    it "drops indexes and resets caches" do
      allow(conn).to receive(:execute).and_return([])
      expect(EmbeddingService).to receive(:reset_vector_cache!)
      expect(EmbeddingService).to receive(:reset_instance!)

      result = described_class.drop_indexes!

      expect(result[:success]).to be true
    end
  end
end
