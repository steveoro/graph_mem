# frozen_string_literal: true

# Lightweight MCP tool telemetry without logging sensitive payloads.
class ToolTelemetry
  class << self
    def record(tool_name:, client_id:, duration_ms:, result_size: nil, scope: nil, error_class: nil)
      Rails.logger.info(
        "[ToolTelemetry] tool=#{tool_name} client=#{client_id} duration_ms=#{duration_ms} " \
        "result_size=#{result_size} scope=#{scope} error_class=#{error_class}"
      )
    end
  end
end
