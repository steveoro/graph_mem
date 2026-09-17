# frozen_string_literal: true

class DetectContradictionsTool < ApplicationTool
  def self.tool_name
    "detect_contradictions"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Scan an entity's active observations and 1-hop related observations for semantically similar pairs with " \
    "opposite polarity; returns candidates and stores a contradictions MaintenanceReport. Pass required `entity_id` " \
    "(integer; also accepts entity name); optional `max_distance` (float, default 0.35), `max_results` (integer, default 20). " \
    "Does not merge or delete. Do not use for trust ranking; use `rank_observations` instead. " \
    "Do not use for duplicate entities; use `suggest_merges` instead. " \
    "Do not use to read stored reports; use `get_maintenance_reports` instead. " \
    "Do not use to resolve a conflicting fact; use `update_observation` or `delete_observation` instead."

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
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search` to find the entity, then retry `detect_contradictions`."
      )
    rescue StandardError => e
      raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }

      logger.error "InternalServerError in DetectContradictionsTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
