# frozen_string_literal: true

class ListEntitiesTool < ApplicationTool
  DEFAULT_PER_PAGE = EntityCatalogService::DEFAULT_PER_PAGE
  MAX_PER_PAGE = EntityCatalogService::MAX_PER_PAGE
  DEFAULT_PAGE = EntityCatalogService::DEFAULT_PAGE

  def self.tool_name
    "list_entities"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    advertised: false,
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Page the entire entity catalog with no search query, returning id, name, and type only. " \
    "Pass optional `page` (integer, default 1) and `per_page` (integer, default 20, max 100). " \
    "Do not use for text or semantic search; use `search` instead. " \
    "Do not use to search observation text or return relations; use `search` instead. " \
    "Do not use to load one known entity; use `get_entities` instead. " \
    "Do not use for graph health counts; use `get_graph_stats` instead."

  # Defines arguments for fast-mcp validation.
  arguments do
    optional(:per_page).filled(:integer)
                       .description("The maximum number of entities to return per page. Defaults to #{DEFAULT_PER_PAGE}, Max: #{MAX_PER_PAGE}. Must be between 1 and #{MAX_PER_PAGE}.")
    optional(:page).filled(:integer)
                   .description("The page number to retrieve. Defaults to #{DEFAULT_PAGE}. Must be 1 or greater.")
  end

  def tool_input_schema # For schema advertisement
    {
      type: :object,
      properties: {
        per_page: {
          type: [ :integer, :null ],
          description: "Optional. Maximum number of entities to return per page. Defaults to #{DEFAULT_PER_PAGE}, max #{MAX_PER_PAGE}.",
          minimum: 1,
          maximum: MAX_PER_PAGE
        },
        page: {
          type: [ :integer, :null ],
          description: "Optional. The page number to retrieve. Defaults to #{DEFAULT_PAGE}.",
          minimum: 1
        }
      },
      required: []
    }.freeze
  end

  def tool_output_schema # Describes the structure of the successful output
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
              entity_type: { type: :string, description: "The type of the entity." }
            },
            required: [ :entity_id, :name, :entity_type ]
          }
        },
        pagination: {
          type: :object,
          properties: {
            total_entities: { type: :integer, description: "Total number of entities in the system." },
            per_page: { type: :integer, description: "Number of entities requested per page." },
            current_page: { type: :integer, description: "The current page number." },
            total_pages: { type: :integer, description: "Total number of pages available." }
          },
          required: [ :total_entities, :per_page, :current_page, :total_pages ]
        }
      },
      required: [ :entities, :pagination ]
    }.freeze
  end

  def call(page: nil, per_page: nil)
    EntityCatalogService.call(page: page, per_page: per_page)
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "ListEntitiesTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
