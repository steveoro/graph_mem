# frozen_string_literal: true

class SearchSubgraphTool < ApplicationTool
  DEFAULT_PER_PAGE = 20 # Renamed from DEFAULT_LIMIT
  MAX_PER_PAGE = 100    # Renamed from MAX_LIMIT
  DEFAULT_PAGE = 1

  def self.tool_name
    "search_subgraph"
  end

  description "Searches a query across entity names, types, aliases, and observations. " \
    "Returns a paginated subgraph of matching entities (with observations) " \
    "and relations exclusively between them, using page/per_page."

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
                    created_at: { type: :string, format: "date-time" },
                    updated_at: { type: :string, format: "date-time" }
                  },
                  required: [ :observation_id, :content, :created_at, :updated_at ]
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
    query_term = query
    if query_term.blank?
      raise FastMcp::Tool::InvalidArgumentsError, "Query term cannot be blank."
    end

    unless search_in_name || search_in_type || search_in_observations || search_in_aliases
      raise FastMcp::Tool::InvalidArgumentsError, "At least one search field (name, type, aliases, observations) must be enabled."
    end

    effective_page = page.nil? ? DEFAULT_PAGE : page.to_i
    effective_per_page = per_page.nil? ? DEFAULT_PER_PAGE : per_page.to_i

    if effective_page < 1
      raise FastMcp::Tool::InvalidArgumentsError, "Page number must be 1 or greater."
    end
    if effective_per_page < 1 || effective_per_page > MAX_PER_PAGE
      raise FastMcp::Tool::InvalidArgumentsError, "Per page count must be between 1 and #{MAX_PER_PAGE}."
    end

    # Build query to find all matching entity IDs
    base_query = MemoryEntity.distinct
    like_query_term = "%#{query_term.downcase}%"

    # Build conditions for WHERE clause
    sql_conditions = []
    sql_params = {}

    if search_in_name
      sql_conditions << "LOWER(memory_entities.name) LIKE :like_query_term"
    end
    if search_in_type
      sql_conditions << "LOWER(memory_entities.entity_type) LIKE :like_query_term"
    end
    if search_in_aliases
      sql_conditions << "LOWER(memory_entities.aliases) LIKE :like_query_term"
    end
    sql_params[:like_query_term] = like_query_term

    if search_in_observations
      # Ensure join is added only if searching observations
      base_query = base_query.joins(:memory_observations) unless base_query.joins_values.include?(:memory_observations)
      sql_conditions << "LOWER(memory_observations.content) LIKE :like_query_term"
    end

    # Combine conditions with OR
    combined_sql_conditions = sql_conditions.join(" OR ")

    # Text-based matching
    matching_entity_ids = base_query.where(combined_sql_conditions, sql_params).pluck(:id).uniq

    # Merge in vector search results when embeddings are available
    begin
      vector_strategy = VectorSearchStrategy.new
      vector_results = vector_strategy.search(query_term, limit: effective_per_page * 2)
      vector_ids = vector_results.map { |r| r.entity.id }
      matching_entity_ids = (matching_entity_ids + vector_ids).uniq
    rescue StandardError => e
      logger.debug "SearchSubgraphTool: vector search unavailable, using text only — #{e.message}"
    end

    total_matching_entities = matching_entity_ids.length

    # Apply pagination to the IDs
    offset = (effective_page - 1) * effective_per_page
    paginated_entity_ids = matching_entity_ids.slice(offset, effective_per_page) || []

    entities_to_return = []
    relations_to_return = []

    if paginated_entity_ids.any?
      # Fetch the entities for the current page, including their observations
      # Order them by the paginated_entity_ids to maintain the slice order
      db_entities = MemoryEntity.where(id: paginated_entity_ids)
                                .includes(:memory_observations)
                                .order(Arel.sql("CASE id #{paginated_entity_ids.map.with_index { |id, index| "WHEN #{id} THEN #{index}" }.join(' ')} END"))
                                .to_a

      entities_to_return = db_entities.map do |entity|
        {
          entity_id: entity.id,
          name: entity.name,
          entity_type: entity.entity_type,
          aliases: entity.aliases,
          observations: entity.memory_observations.map do |obs|
            {
              observation_id: obs.id,
              content: obs.content,
              created_at: obs.created_at.iso8601,
              updated_at: obs.updated_at.iso8601
            }
          end,
          created_at: entity.created_at.iso8601,
          updated_at: entity.updated_at.iso8601
        }
      end

      # Fetch relations *only* between the entities on the current page
      db_relations = MemoryRelation.where(from_entity_id: paginated_entity_ids, to_entity_id: paginated_entity_ids).to_a
      relations_to_return = db_relations.map do |relation|
        {
          relation_id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type,
          created_at: relation.created_at.iso8601,
          updated_at: relation.updated_at.iso8601
        }
      end
    end

    total_pages_count = (total_matching_entities.to_f / effective_per_page).ceil
    total_pages_count = [ total_pages_count, 1 ].max # Ensure at least 1 page

    {
      entities: entities_to_return,
      relations: relations_to_return,
      pagination: {
        total_entities: total_matching_entities,
        per_page: effective_per_page,
        current_page: effective_page,
        total_pages: total_pages_count
      }
    }
  rescue FastMcp::Tool::InvalidArgumentsError # Re-raise if it's our own validation
    raise
  rescue StandardError => e
    logger.error "InternalServerError in SearchSubgraphTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred during search: #{e.message}"
  end
end
