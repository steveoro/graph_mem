# frozen_string_literal: true

class RankObservationsTool < ApplicationTool
  def self.tool_name
    "rank_observations"
  end

  description "Return one known entity's observations sorted by trust_score (most reliable first). Pass required " \
    "`entity_id` (integer; also accepts entity name); optional `include_obsolete` (bool, default false), " \
    "`limit` (integer, default all), `query` (string; relevance then trust). " \
    "Do not use when you also need relations or entity metadata; use `get_entity` instead. " \
    "Do not use for opposing observation pairs; use `detect_contradictions` instead. " \
    "Do not use to find observations across entities by keyword; use `search_subgraph` instead. " \
    "Do not use for a topic answer; use `summarize` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity whose observations should be ranked.")
    optional(:include_obsolete).filled(:bool).description("Include obsolete and superseded observations in the ranking. Defaults to false.")
    optional(:limit).filled(:integer).description("Maximum number of observations to return. Defaults to all.")
    optional(:query).filled(:string).description("Optional query for relevance-ranked observations.")
  end

  def call(entity_id:, include_obsolete: false, limit: nil, query: nil)
    logger.info "Performing RankObservationsTool with entity_id: #{entity_id}"
    begin
      entity = MemoryEntity.find(entity_id)
      observations = include_obsolete ? entity.memory_observations : entity.active_memory_observations
      observations = ObservationRankingService.rank(observations, query: query, limit: limit)

      {
        entity_id: entity.id,
        name: entity.name,
        observations: observations.map do |observation|
          MemoryObservationSerializer.call(observation, content_key: :observation_content, include_entity_id: true)
        end
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in RankObservationsTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search_entities` to find the entity, then retry `rank_observations`."
      )
    rescue StandardError => e
      raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }

      logger.error "InternalServerError in RankObservationsTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
