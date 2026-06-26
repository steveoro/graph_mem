# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingIndexStatus do
  describe ".indexes" do
    before do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    end

    it "returns false for each table when index is absent" do
      conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)
      allow(conn).to receive(:table_exists?).and_return(true)
      allow(conn).to receive(:quote).and_return("'idx'")
      allow(conn).to receive(:execute).and_return([])

      expect(described_class.indexes).to eq(
        memory_entities: false,
        memory_observations: false
      )
    end
  end
end
