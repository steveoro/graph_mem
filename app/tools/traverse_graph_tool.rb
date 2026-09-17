# frozen_string_literal: true

class TraverseGraphTool < ApplicationTool
  def self.tool_name
    "traverse_graph"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Perform a bounded multi-hop BFS from one start entity and return reachable entities (with observations) " \
    "and connecting relations. Pass required `start_entity_id` (integer; also accepts entity name); optional " \
    "`max_depth` (integer, default 2, max 5), `direction` (both|outgoing|incoming, default both), " \
    "`relation_types` (array of strings), `max_entities` (integer, default 100, max 1000). " \
    "Do not use for keyword search; use `search_subgraph` instead. " \
    "Do not use for the shortest path between two ids; use `find_shortest_path` instead. " \
    "Do not use for a 1-hop edge list; use `find_relations` instead. " \
    "Do not use for an explicit id set with no expansion; use `get_subgraph_by_ids` instead."

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
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{start_entity_id} not found.",
          next_move: "Call `search_entities`, then retry `traverse_graph` with a known start_entity_id."
        )
      end

      GraphTraversalSerializer.traversal(result)
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue StandardError => e
      logger.error "InternalServerError in TraverseGraphTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
