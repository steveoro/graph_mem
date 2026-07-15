# frozen_string_literal: true

class DetectContradictionsTool < ApplicationTool
  def self.tool_name
    "detect_contradictions"
  end

  description "Scans an entity's active observations (and observations from 1-hop related entities) for pairs that are semantically similar but have opposite polarity. " \
    "Candidate contradictions are returned and stored as a MaintenanceReport for operator review."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to scan for contradictions.")
    optional(:max_distance).filled(:float).description("Maximum cosine distance threshold (smaller = stricter). Defaults to 0.35.")
    optional(:max_results).filled(:integer).description("Maximum candidate pairs to return. Defaults to 20.")
  end

  def call(entity_id:, max_distance: 0.35, max_results: 20)
    logger.info "Performing DetectContradictionsTool with entity_id: #{entity_id}"
    begin
      entity = MemoryEntity.find(entity_id)
      pairs = ContradictionDetector.detect(
        entity_id,
        max_distance: max_distance,
        max_results: max_results,
        persist: true
      )

      {
        entity_id: entity.id,
        name: entity.name,
        candidate_count: pairs.length,
        candidates: pairs.map do |p|
          {
            observation_id_1: p.observation_id_1,
            observation_id_2: p.observation_id_2,
            distance: p.distance,
            confidence: p.confidence
          }
        end
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in DetectContradictionsTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue StandardError => e
      logger.error "InternalServerError in DetectContradictionsTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in DetectContradictionsTool: #{e.message}"
    end
  end
end
