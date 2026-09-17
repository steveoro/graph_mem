# frozen_string_literal: true

class SearchSubgraphTool < ApplicationTool
  DEFAULT_PER_PAGE = SubgraphSearchService::DEFAULT_PER_PAGE
  MAX_PER_PAGE = SubgraphSearchService::MAX_PER_PAGE
  DEFAULT_PAGE = SubgraphSearchService::DEFAULT_PAGE

  def self.tool_name
    "search_subgraph"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    advertised: false,
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Search names, types, aliases, and observations and return a paginated subgraph of matches " \
    "(observations plus relations exclusively among them). Pass required `query` (string); optional " \
    "`search_in_name`, `search_in_type`, `search_in_aliases`, `search_in_observations` (bool, default true), " \
    "`page` (integer, default 1), `per_page` (integer, default 20, max 100). Not a BFS from a start node. " \
    "Do not use for ranked summaries without observations or relations; use `search` instead. " \
    "Do not use with known ids; use `get_entities` instead. " \
    "Do not use for multi-hop expansion; use `traverse_graph` instead. " \
    "Do not use for a synthesized answer; use `summarize` instead. " \
    "Do not use as a no-query catalog; use `search` instead."

  # Defines arguments for fast-mcp validation.
  arguments do
    required(:query).filled(:string).description("The search term to find within entity names, types, aliases, or observations.")
    optional(:search_in_name).filled(:bool).description("Whether to search in entity names. Defaults to true.")
    optional(:search_in_type).filled(:bool).description("Whether to search in entity types. Defaults to true.")
    optional(:search_in_aliases).filled(:bool).description("Whether to search in entity aliases. Defaults to true.")
    optional(:search_in_observations).filled(:bool).description("Whether to search in entity observations. Defaults to true.")
    optional(:page).filled(:integer)
                   .description("The page number to retrieve. Defaults to #{DEFAULT_PAGE}. Must be 1 or greater.")
    optional(:per_page).filled(:integer)
                       .description("The maximum number of entities to return per page. Defaults to #{DEFAULT_PER_PAGE}, Max: #{MAX_PER_PAGE}. Must be between 1 and #{MAX_PER_PAGE}.")
  end

  def tool_input_schema
    {
      type: :object,
      properties: {
        query: {
          type: :string,
          description: "The search term."
        },
        search_in_name: {
          type: :boolean,
          default: true,
          description: "Whether to search in entity names."
        },
        search_in_type: {
          type: :boolean,
          default: true,
          description: "Whether to search in entity types."
        },
        search_in_observations: {
          type: :boolean,
          default: true,
          description: "Whether to search in entity observations."
        },
        search_in_aliases: {
          type: :boolean,
          default: true,
          description: "Whether to search in entity aliases."
        },
        page: {
          type: [ :integer, :null ],
          description: "Optional. The page number to retrieve. Defaults to #{DEFAULT_PAGE}.",
          minimum: 1 # Informational, enforced in call
        },
        per_page: {
          type: [ :integer, :null ],
          description: "Optional. Maximum number of entities to return per page. Defaults to #{DEFAULT_PER_PAGE}, max #{MAX_PER_PAGE}.",
          minimum: 1, # Informational
          maximum: MAX_PER_PAGE # Informational
        }
      },
      required: [ :query ]
    }.freeze
  end

  def tool_output_schema
    {
      type: :object,
      properties: {
        entities: {
          type: :array,
          items: {
            type: :object,
            properties: {
              entity_id: { type: :integer },
              name: { type: :string },
              entity_type: { type: :string },
              aliases: { type: [ :string, :null ] },
              observations: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    observation_id: { type: :integer },
                    content: { type: :string },
                    confidence: { type: [ :number, :null ] },
                    source: { type: [ :string, :null ] },
                    valid_from: { type: [ :string, :null ], format: "date-time" },
                    valid_until: { type: [ :string, :null ], format: "date-time" },
                    tags: { type: :array, items: { type: :string } },
                    status: { type: :string, enum: MemoryObservation::STATUSES },
                    obsoleted_at: { type: [ :string, :null ], format: "date-time" },
                    obsolescence_reason: { type: [ :string, :null ] },
                    superseded_by_id: { type: [ :integer, :null ] },
                    created_at: { type: :string, format: "date-time" },
                    updated_at: { type: :string, format: "date-time" }
                  },
                  required: [ :observation_id, :content, :status, :created_at, :updated_at ]
                }
              },
              created_at: { type: :string, format: "date-time" },
              updated_at: { type: :string, format: "date-time" }
            },
            required: [ :entity_id, :name, :entity_type, :observations, :created_at, :updated_at ]
          }
        },
        relations: {
          type: :array,
          items: {
            type: :object,
            properties: {
              relation_id: { type: :integer },
              from_entity_id: { type: :integer },
              to_entity_id: { type: :integer },
              relation_type: { type: :string },
              weight: { type: [ :number, :null ] },
              confidence: { type: [ :number, :null ] },
              properties: { type: :object },
              created_at: { type: :string, format: "date-time" },
              updated_at: { type: :string, format: "date-time" }
            },
            required: [ :relation_id, :from_entity_id, :to_entity_id, :relation_type, :created_at, :updated_at ]
          }
        },
        pagination: {
          type: :object,
          properties: {
            total_entities: { type: :integer, description: "Total number of entities matching the search criteria." },
            per_page: { type: :integer, description: "Number of entities requested per page." },
            current_page: { type: :integer, description: "The current page number." },
            total_pages: { type: :integer, description: "Total number of pages available for the search results." }
          },
          required: [ :total_entities, :per_page, :current_page, :total_pages ]
        }
      },
      required: [ :entities, :relations, :pagination ]
    }.freeze
  end

  def call(query:, search_in_name: true, search_in_type: true, search_in_observations: true, search_in_aliases: true, page: nil, per_page: nil)
    SubgraphSearchService.call(
      query: query,
      search_in_name: search_in_name,
      search_in_type: search_in_type,
      search_in_observations: search_in_observations,
      search_in_aliases: search_in_aliases,
      page: page,
      per_page: per_page,
      context_scope: graph_mem_context.scoped_entity_scope,
      logger: logger
    )
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "InternalServerError in SearchSubgraphTool: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
