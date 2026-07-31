# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  def self.tool_name
    "search_entities"
  end

  description "Search for graph memory entities by name, entity type, and aliases with relevance ranking."

  arguments do
    required(:query).filled(:string).description("The search term to find within entity names, entity types, or aliases. Multiple words will be tokenized for better matching (case-insensitive).")
    optional(:limit).filled(:integer).description("Maximum entities to return (1-100). Defaults to 50.")
  end

  def call(query:, limit: 50)
    logger.info "Performing SearchEntitiesTool with query: #{query}"
    begin
      limit = [ limit.to_i, 1 ].max.clamp(1, 100)
      context_scope = graph_mem_context.scoped_entity_scope
      payload = EntityRetrievalService.search(
        query,
        limit: limit,
        semantic: true,
        context_entity_ids: context_scope&.entity_ids,
        scope_entity_ids: context_scope&.entity_ids,
        context_scope: context_scope
      )
      payload[:results].map(&:to_h)
    rescue StandardError => e
      logger.error "InternalServerError in SearchEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in SearchEntitiesTool: #{e.message}"
    end
  end
end
