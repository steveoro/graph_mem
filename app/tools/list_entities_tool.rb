# frozen_string_literal: true

class ListEntitiesTool < ApplicationTool
  DEFAULT_PER_PAGE = 20 # Renamed from DEFAULT_LIMIT
  MAX_PER_PAGE = 100    # Renamed from MAX_LIMIT
  DEFAULT_PAGE = 1

  def self.tool_name
    'list_entities'
  end

  description 'Retrieves a paginated list of all entities, returning their ID, name, and type, using page/per_page.'

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
          type: [:integer, :null],
          description: "Optional. Maximum number of entities to return per page. Defaults to #{DEFAULT_PER_PAGE}, max #{MAX_PER_PAGE}.",
          minimum: 1,
          maximum: MAX_PER_PAGE
        },
        page: {
          type: [:integer, :null],
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
              entity_type: { type: :string, description: 'The type of the entity.' }
            },
            required: [:entity_id, :name, :entity_type]
          }
        },
        pagination: {
          type: :object,
          properties: {
            total_entities: { type: :integer, description: 'Total number of entities in the system.' },
            per_page: { type: :integer, description: 'Number of entities requested per page.' },
            current_page: { type: :integer, description: 'The current page number.' },
            total_pages: { type: :integer, description: 'Total number of pages available.' }
          },
          required: [:total_entities, :per_page, :current_page, :total_pages]
        }
      },
      required: [:entities, :pagination]
    }.freeze
  end

  def call(page: nil, per_page: nil)
    # Determine effective values, using defaults if parameters were not provided
    effective_page = page.nil? ? DEFAULT_PAGE : page.to_i
    effective_per_page = per_page.nil? ? DEFAULT_PER_PAGE : per_page.to_i

    # Validate effective_page
    if effective_page < 1
      raise FastMcp::Tool::InvalidArgumentsError, "Page number must be 1 or greater."
    end

    # Validate effective_per_page
    if effective_per_page < 1 || effective_per_page > MAX_PER_PAGE
      raise FastMcp::Tool::InvalidArgumentsError, "Per page count must be between 1 and #{MAX_PER_PAGE}."
    end

    # Proceed with logic using effective_page and effective_per_page
    offset = (effective_page - 1) * effective_per_page

    total_entities_count = MemoryEntity.count
    fetched_entities = MemoryEntity.order(:id).limit(effective_per_page).offset(offset).to_a

    output_entities = fetched_entities.map do |entity|
      {
        entity_id: entity.id.to_s,
        name: entity.name,
        entity_type: entity.entity_type
      }
    end

    total_pages_count = (total_entities_count.to_f / effective_per_page).ceil
    total_pages_count = [total_pages_count, 1].max

    {
      entities: output_entities,
      pagination: {
        total_entities: total_entities_count,
        per_page: effective_per_page,
        current_page: effective_page,
        total_pages: total_pages_count
      }
    }
  rescue StandardError => e
    logger.error "InternalServerError in ListEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
    # Consider if a more specific error type is needed for bad pagination params if not caught by `arguments`
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred: #{e.message}"
  end
end
