# frozen_string_literal: true

module Llm
  # An agent CLI (Claude Code, Devin) on the operator's workstation, reached through the host bridge
  # (agent-CLI PR4; the bridge is script/llm_bridge/). A cloud provider: the Router sends it only
  # through Llm::CloudCall (gate, anonymize, restore), and only when a task's chain names it
  # (AppSettings llm_chain_<task>, "ollama" by default). It never calls the bridge to find out
  # whether it is usable (Llm::BridgeProbe does) and never raises.
  #
  #   provider = Llm::AgentCliProvider.new.for_task(:summary)
  #   provider.available? # => false until LLM_BRIDGE_URL, the token file, a profile and a model are set
  #   provider.generate("⟦ENT_1a2b⟧ is …", style: "concise", options: { timeout: 120 })
  #   # => { ok: true, text: "…", error: nil, latency_ms: 2412.0 }, or { ok: false, error: "bridge_gate_stale", … }
  class AgentCliProvider < Provider
    NAME = "agent_cli"
    # The profiles the bridge ships (script/llm_bridge/profiles/).
    PROFILES = %w[claude devin].freeze
    MODEL_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z/

    # @param client [Llm::BridgeClient]
    # @param task [Symbol] the Router task the bridge logs (one of Router::TASKS)
    def initialize(client: BridgeClient.new, task: :summary)
      super()
      @client = client
      @task = task
    end

    # @param task [Symbol]
    # @return [AgentCliProvider] a copy bound to `task` (the Router binds each call's task)
    def for_task(task)
      self.class.new(client: @client, task: task)
    end

    # @return [String] "agent_cli"
    def name
      NAME
    end

    # @return [Boolean] true: the text leaves the machine for a cloud model
    def cloud?
      true
    end

    # @return [Boolean] false: an inline call (an MCP request) never waits up to the bridge timeout
    def inline?
      false
    end

    # @return [String, nil] the configured model (AppSettings llm_agent_cli_model), when valid
    def model
      value = AppSettings.llm_agent_cli_model.to_s
      value if value.match?(MODEL_PATTERN)
    end

    # @return [String, nil] the configured bridge profile (AppSettings llm_agent_cli_profile), when known
    def profile
      value = AppSettings.llm_agent_cli_profile.to_s
      value if PROFILES.include?(value)
    end

    # @return [Boolean] the bridge client is configured and a profile and a model are set; no request
    def available?
      @client.configured? && profile.present? && model.present?
    end

    # @param prompt [String] the masked prompt (CloudCall adds its instruction)
    # @param style [String] unused: the prompt already says how to answer
    # @param options [Hash, nil] `timeout:` (seconds, the summary timeout by default), `format:`
    #   ("json" for scan and judge) and `max_output_length:` (see Llm::ResponseNormalizer)
    # @return [Hash] see Llm::BridgeClient#complete, with an answer's text normalized
    #   (Llm::ResponseNormalizer); "bridge_not_configured" without a profile or model
    def generate(prompt, style:, options: nil)
      opts = options.to_h.symbolize_keys
      return { ok: false, text: nil, error: BridgeClient::NOT_CONFIGURED, latency_ms: 0.0 } unless profile && model

      result = @client.complete(prompt, profile: profile, model: model, task: @task, timeout_s: timeout(opts))
      result[:ok] ? result.merge(text: ResponseNormalizer.call(result[:text], opts)) : result
    rescue StandardError
      { ok: false, text: nil, error: "bridge_error", latency_ms: nil }
    end

    private

    def timeout(opts)
      opts[:timeout].presence || SummarizationConfig.resolved_config[:timeout]
    end
  end
end
