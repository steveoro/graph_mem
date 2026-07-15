# frozen_string_literal: true

class FindShortestPathTool < ApplicationTool
  def self.tool_name
    "find_shortest_path"
  end

  description "Finds the shortest path (by hop count) between two entities using bounded " \
    "breadth-first search. Returns the ordered entities and relations along the path, or " \
    "found: false when no path exists within max_depth."

  arguments do
    required(:from_entity_id).filled(:integer).description("The ID of the source entity. Also accepts entity name (string).")
    required(:to_entity_id).filled(:integer).description("The ID of the target entity. Also accepts entity name (string).")
    optional(:max_depth).filled(:integer).description("Maximum number of hops to search. Default #{GraphTraversalService::DEFAULT_MAX_DEPTH}, max #{GraphTraversalService::MAX_DEPTH}.")
    optional(:direction).filled(:string).description("Traversal direction: one of #{GraphTraversalService::DIRECTIONS.join(', ')}. Default #{GraphTraversalService::DEFAULT_DIRECTION}.")
    optional(:relation_types).array(:string).description("Optional: restrict traversal to these relation types (canonicalized).")
  end

  def tool_output_schema
    {
      type: :object,
      properties: {
        found: { type: :boolean },
        hop_count: { type: [ :integer, :null ] },
        direction: { type: :string },
        entities: { type: :array, items: GraphTraversalToolSchema.entity },
        relations: { type: :array, items: GraphTraversalToolSchema.relation }
      },
      required: [ :found, :hop_count, :direction, :entities, :relations ]
    }
  end

  def call(from_entity_id:, to_entity_id:, max_depth: nil, direction: nil, relation_types: nil)
    logger.info "Performing FindShortestPathTool from #{from_entity_id} to #{to_entity_id}"
    begin
      result = GraphTraversalService.new.shortest_path(
        from_entity_id: from_entity_id,
        to_entity_id: to_entity_id,
        max_depth: max_depth || GraphTraversalService::DEFAULT_MAX_DEPTH,
        direction: direction || GraphTraversalService::DEFAULT_DIRECTION,
        relation_types: relation_types
      )

      case result
      when :missing_from
        raise McpGraphMemErrors::ResourceNotFound, "Entity with ID=#{from_entity_id} not found."
      when :missing_to
        raise McpGraphMemErrors::ResourceNotFound, "Entity with ID=#{to_entity_id} not found."
      else
        GraphTraversalSerializer.path(result)
      end
    rescue McpGraphMemErrors::ResourceNotFound
      raise
    rescue StandardError => e
      logger.error "InternalServerError in FindShortestPathTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in FindShortestPathTool: #{e.message}"
    end
  end
end
