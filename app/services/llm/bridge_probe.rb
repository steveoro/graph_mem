# frozen_string_literal: true

module Llm
  # What the operator sees of the host bridge (agent-CLI PR4): whether the app is configured for it,
  # whether it answers, and each profile's CLI, gate and tripped state, from `GET /v1/health`. Run
  # only on demand (Settings › Summaries "Check now", `bin/rails llm:bridge_probe`), never on a
  # timer. It keeps only booleans, the gate result and short version and date strings: never the
  # token, a CLI path or any other path. `passed_on` is shown as text and compared to nothing.
  #
  #   Llm::BridgeProbe.call
  #   # => { configured: true, reason: nil, reachable: true, bridge_version: "1.0.0",
  #   #      profiles: { "claude" => { cli_ok: true, gate_ok: true, gate_result: "PASS", passed_on: "2026-11-04", tripped: false } } }
  #   # => { configured: false, reason: "url_unset", reachable: false, bridge_version: nil, profiles: {} }
  module BridgeProbe
    PROFILE_NAME = /\A[a-z][a-z0-9_-]{0,31}\z/
    SHORT_TEXT = /\A[\w.:+\- ]{1,32}\z/
    GATE_RESULTS = %w[PASS FAIL].freeze
    MAX_PROFILES = 16

    module_function

    # @param client [Llm::BridgeClient]
    # @return [Hash] see above; `reason` is a BridgeClient reason or error name when not reachable
    def call(client: BridgeClient.new)
      reason = client.reason
      return report(configured: false, reason: reason) if reason

      health = client.health
      return report(configured: true, reason: health[:error]) unless health[:ok]

      body = health[:body]
      report(configured: true, reason: nil, reachable: true, bridge_version: short(body["bridge_version"]), profiles: profiles(body["profiles"]))
    end

    # @return [Hash{String => Hash}] the profiles the bridge listed, sanitized
    def profiles(listed)
      return {} unless listed.is_a?(Hash)

      listed.select { |name, info| name.is_a?(String) && name.match?(PROFILE_NAME) && info.is_a?(Hash) }.first(MAX_PROFILES).to_h do |name, info|
        gate = info["gate"].is_a?(Hash) ? info["gate"] : nil
        [ name, { cli_ok: info["cli_ok"] == true, gate_ok: info["gate_ok"] == true, gate_result: gate_result(gate),
                  passed_on: gate && short(gate["passed_on"]), tripped: info["tripped"] == true } ]
      end
    end

    def gate_result(gate)
      return nil unless gate

      GATE_RESULTS.include?(gate["result"]) ? gate["result"] : "other"
    end

    def short(value)
      value if value.is_a?(String) && value.match?(SHORT_TEXT)
    end

    def report(configured:, reason:, reachable: false, bridge_version: nil, profiles: {})
      { configured: configured, reason: reason, reachable: reachable, bridge_version: bridge_version, profiles: profiles }
    end
    private_class_method :gate_result, :short, :report
  end
end
