# frozen_string_literal: true

class TraverseGraphTool < ApplicationTool
  def self.tool_name
    "traverse_graph"
  end

  description "Performs a bounded, multi-hop breadth-first traversal starting from an entity. " \
    "Returns the reachable entities (with observations) and the relations connecting them, " \
    "with configurable depth, direction, relation-type filtering, and an entity cap."

  arguments do
    required(:start_entity_id).filled(:integer).description("The ID of the entity to start traversal from. Also accepts entity name (string).")
    optional(:max_depth).filled(:integer).description("Maximum number of hops to expand. Default #{GraphTraversalService::DEFAULT_MAX_DEPTH}, max #{GraphTraversalService::MAX_DEPTH}.")
    optional(:direction).filled(:string).description("Traversal direction: one of #{GraphTraversalService::DIRECTIONS.join(', ')}. Default #{GraphTraversalService::DEFAULT_DIRECTION}.")
    optional(:relation_types).array(:string).description("Optional: restrict traversal to these relation types (canonicalized).")
    optional(:max_entities).filled(:integer).description("Maximum number of entities to return. Default #{GraphTraversalService::DEFAULT_MAX_ENTITIES}, max #{GraphTraversalService::MAX_ENTITIES}.")
  end

  def tool_output_schema
    {
      type: :object,
      properties: {
        entities: { type: :array, items: GraphTraversalToolSchema.entity },
        relations: { type: :array, items: GraphTraversalToolSchema.relation },
        traversal: {
          type: :object,
          properties: {
            start_entity_id: { type: :integer },
            max_depth: { type: :integer },
            direction: { type: :string },
            visited_depth: { type: :integer },
            truncated: { type: :boolean }
          },
          required: [ :start_entity_id, :max_depth, :direction, :visited_depth, :truncated ]
        }
      },
      required: [ :entities, :relations, :traversal ]
    }
  end

  def call(start_entity_id:, max_depth: nil, direction: nil, relation_types: nil, max_entities: nil)
    logger.info "Performing TraverseGraphTool from #{start_entity_id} (depth=#{max_depth}, direction=#{direction})"
    begin
      result = GraphTraversalService.new.expand(
        start_entity_id: start_entity_id,
        max_depth: max_depth || GraphTraversalService::DEFAULT_MAX_DEPTH,
        direction: direction || GraphTraversalService::DEFAULT_DIRECTION,
        relation_types: relation_types,
        max_entities: max_entities || GraphTraversalService::DEFAULT_MAX_ENTITIES
      )

      if result.nil?
        raise McpGraphMemErrors::ResourceNotFound, "Entity with ID=#{start_entity_id} not found."
      end

      GraphTraversalSerializer.traversal(result)
    rescue McpGraphMemErrors::ResourceNotFound
      raise
    rescue StandardError => e
      logger.error "InternalServerError in TraverseGraphTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in TraverseGraphTool: #{e.message}"
    end
  end
end
