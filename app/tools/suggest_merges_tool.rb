# frozen_string_literal: true

class SuggestMergesTool < ApplicationTool
  DEFAULT_THRESHOLD = 0.3
  DEFAULT_LIMIT = 20

  def self.tool_name
    "suggest_merges"
  end

  description "Find entities that are potential duplicates using vector similarity. " \
    "Returns pairs of entities that may represent the same concept and could be merged."

  arguments do
    optional(:threshold).filled(:float)
      .description("Maximum cosine distance to consider as a potential duplicate (0.0 = identical, 1.0 = unrelated). Default: #{DEFAULT_THRESHOLD}.")
    optional(:limit).filled(:integer)
      .description("Maximum number of merge suggestions to return. Default: #{DEFAULT_LIMIT}.")
    optional(:entity_type).maybe(:string)
      .description("Filter suggestions to a specific entity type (e.g., 'Project').")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: {
        threshold: { type: "number", description: "Max cosine distance (0-1). Default: #{DEFAULT_THRESHOLD}." },
        limit: { type: "integer", description: "Max suggestions. Default: #{DEFAULT_LIMIT}." },
        entity_type: { type: [ "string", "null" ], description: "Filter by entity type." }
      },
      required: []
    }
  end

  def call(threshold: nil, limit: nil, entity_type: nil)
    effective_threshold = threshold || DEFAULT_THRESHOLD
    effective_limit = limit || DEFAULT_LIMIT

    scope = MemoryEntity.where.not(embedding: nil)
    scope = scope.where(entity_type: entity_type) if entity_type.present?

    entities = scope.to_a
    suggestions = []

    entities.each_with_index do |entity, i|
      break if suggestions.length >= effective_limit

      vector_sql = entity.embedding
      next if vector_sql.blank?

      candidates = MemoryEntity
        .where.not(id: entity.id)
        .where.not(embedding: nil)
        .where("id > ?", entity.id)
        .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, (SELECT embedding FROM memory_entities WHERE id = #{entity.id})) AS vec_distance")
        .having("vec_distance < ?", effective_threshold)
        .order(Arel.sql("vec_distance ASC"))
        .limit(3)

      candidates.each do |candidate|
        suggestions << {
          entity_a: { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type },
          entity_b: { entity_id: candidate.id, name: candidate.name, entity_type: candidate.entity_type },
          cosine_distance: candidate[:vec_distance].to_f.round(4),
          recommendation: candidate[:vec_distance].to_f < 0.15 ? "high_confidence_merge" : "review_manually"
        }
        break if suggestions.length >= effective_limit
      end
    end

    {
      suggestions: suggestions,
      total: suggestions.length,
      threshold_used: effective_threshold
    }
  rescue StandardError => e
    logger.error "SuggestMergesTool error: #{e.message} - #{e.backtrace.first(5).join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "Failed to generate merge suggestions: #{e.message}"
  end
end
