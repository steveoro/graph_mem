# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  def self.tool_name
    "search_entities"
  end

  description "Search entities by keyword and semantic similarity (hybrid RRF); returns ranked summaries without " \
    "observation text or relations. Pass required `query` (string); optional `limit` (integer, default 50, max 100). " \
    "Active context boosts matches (not a hard filter). " \
    "Do not use to search observation text or return connecting relations; use `search_subgraph` instead. " \
    "Do not use to load a known id; use `get_entity` instead. " \
    "Do not use to page every entity with no query; use `list_entities` instead. " \
    "Do not use to answer what the graph knows about a topic; use `summarize` instead."

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
