# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  COMPACTION_VALVE_TOOLS = %w[
    bulk_update create_entity create_observation create_relation
    delete_entity delete_observation delete_relation update_entity merge_entities
    search_entities search_subgraph suggest_merges
  ].freeze

  attr_accessor :server

  class << self
    # Provide a default schema JSON for tools that don't use the arguments DSL
    # (e.g. VersionTool, GetCurrentTimeTool). FastMcp returns nil when no
    # arguments block is defined; handle_tools_list needs a valid hash.
    def input_schema_to_json
      super || { type: "object", properties: {}, required: [] }
    end
  end

  # Normalize incoming parameters (camelCase, entity names, operations array)
  # before schema validation and dispatch.
  def call_with_schema_validation!(**args)
    CompactionValve.request_pause_if_running! if COMPACTION_VALVE_TOOLS.include?(tool_name)

    normalized = ParameterNormalizer.normalize(tool_name, args)
    arg_validation = self.class.input_schema.call(normalized)
    if arg_validation.errors.any?
      raise FastMcp::Tool::InvalidArgumentsError, arg_validation.errors.to_h.to_json
    end
    record_client_activity!
    [ call(**normalized), _meta ]
  end

  def call(...)
    Current.actor = "mcp:#{tool_name}"
    super
  end

  def logger
    Rails.logger
  end

  def current_client_id
    hdrs = respond_to?(:headers, true) ? headers : nil
    return GraphMemContext::DEFAULT_CLIENT_ID if hdrs.blank?

    client = hdrs["HTTP_X_MCP_CLIENT"] || hdrs["X-MCP-CLIENT"] || hdrs["X-MCP-Client"]
    GraphMemContext.normalize_client_id(client)
  end

  def graph_mem_context
    GraphMemContext.for(current_client_id)
  end

  def tool_name
    self.class.tool_name
  end

  def description
    if self.class.respond_to?(:description)
      self.class.description
    else
      "#{tool_name} - A general purpose tool."
    end
  end

  private

  def record_client_activity!
    AgentContext.record_activity!(client_id: current_client_id, tool_name: tool_name)
  rescue StandardError => e
    logger.warn "AgentContext activity record failed for #{current_client_id}: #{e.message}"
  end
end
