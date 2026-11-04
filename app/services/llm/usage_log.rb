# frozen_string_literal: true

module Llm
  # One info line per LLM call, written by the Router after the call (also when it failed):
  #
  #   [llm] {"task":"scan","provider":"ollama","model":"qwen3:8b","inline":false,"prompt_chars":5508,
  #          "est_in_tokens":1377,"out_chars":212,"est_out_tokens":53,"latency_ms":812.4,"outcome":"ok","prompt_tokens":1201}
  #
  # Sizes and outcome only: never the prompt, the answer, an error or a project or entity name. A
  # cloud call's line also has CLOUD_KEYS (what was masked, per type; the round trip) and measures
  # the masked prompt.
  # Token estimates use TokenBudget::CHARS_PER_TOKEN. A logging failure never fails the call.
  module UsageLog
    PREFIX = "[llm]"
    # The only extra keys a cloud call's line may carry: counts and outcomes, never text.
    CLOUD_KEYS = %i[anonymized masked secrets round_trip leftover_out refused refused_detail retry json].freeze

    module_function

    # @param task [Symbol] one of Router::TASKS
    # @param provider [Llm::Provider]
    # @param inline [Boolean] whether the call runs inside a request (an MCP tool call)
    # @param prompt [String]
    # @param result [Hash, nil] the provider's result; nil when it raised
    # @param cloud [Hash, nil] a cloud call's extra fields (CLOUD_KEYS only; the rest is dropped)
    # @param step [Integer] the attempt's place in its chain (PR5): a cloud line always carries it as
    #   `fallback_step`, with the agent-CLI `profile`; a local line only after a fallback (step > 0)
    # @return [void]
    def record(task:, provider:, inline:, prompt:, result:, cloud: nil, step: 0)
      line = fields(task, provider, inline, prompt, result || {})
      line = line.merge(cloud.slice(*CLOUD_KEYS)) if cloud
      line = line.merge(attempt_fields(provider, cloud, step)) if cloud || step.positive?
      Rails.logger.info("#{PREFIX} #{JSON.generate(line)}")
    rescue StandardError
      nil
    end

    # @return [Hash] the line's fields
    def fields(task, provider, inline, prompt, result)
      prompt_chars = prompt.to_s.length
      out_chars = result[:text].to_s.length
      line = { task: task.to_s, provider: provider.name.to_s, model: provider.model, inline: inline == true,
               prompt_chars: prompt_chars, est_in_tokens: estimate(prompt_chars), out_chars: out_chars,
               est_out_tokens: estimate(out_chars), latency_ms: result[:latency_ms], outcome: result[:ok] ? "ok" : "error" }
      result[:prompt_tokens].nil? ? line : line.merge(prompt_tokens: result[:prompt_tokens])
    end

    def attempt_fields(provider, cloud, step)
      profile = cloud && provider.respond_to?(:profile) ? provider.profile : nil
      { profile: profile, fallback_step: step }.compact
    end

    def estimate(chars)
      (chars.to_f / TokenBudget::CHARS_PER_TOKEN).ceil
    end
    private_class_method :fields, :attempt_fields, :estimate
  end
end
