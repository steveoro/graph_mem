# frozen_string_literal: true

# Query-scoped summarization: deterministic evidence plus optional LLM synthesis.
class SummarizerService
  DEFAULT_MAX_RESULTS = 10
  DEFAULT_MAX_OBSERVATIONS = 20
  DEFAULT_OBSERVATIONS_PER_ENTITY = 3
  DEFAULT_MAX_DEPTH = 0
  DEFAULT_STYLE = "concise"
  SCOPES = %w[context global].freeze
  CONTEXT_SEARCH_OVERSAMPLE = 5

  class << self
    def call(**kwargs)
      new(**kwargs).call
    end
  end

  def initialize(query:, entity_id: nil, max_results: DEFAULT_MAX_RESULTS,
                 max_observations: DEFAULT_MAX_OBSERVATIONS,
                 observations_per_entity: nil, max_depth: DEFAULT_MAX_DEPTH,
                 include_sources: true, style: DEFAULT_STYLE, scope: nil,
                 context_entity_ids: nil, context_scope: nil)
    @query = query.to_s.strip
    @entity_id = entity_id
    @max_results = normalize_positive(max_results, DEFAULT_MAX_RESULTS, max: 50)
    @max_observations = normalize_positive(max_observations, DEFAULT_MAX_OBSERVATIONS, max: 100)
    @observations_per_entity = normalize_per_entity_cap(
      observations_per_entity,
      SummarizationConfig.resolved_config[:observations_per_entity]
    )
    @max_depth = normalize_depth(max_depth)
    @include_sources = include_sources != false
    @style = style.presence || DEFAULT_STYLE
    @context_entity_ids = Array(context_entity_ids).compact
    @context_scope = context_scope
    @allowed_entity_ids = entity_scope? ? nil : @context_entity_ids.presence
    @scope = normalize_scope(scope)
    @candidate_entity_count = 0
    @excluded_out_of_scope_count = 0
    @logger = Rails.logger
  end

  def call
    raise ArgumentError, "query is required" if @query.blank?

    entities, entity_scores = fetch_entities
  rescue ActiveRecord::RecordNotFound
    raise
  else
    evidence = build_evidence(entities, entity_scores)
    response = build_deterministic_response(entities, evidence)
    attempt_llm_synthesis(response, evidence)
  end

  private

  def entity_scope?
    @entity_id.present?
  end

  def normalize_scope(scope)
    value = scope.to_s.strip.downcase.presence
    if value.blank?
      return @allowed_entity_ids.present? ? "context" : "global"
    end

    raise ArgumentError, "scope must be context or global" unless SCOPES.include?(value)
    raise ArgumentError, "scope context requires an active project context" if value == "context" && @allowed_entity_ids.blank?

    value
  end

  # Returns unique entities with the corresponding scores
  def fetch_entities
    if entity_scope?
      entity = MemoryEntity.find(@entity_id)
      @candidate_entity_count = 1
      return [ [ entity ], { entity.id => 1.0 } ]
    end

    search_limit = @scope == "context" ? @max_results * CONTEXT_SEARCH_OVERSAMPLE : @max_results
    results = HybridSearchStrategy.new.search(
      @query,
      limit: search_limit,
      semantic: true,
      context_entity_ids: @context_entity_ids.presence,
      scope_entity_ids: (@scope == "context" ? @allowed_entity_ids : nil)
    )

    @candidate_entity_count = results.size
    results = apply_scope_filter(results)

    entity_scores = results.to_h { |result| [ result.entity.id, result.score.to_f ] }
    entities = results.map(&:entity)

    if @max_depth.positive? && entities.any?
      entities, entity_scores = expand_entities(entities, entity_scores)
    end

    [ entities.uniq, entity_scores ]
  end

  def apply_scope_filter(results)
    return results.first(@max_results) unless @scope == "context" && @allowed_entity_ids.present?

    allowed = @allowed_entity_ids.to_set
    in_scope, out_of_scope = results.partition { |result| allowed.include?(result.entity.id) }
    @excluded_out_of_scope_count = out_of_scope.size
    in_scope.first(@max_results)
  end

  # Expand entities by traversing the graph, collecting the overall scores
  def expand_entities(entities, entity_scores)
    expanded_ids = entities.map(&:id).to_set
    traversal = GraphTraversalService.new

    entities.first(@max_results).each do |entity|
      result = traversal.expand(
        start_entity_id: entity.id,
        max_depth: @max_depth,
        max_entities: @max_results
      )
      next unless result

      result.entity_ids.each do |entity_id|
        next if expanded_ids.include?(entity_id)
        next if @scope == "context" && @allowed_entity_ids.present? && !@allowed_entity_ids.include?(entity_id)

        expanded_ids << entity_id
        entity_scores[entity_id] ||= entity_scores[entity.id].to_f * 0.8
      end
    end

    expanded_entities = MemoryEntity.where(id: expanded_ids.to_a).to_a
    [ expanded_entities, entity_scores ]
  end

  # Build evidence from observations, ranked by query relevance, entity relevance, and quality
  def build_evidence(entities, entity_scores)
    ranker = ObservationRelevanceRanker.new(@query)
    observations = entities.flat_map do |entity|
      entity.active_memory_observations.map do |observation|
        {
          observation: observation,
          entity: entity,
          entity_relevance: entity_scores[entity.id].to_f
        }
      end
    end

    query_scores = ranker.score_batch(observations.map { |entry| entry[:observation] })
    observations.each_with_index do |entry, index|
      entry[:query_relevance] = query_scores[index].to_f.round(4)
    end

    ranked = observations.sort_by do |entry|
      observation = entry[:observation]
      [
        -entry[:query_relevance],
        -entry[:entity_relevance],
        -observation.trust_score.to_f,
        -(observation.confidence || 0.0),
        observation.id
      ]
    end

    selected = select_diverse_evidence(ranked)
    mark_contradictions(selected)
    selected
  end

  def mark_contradictions(selected)
    return unless EmbeddingService.vector_enabled?

    ids = selected.map { |entry| entry[:observation].id }
    selected.each do |entry|
      entry[:has_contradiction] = contradiction_partner_ids(entry[:observation], ids).any?
    end
  end

  def contradiction_partner_ids(observation, candidate_ids)
    return [] unless observation.embedding.present?

    partners = MemoryObservation
      .active
      .where(id: candidate_ids)
      .where.not(id: observation.id)
      .where.not(embedding: nil)
      .select(
        :id,
        :content,
        Arel.sql("VEC_DISTANCE_COSINE(embedding, (SELECT o2.embedding FROM memory_observations o2 WHERE o2.id = #{observation.id})) AS vec_distance")
      )
      .having("vec_distance < ?", ContradictionDetector::DEFAULT_MAX_DISTANCE)
      .limit(5)

    partners.filter_map do |partner|
      next unless polarity_conflict?(observation.content, partner.content)

      partner.id
    end
  end

  def polarity_conflict?(text1, text2)
    neg1 = negative?(text1)
    neg2 = negative?(text2)
    neg1 != neg2
  end

  def negative?(text)
    return false if text.blank?

    words = text.downcase.scan(/\b[\w']+\b/)
    ContradictionDetector::NEGATIVE_MARKERS.any? { |marker| words.include?(marker) }
  end

  # Build deterministic response from evidence regarding each entity
  def build_deterministic_response(entities, evidence)
    observations_payload = evidence.map do |entry|
      payload = MemoryObservationSerializer.call(
        entry[:observation],
        id_key: :id,
        content_key: :content,
        include_entity_id: true
      )
      payload[:entity_name] = entry[:entity].name
      payload[:entity_relevance] = entry[:entity_relevance].round(4)
      payload[:query_relevance] = entry[:query_relevance]
      payload[:has_contradiction] = entry[:has_contradiction] == true
      payload
    end

    {
      query: @query,
      summary: build_deterministic_summary(evidence),
      generation_mode: "deterministic",
      generated_by: "deterministic",
      fallback_reason: nil,
      scope: @scope,
      entity_count: entities.map(&:id).uniq.size,
      observation_count: observations_payload.size,
      observations: observations_payload,
      sources: build_sources(evidence),
      retrieval: build_retrieval_diagnostics(entities, evidence)
    }
  end

  def build_deterministic_summary(evidence)
    return empty_scope_message if evidence.empty?

    grouped = evidence.group_by { |entry| entry[:entity] }
    sections = grouped.map do |entity, entries|
      facts = entries.map do |entry|
        observation = entry[:observation]
        suffix = entry[:has_contradiction] ? " [possible contradiction]" : ""
        "  - [observation_id=#{observation.id}] #{observation.content}#{suffix}"
      end

      "#{entity.name}:\n#{facts.join("\n")}"
    end

    sections.join("\n\n")
  end

  def empty_scope_message
    if @scope == "context"
      "No active evidence found for \"#{@query}\" within the active project scope."
    else
      "No active evidence found for \"#{@query}\"."
    end
  end

  def build_sources(evidence)
    return [] unless @include_sources

    evidence.map do |entry|
      {
        entity_id: entry[:entity].id,
        observation_id: entry[:observation].id
      }
    end
  end

  def build_retrieval_diagnostics(entities, evidence)
    {
      scope: @scope,
      context_entity_count: @allowed_entity_ids&.size,
      scope_truncated: @context_scope&.truncated == true,
      scope_max_entities: @context_scope&.max_entities,
      candidate_entity_count: @candidate_entity_count,
      selected_entity_count: entities.map(&:id).uniq.size,
      excluded_out_of_scope_count: @excluded_out_of_scope_count,
      selected_observation_count: evidence.size
    }
  end

  def attempt_llm_synthesis(response, evidence)
    unless SummarizationConfig.llm_usable?
      response[:fallback_reason] = fallback_reason_for_disabled
      return response
    end

    prompt = build_prompt(evidence)
    result = SummaryGenerationClient.generate(prompt, style: @style)

    if result[:ok]
      response[:summary] = result[:text]
      response[:generation_mode] = "llm"
      response[:generated_by] = SummarizationConfig.resolved_config[:model]
      response[:fallback_reason] = nil
      return response
    end

    response[:fallback_reason] = result[:error] || "provider_unavailable"
    response
  end

  def fallback_reason_for_disabled
    config = SummarizationConfig.resolved_config
    return "disabled" unless config[:llm_enabled]
    return "unconfigured" if config[:url].blank? || config[:model].blank?
    return "unconfigured" unless SummarizationConfig.valid_provider?(config[:provider])

    "provider_unavailable"
  end

  def build_prompt(evidence)
    lines = [
      "Query: #{@query}",
      "Style: #{@style}",
      "Scope: #{@scope}",
      "",
      "Write a #{@style} summary using only the observations below.",
      "Use this structure:",
      "1. One short overview paragraph.",
      "2. Bullet points grouped by entity when helpful.",
      "3. End with a Sources line listing observation_id values you used.",
      "",
      "Rules:",
      "- Do not invent facts, acronym expansions, or entities.",
      "- Mention uncertainty only when an observation is marked [possible contradiction].",
      "- Do not ask follow-up questions.",
      ""
    ]

    if evidence.empty?
      lines << "No observations were retrieved. Reply that no active evidence was found for this query."
    else
      evidence.each do |entry|
        observation = entry[:observation]
        entity = entry[:entity]
        contradiction = entry[:has_contradiction] ? " [possible contradiction]" : ""
        lines << "- [observation_id=#{observation.id}, entity_id=#{entity.id}, entity=#{entity.name}]#{contradiction} #{observation.content}"
      end
    end

    lines.join("\n")
  end

  def select_diverse_evidence(ranked)
    selected = []
    counts = Hash.new(0)

    ranked.each do |entry|
      break if selected.size >= @max_observations

      entity_id = entry[:entity].id
      next if @observations_per_entity.positive? && counts[entity_id] >= @observations_per_entity

      selected << entry
      counts[entity_id] += 1
    end

    selected
  end

  def normalize_positive(value, default, max:)
    parsed = value.to_i
    return default if parsed <= 0

    [ parsed, max ].min
  end

  def normalize_per_entity_cap(value, default, max: 100)
    return default if value.nil? || value.to_s.strip == ""

    parsed = value.to_i
    return default if parsed.negative?

    [ parsed, max ].min
  end

  def normalize_depth(value)
    parsed = value.to_i
    return 0 if parsed.negative?

    [ parsed, GraphTraversalService::MAX_DEPTH ].min
  end
end
