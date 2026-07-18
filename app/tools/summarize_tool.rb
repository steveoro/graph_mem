# frozen_string_literal: true

class SummarizeTool < ApplicationTool
  def self.tool_name
    "summarize"
  end

  description "Summarize what the knowledge graph knows about a query within the active project context. " \
    "Returns deterministic source-backed evidence and optionally an LLM-generated synthesis when enabled."

  arguments do
    required(:query).filled(:string).description("The topic or question to summarize.")
    optional(:entity_id).filled(:integer).description("Optional entity ID to scope summarization to a single entity.")
    optional(:max_results).filled(:integer).description("Maximum entities to retrieve before ranking observations. Defaults to 10.")
    optional(:max_observations).filled(:integer).description("Maximum observations to include in the summary. Defaults to 20.")
    optional(:observations_per_entity).filled(:integer).description("Maximum observations to include per entity before capping. 0 disables the cap. Defaults to the AppSetting.")
    optional(:max_depth).filled(:integer).description("Optional graph traversal depth from matched entities. Defaults to 0.")
    optional(:include_sources).filled(:bool).description("Include source entity and observation IDs. Defaults to true.")
    optional(:style).filled(:string).description('Summary style: "concise" (default) or "detailed".')
  end

  def call(query:, entity_id: nil, max_results: 10, max_observations: 20, observations_per_entity: nil,
           max_depth: 0, include_sources: true, style: "concise")
    logger.info "Performing SummarizeTool with query: #{query}"
    begin
      SummarizerService.call(
        query: query,
        entity_id: entity_id,
        max_results: max_results,
        max_observations: max_observations,
        observations_per_entity: observations_per_entity,
        max_depth: max_depth,
        include_sources: include_sources,
        style: style,
        context_entity_ids: graph_mem_context.scoped_entity_ids
      )
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in SummarizeTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ArgumentError => e
      logger.error "InvalidArguments in SummarizeTool: #{e.message}"
      raise FastMcp::Tool::InvalidArgumentsError, e.message
    rescue StandardError => e
      logger.error "InternalServerError in SummarizeTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in SummarizeTool: #{e.message}"
    end
  end
end
