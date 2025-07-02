# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "search_entities"
  end

  description "Search for graph memory entities by name and aliases with relevance ranking."

  # TODO: after successfully testing both 'list_entities' and 'search_subgraph', introduce pagination here too

  arguments do
    required(:query).filled(:string).description("The search term to find within entity names or aliases. Multiple words will be tokenized for better matching (case-insensitive).")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: { query: { type: "string", description: "The search term to find within entity names or aliases. Multiple words will be tokenized for better matching (case-insensitive)." } },
      required: [ "query" ]
    }
  end

  # Output: Array of entity objects with relevance scoring

  def call(query:)
    logger.info "Performing SearchEntitiesTool with query: #{query}"
    begin
      # Use the EntitySearchStrategy for improved search with relevance ranking
      search_strategy = EntitySearchStrategy.new
      search_results = search_strategy.search(query)

      # Convert SearchResult objects to the expected hash format
      search_results.map(&:to_h)
    rescue StandardError => e
      logger.error "InternalServerError in SearchEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in SearchEntitiesTool: #{e.message}"
    end
  end
end
