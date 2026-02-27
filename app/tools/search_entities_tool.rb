# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  def self.tool_name
    "search_entities"
  end

  description "Search for graph memory entities by name, entity type, and aliases with relevance ranking."

  arguments do
    required(:query).filled(:string).description("The search term to find within entity names, entity types, or aliases. Multiple words will be tokenized for better matching (case-insensitive).")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: { query: { type: "string", description: "The search term to find within entity names, entity types, or aliases. Multiple words will be tokenized for better matching (case-insensitive)." } },
      required: [ "query" ]
    }
  end

  def call(query:)
    logger.info "Performing SearchEntitiesTool with query: #{query}"
    begin
      strategy = HybridSearchStrategy.new
      results = strategy.search(query, semantic: true)
      results.map(&:to_h)
    rescue StandardError => e
      logger.error "InternalServerError in SearchEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in SearchEntitiesTool: #{e.message}"
    end
  end
end
