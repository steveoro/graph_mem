# frozen_string_literal: true

module Llm
  # The contract every LLM backend implements (agent-CLI train PR1). A provider turns a prompt
  # into the result Hash the call sites read today, and never raises for a failed request:
  #
  #   { ok: true, text: "…", error: nil, latency_ms: 812.4, prompt_tokens: 1201, done_reason: "stop" }
  #   { ok: false, text: nil, error: "provider_unavailable", latency_ms: 30.1, http_status: 413 }
  #
  # `ok`, `text`, `error` and `latency_ms` are always there (`latency_ms` may be nil); a provider
  # may add `prompt_tokens`, `done_reason` and `http_status`, which ChunkedExtraction reads to
  # decide whether to split a scan part. Callers go through Llm::Router, never a provider.
  class Provider
    # @return [String] the name the Router adds to each result as `provider:`
    def name
      raise NotImplementedError, "#{self.class.name} must define #name"
    end

    # @param prompt [String]
    # @param style [String] "concise" or "detailed"
    # @param options [Hash, nil] the caller's request options (see SummaryGenerationClient#generate);
    #   nil when the caller passes none
    # @return [Hash] the result described above
    def generate(prompt, style:, options: nil)
      raise NotImplementedError, "#{self.class.name} must define #generate"
    end

    # @return [Boolean] whether the provider is configured and enabled
    def available?
      false
    end

    # @return [Boolean] whether a request leaves the machine for a cloud model
    def cloud?
      false
    end

    # @return [String, nil] the model the next request goes to, for the usage line
    def model
      nil
    end
  end
end
