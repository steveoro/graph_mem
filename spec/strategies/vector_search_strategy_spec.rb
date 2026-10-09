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
        allow(relation).to receive(:where).and_return(relation)
        allow(relation).to receive(:select) do |sql_str|
          expect(sql_str).to include("VEC_DISTANCE_COSINE")
          expect(sql_str).to include("VEC_FromText")
          relation
        end
        allow(relation).to receive(:having).and_return(relation)
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([])

        strategy.search("test query")
      end

      it "applies a cosine distance quality gate via HAVING clause" do
        relation = double("relation")
        allow(MemoryEntity).to receive(:where).and_return(relation)
        allow(relation).to receive(:not).and_return(relation)
        allow(relation).to receive(:where).and_return(relation)
        allow(relation).to receive(:select).and_return(relation)
        allow(relation).to receive(:having) do |clause, threshold|
          expect(clause).to include("vec_distance")
          expect(threshold).to eq(described_class::MAX_COSINE_DISTANCE)
          relation
        end
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([])

        strategy.search("test query")
      end

      it "filters by entity_type when provided" do
        relation = double("relation")
        allow(MemoryEntity).to receive(:where).and_return(relation)
        allow(relation).to receive(:not).and_return(relation)
        allow(relation).to receive(:where).with(entity_type: "Task").and_return(relation)
        allow(relation).to receive(:select).and_return(relation)
        allow(relation).to receive(:having).and_return(relation)
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([])

        strategy.search("test query", entity_type: "Task")

        expect(relation).to have_received(:where).with(entity_type: "Task")
      end

      it "does not add an entity_type predicate when none is given" do
        relation = double("relation")
        allow(MemoryEntity).to receive(:where).and_return(relation)
        allow(relation).to receive(:not).and_return(relation)
        allow(relation).to receive(:where)
        allow(relation).to receive(:select).and_return(relation)
        allow(relation).to receive(:having).and_return(relation)
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([])

        strategy.search("test query")

        expect(relation).not_to have_received(:where)
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

    context "when vector search succeeds" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(embedding_service).to receive(:embed).and_return(fake_vector)
      end

      it "searches active observations only" do
        relation = double("relation")
        allow(MemoryObservation).to receive(:active).and_return(relation)
        allow(relation).to receive(:where).and_return(relation)
        allow(relation).to receive(:not).and_return(relation)
        allow(relation).to receive(:select).and_return(relation)
        allow(relation).to receive(:group).and_return(relation)
        allow(relation).to receive(:order).and_return(relation)
        allow(relation).to receive(:limit).and_return([ double("observation", memory_entity_id: 123) ])

        expect(strategy.search_observations("test")).to eq([ 123 ])
        expect(MemoryObservation).to have_received(:active)
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

  # Executes VEC_DISTANCE_COSINE against the real VECTOR column. Doubles cannot
  # catch a nil entity_type predicate or an ORDER BY alias that pluck drops.
  describe "MariaDB vector columns", :with_test_embeddings do
    let(:query_vector) { Array.new(768, 0.0).tap { |vector| vector[0] = 1.0 } }
    let(:near_vector) do
      Array.new(768, 0.0).tap do |vector|
        vector[0] = 0.9
        vector[1] = Math.sqrt(1 - 0.81)
      end
    end
    let(:orthogonal_vector) { Array.new(768, 0.0).tap { |vector| vector[1] = 1.0 } }
    let(:embedding_service) { instance_double(EmbeddingService, embed: query_vector) }
    let(:strategy) { described_class.new(embedding_service: embedding_service) }

    def store_embedding!(record, vector)
      literal = "[#{vector.join(',')}]"
      quoted = ActiveRecord::Base.connection.quote(literal)
      ActiveRecord::Base.connection.execute(
        "UPDATE #{record.class.table_name} SET embedding = VEC_FromText(#{quoted}) WHERE id = #{record.id}"
      )
    end

    describe "#search" do
      let!(:identical) { MemoryEntity.create!(name: "VecIdenticalTask", entity_type: "Task") }
      let!(:near) { MemoryEntity.create!(name: "VecNearProject", entity_type: "Project") }
      let!(:far) { MemoryEntity.create!(name: "VecFarIssue", entity_type: "Issue") }

      before do
        store_embedding!(identical, query_vector)
        store_embedding!(near, near_vector)
        store_embedding!(far, orthogonal_vector)
      end

      it "returns every typed entity under the distance gate when entity_type is omitted" do
        results = strategy.search("semantic query")

        expect(results.map { |result| result.entity.id }).to eq([ identical.id, near.id ])
        expect(results.first.distance).to be < results.last.distance
        expect(results.map(&:distance)).to all(be < described_class::MAX_COSINE_DISTANCE)
      end

      it "still restricts results to the requested entity_type" do
        results = strategy.search("semantic query", entity_type: "Task")

        expect(results.map { |result| result.entity.id }).to eq([ identical.id ])
      end
    end

    describe "#search_observations" do
      let!(:close_entity) { MemoryEntity.create!(name: "VecObsClose", entity_type: "Task") }
      let!(:far_entity) { MemoryEntity.create!(name: "VecObsFar", entity_type: "Project") }
      let!(:obsolete_entity) { MemoryEntity.create!(name: "VecObsObsolete", entity_type: "Issue") }

      before do
        close_obs = MemoryObservation.create!(memory_entity: close_entity, content: "close fact")
        far_obs = MemoryObservation.create!(memory_entity: far_entity, content: "far fact")
        obsolete_obs = MemoryObservation.create!(memory_entity: obsolete_entity, content: "obsolete fact")
        store_embedding!(close_obs, query_vector)
        store_embedding!(far_obs, orthogonal_vector)
        store_embedding!(obsolete_obs, query_vector)
        obsolete_obs.mark_obsolete!(reason: "stale")
      end

      it "returns active entity ids ordered by observation distance" do
        expect(strategy.search_observations("semantic query")).to eq([ close_entity.id, far_entity.id ])
      end
    end
  end
end
