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

  description "Traverse from one entity or query relations directly through one object-shaped response. Pass optional " \
    "`start_entity_id` for bounded BFS; `from_entity_id`, `to_entity_id`, and singular `relation_type` for edge filters; " \
    "`max_depth` (integer, default 2, max 5), `direction` (both|outgoing|incoming, default both), " \
    "`relation_types` (array of strings), `max_entities` (integer, default 100, max 1000), and `include` " \
    "(entities, relations, traversal). With no start entity, relation filters query edges directly; no filters list all edges. " \
    "Do not use for keyword search; use `search` instead. " \
    "Do not use for the shortest path between two ids; use `find_shortest_path` instead. " \
    "Do not use for an explicit id set with no expansion; use `get_entities` instead."

  arguments do
    optional(:start_entity_id).filled(:integer).description("Entity ID to start BFS from. Also accepts a name.")
    optional(:from_entity_id).filled(:integer).description("Direct edge-query source entity.")
    optional(:to_entity_id).filled(:integer).description("Direct edge-query destination entity.")
    optional(:relation_type).filled(:string).description("Singular relation type alias for edge queries.")
    optional(:max_depth).filled(:integer).description("Maximum number of hops to expand. Default #{GraphTraversalService::DEFAULT_MAX_DEPTH}, max #{GraphTraversalService::MAX_DEPTH}.")
    optional(:direction).filled(:string).description("Traversal direction: one of #{GraphTraversalService::DIRECTIONS.join(', ')}. Default #{GraphTraversalService::DEFAULT_DIRECTION}.")
    optional(:relation_types).array(:string).description("Optional: restrict traversal to these relation types (canonicalized).")
    optional(:max_entities).filled(:integer).description("Maximum number of entities to return. Default #{GraphTraversalService::DEFAULT_MAX_ENTITIES}, max #{GraphTraversalService::MAX_ENTITIES}.")
    optional(:include).array(:string).description("Response projections: entities, relations, traversal.")
  end

  def call(start_entity_id: nil, from_entity_id: nil, to_entity_id: nil, relation_type: nil,
           max_depth: nil, direction: nil, relation_types: nil, max_entities: nil, include: nil)
    logger.info "Performing TraverseGraphTool from #{start_entity_id} (depth=#{max_depth}, direction=#{direction})"
    begin
      if direct_relation_query?(start_entity_id, from_entity_id, to_entity_id)
        return relation_query_result(
          start_entity_id: start_entity_id,
          from_entity_id: from_entity_id,
          to_entity_id: to_entity_id,
          relation_type: relation_type,
          relation_types: relation_types,
          include: include
        )
      end

      result = GraphTraversalService.new.expand(
        start_entity_id: start_entity_id,
        max_depth: max_depth || GraphTraversalService::DEFAULT_MAX_DEPTH,
        direction: direction || GraphTraversalService::DEFAULT_DIRECTION,
        relation_types: relation_types.presence || Array(relation_type).presence,
        max_entities: max_entities || GraphTraversalService::DEFAULT_MAX_ENTITIES
      )

      if result.nil?
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{start_entity_id} not found.",
          next_move: "Call `search`, then retry `traverse_graph` with a known start_entity_id."
        )
      end

      project_response(GraphTraversalSerializer.traversal(result), include, default: %w[entities relations traversal])
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue StandardError => e
      logger.error "InternalServerError in TraverseGraphTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end

  private

  def direct_relation_query?(start_entity_id, from_entity_id, to_entity_id)
    start_entity_id.blank? || from_entity_id.present? || to_entity_id.present?
  end

  def relation_query_result(start_entity_id:, from_entity_id:, to_entity_id:, relation_type:, relation_types:, include:)
    effective_from_id = from_entity_id.presence || (start_entity_id if to_entity_id.present?)
    relations = RelationQueryService.call(
      from_entity_id: effective_from_id,
      to_entity_id: to_entity_id,
      relation_type: relation_type,
      relation_types: relation_types
    )
    projections = normalized_projections(include, default: [ "relations" ])
    if "traversal".in?(projections)
      raise FastMcp::Tool::InvalidArgumentsError,
            "The traversal projection requires start_entity_id without direct endpoint filters."
    end

    response = {}
    response[:relations] = relations if "relations".in?(projections)
    if "entities".in?(projections)
      endpoint_ids = relations.flat_map { |relation| [ relation[:from_entity_id], relation[:to_entity_id] ] }
      endpoint_ids.concat([ effective_from_id, to_entity_id ].compact)
      response[:entities] = GraphTraversalSerializer.entities_for(endpoint_ids.uniq)
    end
    response
  end

  def project_response(response, include, default:)
    normalized_projections(include, default: default).to_h do |projection|
      [ projection.to_sym, response.fetch(projection.to_sym) ]
    end
  end

  def normalized_projections(include, default:)
    projections = include.nil? ? default : Array(include).map(&:to_s).uniq
    allowed = %w[entities relations traversal]
    unknown = projections - allowed
    if projections.empty? || unknown.any?
      raise FastMcp::Tool::InvalidArgumentsError,
            "include must contain one or more of: #{allowed.join(', ')}."
    end
    projections
  end
end
