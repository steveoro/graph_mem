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
    # @param chains [Boolean] PR5: also list, per task whose chain names a profile, the configured
    #   profiles and models (primary, then backups), each with `tested:` (the gate's models include
    #   it; nil when unknown). The same single health request.
    # @return [Hash] see above; `reason` is a BridgeClient reason or error name when not reachable
    def call(client: BridgeClient.new, chains: false)
      reason = client.reason
      return with_chains(report(configured: false, reason: reason), nil, chains) if reason

      health = client.health
      return with_chains(report(configured: true, reason: health[:error]), nil, chains) unless health[:ok]

      body = health[:body]
      result = report(configured: true, reason: nil, reachable: true, bridge_version: short(body["bridge_version"]), profiles: profiles(body["profiles"]))
      with_chains(result, body["profiles"], chains)
    end

    # @param listed [Hash, nil] the health body's profiles (nil when the bridge didn't answer)
    # @return [Hash{String => Array<Hash>}] per task, `{ profile:, model:, tested: }` for each model the
    #   chain would try; models are the operator's settings, never the bridge's list
    def configured_models(listed)
      Router::TASKS.each_with_object({}) do |task, table|
        entries = Router.chain(task).select { |name| Chain.profile_entry?(name) }
        next if entries.empty?

        table[task.to_s] = entries.flat_map do |name|
          Chain.models(name).map { |profile, model| { profile: profile, model: model, tested: tested(listed, profile, model) } }
        end
      end
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

    def with_chains(result, listed, chains)
      chains ? result.merge(chains: configured_models(listed)) : result
    end

    def tested(listed, profile, model)
      info = listed.is_a?(Hash) ? listed[profile] : nil
      models = info.is_a?(Hash) && info["gate"].is_a?(Hash) ? info["gate"]["models"] : nil
      models.is_a?(Array) ? models.include?(model) : nil
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
    private_class_method :with_chains, :tested, :gate_result, :short, :report
  end
end
