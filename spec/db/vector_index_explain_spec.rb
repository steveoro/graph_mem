# frozen_string_literal: true

require "rails_helper"

# Which vector queries can use the HNSW index (`key = idx_*_embedding` in EXPLAIN), on the clustered
# fixture (spec/support/vector_index_fixture.rb): step 1 of docs/plans/mariadb-vector-search-plan.md
# ("No vector query can use the index today"). Each example runs the real code, catches the
# statements that compute a vector distance and EXPLAINs them. Today none uses the index; steps 2
# and 3 flip the examples of the queries they change. MariaDB uses the index only for
# `ORDER BY VEC_DISTANCE_*(col, <constant>) LIMIT n`: the control example checks that EXPLAIN shows
# it on this fixture. Optimizer output can change between MariaDB minors (CI runs 11.8.6).
RSpec.describe "Vector queries and the HNSW index (EXPLAIN)", :with_test_embeddings do
  include_context "vector index fixture"

  let(:probe) { @fixture.probe(0) }
  let(:entity) { MemoryEntity.find(@fixture.entity_ids.first) }
  # An entity whose observations are all embedded, two or more.
  let(:fact_owner) do
    MemoryEntity.find(MemoryObservation.group(:memory_entity_id).having("COUNT(*) >= 2 AND COUNT(*) = COUNT(embedded_at)").pick(:memory_entity_id))
  end

  # The embedding service answers every call with the probe vector, below EmbeddingService#embed.
  before { allow(EmbeddingService.instance).to receive(:embed_with_retries).and_return(probe) }

  # @return [Array<String>] the vector indexes the block's distance queries use
  def index_used_by(signature, &block)
    statements = vector_distance_sql(&block)
    expect(statements.grep(signature)).not_to be_empty, "no statement matched #{signature.inspect}: #{statements.map { |sql| sql.first(200) }}"
    index_keys(statements)
  end

  it "shows the index for the raw `ORDER BY distance LIMIT k` shape (control)" do
    VectorIndexFixture::TABLES.each do |table|
      expect(index_keys([ nearest_sql(table, probe) ])).to eq([ "idx_#{table}_embedding" ])
    end
  end

  describe "VectorSearchStrategy" do
    let(:strategy) { VectorSearchStrategy.new }

    it "entity search (HAVING, ORDER BY vec_distance + 0) doesn't use the index" do
      expect(index_used_by(/vec_distance \+ 0/) { expect(strategy.search("SynthQuery", limit: 20)).not_to be_empty }).to be_empty
    end

    it "entity search with an entity_type doesn't use the index" do
      expect(index_used_by(/entity_type/) { strategy.search("SynthQuery", limit: 20, entity_type: "SynthType1") }).to be_empty
    end

    it "observation search (MIN + GROUP BY) doesn't use the index" do
      expect(index_used_by(/GROUP BY/) { expect(strategy.search_observations("SynthQuery", limit: 40)).not_to be_empty }).to be_empty
    end
  end

  it "ImportObservationDuplicateDetector (vec_distance + 0, one entity) doesn't use the index" do
    detector = ImportObservationDuplicateDetector.new(threshold: 0.1)
    expect(index_used_by(/vec_distance \+ 0/) { detector.find_duplicate(entity: fact_owner, content: "SynthFactNew") }).to be_empty
  end

  it "suggest_merges, the MCP tool (subquery vector, HAVING, one query per entity), doesn't use the index" do
    expect(index_used_by(/SELECT embedding FROM memory_entities WHERE id =/) { SuggestMergesTool.new.call(threshold: 0.3, limit: 1) }).to be_empty
  end

  describe "suggest_merges, the REST copy", type: :request do
    before { sign_in_operator } # spec/support/operator_auth_helpers.rb does it only under spec/requests/api/v1

    it "doesn't use the index" do
      keys = index_used_by(/SELECT embedding FROM memory_entities WHERE id =/) do
        get "/api/v1/maintenance/suggest_merges", params: { threshold: 0.3, limit: 1 }
      end
      expect(response).to have_http_status(:ok)
      expect(keys).to be_empty
    end
  end

  it "EntityMergeEvidence.candidates_for (literal vector, HAVING) doesn't use the index" do
    expect(index_used_by(/AS vec_distance/) { EntityMergeEvidence.candidates_for(entity) }).to be_empty
  end

  describe "the scoped checks" do
    before { AppSettings.fact_keywords_enabled = false }

    after { AppSettings.where(var: "fact_keywords_enabled").delete_all }

    it "ContradictionDetector (subquery vector, HAVING, per anchor) doesn't use the index" do
      expect(index_used_by(/o2\.id = /) { ContradictionDetector.detect(fact_owner.id, persist: false) }).to be_empty
    end

    it "FactSupersede::Candidates (subquery vector, HAVING) doesn't use the index" do
      fs_member!(fs_project!("SynthProject"), fact_owner)
      fact = fact_owner.memory_observations.first
      fact.update_columns(tags: [ SourceFact::SOURCE_FACT_TAG ])
      expect(index_used_by(/o2\.id = /) { FactSupersede::Candidates.call(fact.reload) }).to be_empty
    end

    it "SummarizerService's contradiction marks (subquery vector, HAVING, no ORDER BY) don't use the index" do
      expect(index_used_by(/o2\.id = /) { SummarizerService.call(query: "SynthQuery", entity_id: fact_owner.id) }).to be_empty
    end
  end

  it "ObservationRelevanceRanker (WHERE id IN, no ORDER BY) doesn't use the index" do
    ranker = ObservationRelevanceRanker.new("SynthQuery")
    expect(index_used_by(/`id` IN/) { ranker.score_batch(fact_owner.memory_observations.to_a) }).to be_empty
  end

  it "the pairwise distances (merge evidence, contradiction auto-resolve) don't use the index" do
    left, right = MemoryEntity.with_embedding.where(entity_type: "SynthType1").first(2)
    facts = fact_owner.memory_observations.first(2)
    keys = index_used_by(/memory_entities a, memory_entities b|memory_observations a, memory_observations b/) do
      EntityMergeEvidence.qualifies?(left, right)
      ReviewPolicies::AutoApplyContradiction.new.send(:within_distance?, facts)
    end
    expect(keys).to be_empty
  end
end
