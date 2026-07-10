# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingVectorTriggerManager do
  let(:conn) { instance_double(ActiveRecord::ConnectionAdapters::Mysql2Adapter) }

  before do
    allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
    allow(EmbeddingConfig).to receive(:resolved_config).and_return(
      url: "http://localhost:11434",
      model: "test",
      provider: "ollama",
      dims: 4
    )
    allow(conn).to receive(:table_exists?).and_return(true)
    allow(conn).to receive(:columns).and_return([
      instance_double(ActiveRecord::ConnectionAdapters::Column, name: "embedding", null: false)
    ])
    allow(conn).to receive(:execute)
  end

  describe ".install!" do
    it "creates zero-vector insert triggers for embedding tables" do
      described_class.install!

      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_entities_embedding_bi")
      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_observations_embedding_bi")
      expect(conn).to have_received(:execute).with(
        a_string_matching(/CREATE TRIGGER trg_memory_entities_embedding_bi.*REPEAT\('0,', 3\)/)
      )
      expect(conn).to have_received(:execute).with(
        a_string_matching(/CREATE TRIGGER trg_memory_observations_embedding_bi.*REPEAT\('0,', 3\)/)
      )
    end

    it "skips nullable embedding columns" do
      allow(conn).to receive(:columns).and_return([
        instance_double(ActiveRecord::ConnectionAdapters::Column, name: "embedding", null: true)
      ])

      described_class.install!

      expect(conn).not_to have_received(:execute)
    end
  end

  describe ".drop!" do
    it "drops embedding insert triggers" do
      described_class.drop!

      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_entities_embedding_bi")
      expect(conn).to have_received(:execute).with("DROP TRIGGER IF EXISTS trg_memory_observations_embedding_bi")
    end
  end
end
