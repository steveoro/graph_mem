# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  COMPACTION_VALVE_TOOLS = ToolMutationPolicy::COMPACTION_VALVE_TOOLS
  MCP_CLIENT_HEADER = "x-mcp-client"
  MCP_PROFILE_NAMES = %i[default readonly maintenance].freeze
  MCP_ANNOTATION_KEYS = %i[read_only_hint destructive_hint idempotent_hint open_world_hint].freeze

  attr_accessor :server

  class << self
    def input_schema_to_json
      super || { type: "object", properties: {}, required: [] }
    end

    def mcp_metadata(profiles:, advertised: true, **hints)
      normalized_profiles = Array(profiles).map(&:to_sym).uniq
      unknown_profiles = normalized_profiles - MCP_PROFILE_NAMES
      raise ArgumentError, "Unknown MCP profiles: #{unknown_profiles.join(', ')}" if unknown_profiles.any?
      raise ArgumentError, "At least one MCP profile is required" if normalized_profiles.empty?
      raise ArgumentError, "MCP advertised flag must be boolean" unless advertised.in?([ true, false ])

      missing_hints = MCP_ANNOTATION_KEYS - hints.keys
      unknown_hints = hints.keys - MCP_ANNOTATION_KEYS
      if missing_hints.any? || unknown_hints.any?
        raise ArgumentError,
              "MCP annotations must contain exactly #{MCP_ANNOTATION_KEYS.join(', ')}"
      end
      raise ArgumentError, "MCP annotation values must be boolean" unless hints.values.all? { |value| value.in?([ true, false ]) }

      @mcp_profiles = normalized_profiles.freeze
      @mcp_advertised = advertised
      annotations(hints.freeze)
    end

    def mcp_profiles
      @mcp_profiles || []
    end

    def mcp_advertised?
      @mcp_advertised != false
    end
  end

  def call_with_schema_validation!(**args)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client_id = current_client_id
    argument_keys = args.keys.map(&:to_s).uniq.sort
    normalized = nil
    result = nil
    error = nil

    if ToolMutationPolicy.compaction_valve?(tool_name)
      paused = CompactionValve.request_pause_if_running!
      logger.warn "[CompactionValve] pause incomplete for #{tool_name}" unless paused
    end

    normalized = ParameterNormalizer.normalize(tool_name, args)
    arg_validation = self.class.input_schema.call(normalized)
    if arg_validation.errors.any?
      details = arg_validation.errors.to_h
      raise FastMcp::Tool::InvalidArgumentsError,
            "Invalid arguments: #{details.to_json}. Correct the argument format required by the tool schema and retry."
    end

    record_client_activity!
    result = call(**normalized)
    [ result, _meta ]
  rescue StandardError => e
    error = e
    raise
  ensure
    ToolTelemetry.record(
      tool_name: tool_name,
      client_id: client_id,
      outcome: error ? "error" : "ok",
      error_class: error&.class&.name,
      error_category: telemetry_error_category(error),
      duration_ms: elapsed_ms_since(started_at),
      result_size: error ? nil : result_size_for(result),
      scope: normalized&.[](:scope),
      argument_keys: argument_keys
    )
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

  # Mcp-Session-Id of the current Streamable HTTP request, or nil on the legacy
  # /mcp/sse endpoint and over stdio.
  def current_session_id
    Thread.current[:graph_mem_mcp_session_id]
  end

  # True when another MCP session was seen under this same client_id during the
  # current call's conflict window, so both are sharing one context row.
  def concurrent_session?
    @concurrent_session.present?
  end

  # Advice to merge into a response when this client id is being shared.
  # Returns nil when there is nothing to report.
  def shared_client_id_warning(displaced_project: nil)
    return nil unless concurrent_session? || displaced_project

    detail =
      if displaced_project
        "Active project was changed from #{displaced_project.name.inspect} " \
          "(ID #{displaced_project.id}) moments ago."
      else
        "Another MCP session is calling tools under this same client id."
      end

    {
      warning: "Client id #{current_client_id.inspect} appears to be shared by more than one agent. " \
        "#{detail} Context is stored per client id, so these agents overwrite each other's scope.",
      next_move: "Give each agent its own `X-MCP-Client` header value, then call `set_context` again."
    }
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

  def elapsed_ms_since(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  def telemetry_error_category(error)
    ToolError.category_for(error) if error
  rescue StandardError
    ToolError::CATEGORY_SYSTEM
  end

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
    context = AgentContext.record_activity!(
      client_id: current_client_id,
      tool_name: tool_name,
      session_id: current_session_id
    )
    @concurrent_session = context.concurrent_session
  rescue StandardError => e
    logger.warn "AgentContext activity record failed for #{current_client_id}: #{e.message}"
  end
end
