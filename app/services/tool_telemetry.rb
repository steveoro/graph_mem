# frozen_string_literal: true

# Lightweight MCP tool telemetry without logging sensitive payloads.
class ToolTelemetry
  class << self
    def record(tool_name:, client_id:, duration_ms:, outcome:, argument_keys:, result_size: nil, scope: nil,
               error_class: nil, error_category: nil)
      safe_argument_keys = Array(argument_keys).map(&:to_s).uniq.sort

      Rails.logger.info(
        "[ToolTelemetry] tool=#{tool_name} client=#{client_id} outcome=#{outcome} duration_ms=#{duration_ms} " \
        "result_size=#{result_size} scope=#{scope} error_class=#{error_class} error_category=#{error_category}"
      )

      ToolInvocation.create!(
        tool_name: tool_name,
        client_id: client_id,
        outcome: outcome,
        error_class: error_class,
        error_category: error_category,
        duration_ms: duration_ms,
        result_size: result_size,
        scope: scope,
        argument_keys: safe_argument_keys,
        created_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.warn(
        "[ToolTelemetry] persistence failed for tool=#{tool_name} client=#{client_id}: " \
        "#{e.class}: #{e.message}"
      )
      nil
    end
  end
end
