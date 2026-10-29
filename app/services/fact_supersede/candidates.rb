# frozen_string_literal: true

module FactSupersede
  # Finds the observations a source fact may outdate. No LLM call. Scope first, then signals:
  #
  # - scope (hard): observations of entities in the fact's project (members and the root),
  #   excluding the fact and every other fact-tagged row; active only unless `include_inactive`
  #   (the bulk page lists inactive rows for viewing). Entities without a project that are
  #   related to the fact's entity are included as unscoped (shown with a warning, never
  #   auto-applied). Other projects are never searched.
  # - vector: one VEC_DISTANCE_COSINE query against the fact's embedding (when vectors are on
  #   and the fact is embedded), within the fact_supersede_max_distance review number;
  # - terms: an escaped LIKE per term (the operator's query, the fact's replaces: tags, the
  #   caller's terms; at most SourceFact::MAX_TERMS);
  # - polarity: ContradictionDetector.negative? on both sides is a +0.1 boost, never a filter.
  #
  #   result = FactSupersede::Candidates.call(fact, terms: ["fast-mcp"])
  #   result.candidates.first # => #<struct Candidate observation=…, score=0.6, term="fast-mcp", scoped=true, …>
  #   result.vector           # => false (similarity search off: term match only)
  class Candidates
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    TERM_SCORE = 0.6
    POLARITY_BOOST = 0.1
    MAX_SCORE = 0.99

    # @!attribute candidates [Array<Candidate>] by score desc, then id
    # @!attribute terms [Array<String>] the terms that were searched
    # @!attribute vector [Boolean] whether the vector query ran
    # @!attribute project_id [Integer, nil] the fact's project
    Result = Data.define(:candidates, :terms, :vector, :project_id)

    # @param fact [MemoryObservation] an active source fact
    # @param query [String, nil] the operator's search text (one more term)
    # @param terms [Array<String>] more terms (the MCP tool's `terms`)
    # @param limit [Integer] 1-MAX_LIMIT
    # @param include_inactive [Boolean] list inactive rows too (for viewing only)
    # @return [Result] empty when `fact` is not a source fact
    def self.call(fact, query: nil, terms: [], limit: DEFAULT_LIMIT, include_inactive: false)
      new(fact, query: query, terms: terms, limit: limit, include_inactive: include_inactive).call
    end

    def initialize(fact, query:, terms:, limit:, include_inactive:)
      @fact = fact
      @terms = SourceFact.normalize_terms([ query, *terms, *fact.replaces_terms ])
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @include_inactive = include_inactive
    end

    # @return [Result]
    def call
      return Result.new(candidates: [], terms: @terms, vector: false, project_id: nil) unless @fact.source_fact?

      @project_id = @fact.fact_project_id
      distances = vector_distances
      hits = term_hits
      ids = distances.keys | hits.keys
      candidates = scope.where(id: ids).includes(:memory_entity).map { |observation| candidate(observation, distances, hits) }
      candidates = candidates.sort_by { |entry| [ -entry.score, entry.observation.id ] }.first(@limit)
      Result.new(candidates: candidates, terms: @terms, vector: vector_usable?, project_id: @project_id)
    end

    private

    def candidate(observation, distances, hits)
      distance = distances[observation.id]
      flip = ContradictionDetector.negative?(@fact.content) != ContradictionDetector.negative?(observation.content)
      score = [ distance ? 1.0 - distance : 0.0, hits[observation.id] ? TERM_SCORE : 0.0 ].max
      score += POLARITY_BOOST if flip
      Candidate.new(observation: observation, score: [ score, MAX_SCORE ].min.round(3), distance: distance, term: hits[observation.id],
                    polarity_flip: flip, scoped: scoped_entity?(observation.memory_entity))
    end

    def scoped_entity?(entity)
      entity.project_id == @project_id || entity.id == @project_id
    end

    def scope
      @scope ||= begin
        members = MemoryEntity.where(project_id: @project_id).or(MemoryEntity.where(id: @project_id)).select(:id)
        relation = MemoryObservation.where(memory_entity_id: members).or(MemoryObservation.where(memory_entity_id: unscoped_entity_ids))
                                    .where.not(id: @fact.id)
                                    .where("NOT JSON_CONTAINS(memory_observations.tags, ?)", [ SourceFact::SOURCE_FACT_TAG ].to_json)
        @include_inactive ? relation : relation.active
      end
    end

    # Entities without a project (never a Project root: that is another project) related to the
    # fact's entity in either direction.
    def unscoped_entity_ids
      @unscoped_entity_ids ||= begin
        entity_id = @fact.memory_entity_id
        related = MemoryRelation.where(from_entity_id: entity_id).pluck(:to_entity_id) +
                  MemoryRelation.where(to_entity_id: entity_id).pluck(:from_entity_id)
        MemoryEntity.where(id: related.uniq, project_id: nil).where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).pluck(:id)
      end
    end

    # The stamp is read from the row: store_vector writes it without touching loaded records.
    def vector_usable?
      return @vector_usable if defined?(@vector_usable)

      @vector_usable = EmbeddingService.vector_enabled? && MemoryObservation.with_embedding.exists?(id: @fact.id)
    end

    # @return [Hash{Integer => Float}] cosine distance per observation id ({} when vectors are off)
    def vector_distances
      return {} unless vector_usable?

      distance_sql = MemoryObservation.sanitize_sql_array(
        [ "VEC_DISTANCE_COSINE(memory_observations.embedding, (SELECT o2.embedding FROM memory_observations o2 WHERE o2.id = ?)) AS vec_distance", @fact.id ]
      )
      scope.with_embedding.select(:id, Arel.sql(distance_sql))
           .having("vec_distance < ?", AppSettings.review_number(:fact_supersede_max_distance))
           .order(Arel.sql("vec_distance ASC"), :id).limit(MAX_LIMIT)
           .to_h { |row| [ row.id, row[:vec_distance].to_f ] }
    end

    # @return [Hash{Integer => String}] the first matching term per observation id
    def term_hits
      @terms.each_with_object({}) do |term, hits|
        like = "%#{MemoryObservation.sanitize_sql_like(term)}%"
        scope.where("memory_observations.content LIKE ?", like).order(:id).limit(MAX_LIMIT).pluck(:id).each { |id| hits[id] ||= term }
      end
    end
  end
end
