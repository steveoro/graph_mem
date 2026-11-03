# frozen_string_literal: true

module Llm
  # One info line per LLM call, written by the Router after the call (also when it failed):
  #
  #   [llm] {"task":"scan","provider":"ollama","model":"qwen3:8b","inline":false,"prompt_chars":5508,
  #          "est_in_tokens":1377,"out_chars":212,"est_out_tokens":53,"latency_ms":812.4,"outcome":"ok","prompt_tokens":1201}
  #
  # Sizes and outcome only: never the prompt, the answer, an error or a project or entity name.
  # Token estimates use TokenBudget::CHARS_PER_TOKEN. A logging failure never fails the call.
  module UsageLog
    PREFIX = "[llm]"

    module_function

    # @param task [Symbol] one of Router::TASKS
    # @param provider [Llm::Provider]
    # @param inline [Boolean] whether the call runs inside a request (an MCP tool call)
    # @param prompt [String]
    # @param result [Hash, nil] the provider's result; nil when it raised
    # @return [void]
    def record(task:, provider:, inline:, prompt:, result:)
      Rails.logger.info("#{PREFIX} #{JSON.generate(fields(task, provider, inline, prompt, result || {}))}")
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

    def estimate(chars)
      (chars.to_f / TokenBudget::CHARS_PER_TOKEN).ceil
    end
    private_class_method :fields, :estimate
  end
end
