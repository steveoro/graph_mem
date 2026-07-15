# frozen_string_literal: true

class RankObservationsTool < ApplicationTool
  def self.tool_name
    "rank_observations"
  end

  description "Returns an entity's observations sorted by trust score, with the most reliable observation first."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity whose observations should be ranked.")
    optional(:include_obsolete).filled(:bool).description("Include obsolete and superseded observations in the ranking. Defaults to false.")
    optional(:limit).filled(:integer).description("Maximum number of observations to return. Defaults to all.")
  end

  def call(entity_id:, include_obsolete: false, limit: nil)
    logger.info "Performing RankObservationsTool with entity_id: #{entity_id}"
    begin
      entity = MemoryEntity.find(entity_id)
      observations = include_obsolete ? entity.memory_observations : entity.active_memory_observations
      observations = observations.sort_by { |obs| -obs.trust_score.to_f }
      observations = observations.first(limit) if limit.present? && limit > 0

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
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue StandardError => e
      logger.error "InternalServerError in RankObservationsTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in RankObservationsTool: #{e.message}"
    end
  end
end
