# frozen_string_literal: true

class GetEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "get_entity"
  end

  description "Retrieve a specific entity by ID, including its active observations and relations. " \
    "Accepts entity_id (integer) or entity name (string); include_obsolete exposes observation history."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to retrieve.")
    optional(:include_obsolete).filled(:bool).description("Include obsolete and superseded observations. Defaults to false.")
    optional(:include_ranked).filled(:bool).description("Sort observations by trust score descending. Defaults to false.")
    optional(:query).filled(:string).description("Optional query for relevance-ranked observations.")
    optional(:observation_limit).filled(:integer).description("Maximum observations to return per entity.")
  end

  def call(entity_id:, include_obsolete: false, include_ranked: false, query: nil, observation_limit: nil)
    logger.info "Performing GetEntityTool with entity_id: #{entity_id}"
    begin
      # Find the entity and pre-load associations for efficiency
      entity = MemoryEntity.includes(:memory_observations, :active_memory_observations, :relations_from, :relations_to)
                           .find(entity_id)
      observations = include_obsolete ? entity.memory_observations : entity.active_memory_observations
      if query.present?
        observations = ObservationRankingService.rank(observations, query: query, limit: observation_limit)
      elsif include_ranked
        observations = ObservationRankingService.rank(observations, mode: "trust", limit: observation_limit)
      elsif observation_limit.present?
        observations = ObservationRankingService.rank(observations, mode: "trust", limit: observation_limit)
      end

      # Format the output hash - return hash directly
      {
        entity_id: entity.id,
        name: entity.name,
        entity_type: entity.entity_type,
        description: entity.description,
        created_at: entity.created_at.iso8601,
        updated_at: entity.updated_at.iso8601,
        observations_truncated: observation_limit.present? && observations.size < (include_obsolete ? entity.memory_observations.size : entity.active_memory_observations.size),
        observations: observations.map do |observation|
          MemoryObservationSerializer.call(observation, content_key: :observation_content)
        end,
        relations_from: entity.relations_from.map do |rel|
          {
            relation_id: rel.id,
            to_entity_id: rel.to_entity_id,
            relation_type: rel.relation_type,
            weight: rel.weight,
            confidence: rel.confidence,
            properties: rel.properties,
            created_at: rel.created_at.iso8601,
            updated_at: rel.updated_at.iso8601
            # Include to_entity details here if desired
          }
        end,
        relations_to: entity.relations_to.map do |rel|
          {
            relation_id: rel.id,
            from_entity_id: rel.from_entity_id,
            relation_type: rel.relation_type,
            weight: rel.weight,
            confidence: rel.confidence,
            properties: rel.properties,
            created_at: rel.created_at.iso8601,
            updated_at: rel.updated_at.iso8601
            # Include from_entity details here if desired
          }
        end
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in GetEntityTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue StandardError => e
      logger.error "InternalServerError in GetEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in GetEntityTool: #{e.message}"
    end
  end
end
