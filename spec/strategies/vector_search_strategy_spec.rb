# frozen_string_literal: true

require "rails_helper"

RSpec.describe VectorSearchStrategy do
  let(:embedding_service) { instance_double(EmbeddingService) }
  let(:strategy) { described_class.new(embedding_service: embedding_service) }
  let(:fake_vector) { [ 0.1, 0.2, 0.3, 0.4 ] }

  describe "#search" do
    context "when vector is disabled" do
      before { allow(EmbeddingService).to receive(:vector_enabled?).and_return(false) }

      it "returns an empty array" do
        expect(strategy.search("test query")).to eq([])
      end
    end

    context "when vector is enabled but embed returns nil" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_return(nil)
      end

      it "returns an empty array" do
        expect(strategy.search("test query")).to eq([])
      end
    end

    context "when vector search raises an error" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_raise(StandardError, "DB error")
      end

      it "returns an empty array and does not raise" do
        expect { strategy.search("test query") }.not_to raise_error
        expect(strategy.search("test query")).to eq([])
      end
    end

    context "when vector search succeeds" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_return(fake_vector)
      end

      it "builds SQL with VEC_DISTANCE_COSINE and VEC_FromText" do
        relation = double("relation")
        allow(MemoryEntity).to receive(:where).and_return(relation)
        allow(relation).to receive(:not).and_return(relation)
        allow(relation).to receive(:select) do |sql_str|
          expect(sql_str).to include("VEC_DISTANCE_COSINE")
          expect(sql_str).to include("VEC_FromText")
          relation
        end
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([])

        strategy.search("test query")
      end
    end
  end

  describe "#search_observations" do
    context "when vector is disabled" do
      before { allow(EmbeddingService).to receive(:vector_enabled?).and_return(false) }

      it "returns an empty array" do
        expect(strategy.search_observations("test")).to eq([])
      end
    end

    context "when embed returns nil" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_return(nil)
      end

      it "returns an empty array" do
        expect(strategy.search_observations("test")).to eq([])
      end
    end

    context "when search_observations raises an error" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_raise(StandardError, "DB error")
      end

      it "returns an empty array and does not raise" do
        expect(strategy.search_observations("test")).to eq([])
      end
    end
  end

  describe "SearchResult struct" do
    it "stores entity and distance" do
      entity = double("entity")
      result = described_class::SearchResult.new(entity: entity, distance: 0.123)
      expect(result.entity).to eq(entity)
      expect(result.distance).to eq(0.123)
    end
  end
end
