# frozen_string_literal: true

class FindShortestPathTool < ApplicationTool
  def self.tool_name
    "find_shortest_path"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Find the shortest hop-count path between two entities. Pass required `from_entity_id` and " \
    "`to_entity_id` (integer; also accepts entity name); optional `max_depth` (integer, default 2, max 5), " \
    "`direction` (both|outgoing|incoming, default both), `relation_types` (array of strings). " \
    "Returns ordered path entities and relations, or found false when none exists within max_depth. " \
    "Do not use for a full neighborhood from one start; use `traverse_graph` instead. " \
    "Do not use for 1-hop filters; use `traverse_graph` instead. " \
    "Do not use for keyword lookup; use `search` instead."

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
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{from_entity_id} not found.",
          next_move: "Call `search`, then retry `find_shortest_path` with a known from_entity_id."
        )
      when :missing_to
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{to_entity_id} not found.",
          next_move: "Call `search`, then retry `find_shortest_path` with a known to_entity_id."
        )
      else
        GraphTraversalSerializer.path(result)
      end
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue StandardError => e
      logger.error "InternalServerError in FindShortestPathTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
