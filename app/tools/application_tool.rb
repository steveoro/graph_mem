# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  COMPACTION_VALVE_TOOLS = ToolMutationPolicy::COMPACTION_VALVE_TOOLS
  MCP_CLIENT_HEADER = "x-mcp-client"

  attr_accessor :server

  class << self
    def input_schema_to_json
      super || { type: "object", properties: {}, required: [] }
    end
  end

  def call_with_schema_validation!(**args)
    started_at = nil

    if ToolMutationPolicy.compaction_valve?(tool_name)
      paused = CompactionValve.request_pause_if_running!
      logger.warn "[CompactionValve] pause incomplete for #{tool_name}" unless paused
    end

    normalized = ParameterNormalizer.normalize(tool_name, args)
    arg_validation = self.class.input_schema.call(normalized)
    if arg_validation.errors.any?
      raise FastMcp::Tool::InvalidArgumentsError, arg_validation.errors.to_h.to_json
    end

    record_client_activity!
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = call(**normalized)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    ToolTelemetry.record(
      tool_name: tool_name,
      client_id: current_client_id,
      duration_ms: duration_ms,
      result_size: result_size_for(result),
      scope: normalized[:scope]
    )
    [ result, _meta ]
  rescue StandardError => e
    duration_ms = if started_at
                    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    else
                    0
    end
    ToolTelemetry.record(
      tool_name: tool_name,
      client_id: current_client_id,
      duration_ms: duration_ms,
      error_class: e.class.name
    )
    raise
  ensure
    Current.actor = nil
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

    client = client_header_value(hdrs)
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

  def result_size_for(result)
    case result
    when Array then result.size
    when Hash then result.keys.size
    else
      1
    end
  end

  def client_header_value(headers)
    headers.each do |key, value|
      return value if normalized_header_key(key) == MCP_CLIENT_HEADER
    end

    nil
  end

  def normalized_header_key(key)
    key.to_s.sub(/\Ahttp[-_]/i, "").tr("_", "-").downcase
  end

  def record_client_activity!
    AgentContext.record_activity!(client_id: current_client_id, tool_name: tool_name)
  rescue StandardError => e
    logger.warn "AgentContext activity record failed for #{current_client_id}: #{e.message}"
  end
end
