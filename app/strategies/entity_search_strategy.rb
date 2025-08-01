# frozen_string_literal: true

# Strategy class for searching MemoryEntity records with relevance ranking
#
# This strategy:
# - Splits query into tokens separated by spaces
# - Searches name, entity_type, and aliases fields
# - Ranks results by number of matching tokens and field priority (entity_type > name > aliases)
# - Returns results ordered by relevance score (highest first), then by entity_type
class EntitySearchStrategy
  # Result struct to hold entity data with relevance score
  SearchResult = Struct.new(:entity, :score, :matched_fields) do
    def to_h
      {
        entity_id: entity.id,
        name: entity.name,
        entity_type: entity.entity_type,
        aliases: entity.aliases,
        memory_observations_count: entity.memory_observations_count,
        created_at: entity.created_at.iso8601,
        updated_at: entity.updated_at.iso8601,
        relevance_score: score,
        matched_fields: matched_fields
      }
    end
  end

  # Field weights for relevance scoring (higher values = more important)
  FIELD_WEIGHTS = {
    entity_type: 15,  # Highest weight for entity type matches (parent category)
    name: 10,         # High weight for name matches
    aliases: 5        # Lower weight for alias matches
  }.freeze

  # Minimum score threshold to include in results
  MIN_SCORE_THRESHOLD = 1

  # Regex to split strings into words, handling commas and spaces
  WORD_SPLIT_REGEX = /[\s,|]+/

  def initialize
    @logger = Rails.logger
  end

  # Main search method
  # @param query [String] The search query to process
  # @param limit [Integer] Maximum number of results to return (default: 50)
  # @return [Array<SearchResult>] Array of search results ordered by relevance
  def search(query, limit: 50)
    return [] if query.blank?

    tokens = tokenize_query(query)
    return [] if tokens.empty?

    @logger.info "EntitySearchStrategy: Searching for tokens: #{tokens.inspect}"

    # Get all potential matches
    entities = fetch_candidate_entities(tokens)

    # Score and rank results
    scored_results = score_and_rank_entities(entities, tokens)

    # Filter by minimum score and limit results
    scored_results
      .select { |result| result.score >= MIN_SCORE_THRESHOLD }
      .first(limit)
  end

  private

  # Tokenize the query string into searchable tokens
  # @param query [String] The input query
  # @return [Array<String>] Array of normalized tokens
  def tokenize_query(query)
    query.to_s.strip
         .downcase
         .split(/\s+/)
         .reject(&:blank?)
         .uniq
  end

  # Fetch entities that potentially match any of the tokens
  # Uses LIKE queries for broad matching, then scores in Ruby for precision
  # @param tokens [Array<String>] The search tokens
  # @return [ActiveRecord::Relation] Entities that might match
  def fetch_candidate_entities(tokens)
    conditions = []
    params = []

    tokens.each do |token|
      like_token = "%#{token}%"
      conditions << "(LOWER(name) LIKE ? OR LOWER(entity_type) LIKE ? OR LOWER(aliases) LIKE ?)"
      params += [ like_token, like_token, like_token ]
    end

    where_clause = conditions.join(" OR ")
    MemoryEntity.where(where_clause, *params)
  end

  # Score and rank entities based on token matches
  # @param entities [ActiveRecord::Relation] Candidate entities
  # @param tokens [Array<String>] Search tokens
  # @return [Array<SearchResult>] Scored and ranked results
  def score_and_rank_entities(entities, tokens)
    results = entities.map do |entity|
      score, matched_fields = calculate_entity_score(entity, tokens)
      SearchResult.new(entity, score, matched_fields)
    end

    # Sort by score (descending), then by entity_type (alphabetically), then by name (ascending)
    results.sort_by { |result| [ -result.score, result.entity.entity_type.to_s.downcase, result.entity.name.to_s.downcase ] }
  end

  # Calculate relevance score for a single entity
  # @param entity [MemoryEntity] The entity to score
  # @param tokens [Array<String>] Search tokens
  # @return [Array<Float, Array<String>>] Score and list of matched fields
  def calculate_entity_score(entity, tokens)
    score = 0.0
    matched_fields = []

    name_lower = entity.name.to_s.downcase
    entity_type_lower = entity.entity_type.to_s.downcase
    aliases_lower = entity.aliases.to_s.downcase

    tokens.each do |token|
      # Check entity_type matches (highest priority)
      if entity_type_lower.include?(token)
        score += FIELD_WEIGHTS[:entity_type]
        matched_fields << "entity_type"

        # Bonus for exact word matches in entity_type
        if entity_type_lower.split(WORD_SPLIT_REGEX).include?(token)
          score += FIELD_WEIGHTS[:entity_type] * 0.5
        end
      end

      # Check name matches
      if name_lower.include?(token)
        score += FIELD_WEIGHTS[:name]
        matched_fields << "name"

        # Bonus for exact word matches in name
        if name_lower.split(WORD_SPLIT_REGEX).include?(token)
          score += FIELD_WEIGHTS[:name] * 0.5
        end
      end

      # Check aliases matches
      if aliases_lower.include?(token)
        score += FIELD_WEIGHTS[:aliases]
        matched_fields << "aliases"

        # Bonus for exact word matches in aliases
        if aliases_lower.split(WORD_SPLIT_REGEX).include?(token)
          score += FIELD_WEIGHTS[:aliases] * 0.5
        end
      end
    end

    # Bonus for matching multiple tokens
    if tokens.length > 1
      matched_token_count = tokens.count do |token|
        entity_type_lower.include?(token) || name_lower.include?(token) || aliases_lower.include?(token)
      end

      if matched_token_count > 1
        score += (matched_token_count - 1) * 3  # 3 point bonus per additional token
      end
    end

    [ score, matched_fields.uniq ]
  end
end
