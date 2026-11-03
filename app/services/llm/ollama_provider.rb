# frozen_string_literal: true

module Llm
  # Today's backend: SummaryGenerationClient, over either of its transports (Ollama's
  # /api/generate or an OpenAI-compatible /chat/completions; both are named "ollama"). It calls
  # the client at class level on every request, never a held instance, so the settings reset
  # (`SummaryGenerationClient.reset_instance!`) and the specs' class-level stubs keep working,
  # and it passes `options:` only when the caller did, so each call keeps its exact shape.
  #
  #   Llm::OllamaProvider.new.generate("Summarize…", style: "concise")
  #   # => { ok: true, text: "…", error: nil, latency_ms: 812.4, prompt_tokens: 1201, done_reason: "stop" }
  class OllamaProvider < Provider
    NAME = "ollama"

    # @return [String] "ollama"
    def name
      NAME
    end

    # @param prompt [String]
    # @param style [String] "concise" or "detailed"
    # @param options [Hash, nil] passed through as `options:` unless nil
    # @return [Hash] SummaryGenerationClient's result, unchanged
    def generate(prompt, style:, options: nil)
      return SummaryGenerationClient.generate(prompt, style: style) if options.nil?

      SummaryGenerationClient.generate(prompt, style: style, options: options)
    end

    # @return [Boolean] SummarizationConfig.llm_usable?
    def available?
      SummarizationConfig.llm_usable?
    end

    # @return [String, nil] the configured summary model
    def model
      SummarizationConfig.resolved_config[:model].presence
    end
  end
end
