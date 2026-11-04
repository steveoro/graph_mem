# frozen_string_literal: true

module Llm
  # One call to a provider with `cloud?` true (agent-CLI PR2; no such provider exists until PR4).
  # In order: the prompt must be a segmented Llm::Prompt, Llm::CloudGate must allow its scope, and
  # the scope's anonymizer session must mask it cleanly; any refusal returns an `ok: false` Hash
  # without calling the provider. Otherwise the masked text (plus one instruction about tokens)
  # goes to the provider and the answer is restored before the caller sees it; an answer that
  # can't be restored exactly fails as "anonymization_round_trip_failed", and so does a scan
  # answer that writes out a masked name (it would go into the graph).
  #
  #   Llm::CloudCall.new(task: :summary, provider: cloud, prompt: prompt, style: "concise", options: nil, inline: false).call
  #   # => { ok: true, text: "… Gadget Project …", provider: "cloud", … }, or
  #   # => { ok: false, text: nil, error: "cloud_not_allowed", latency_ms: 0.0, provider: "cloud" }
  class CloudCall
    # The example isn't a well-formed token, so a model that copies it can't pass it off as one.
    INSTRUCTION = "Tokens like ⟦ENT_…⟧ stand for names, paths or addresses. Copy them exactly as written; " \
                  "never translate, split, merge or invent them.\n\n"
    # Errors that mean the provider was not called: the Router tries the next provider.
    REFUSALS = %w[prompt_not_segmented cloud_not_allowed anonymizer_refused].freeze
    ROUND_TRIP_FAILED = "anonymization_round_trip_failed"

    # @param result [Hash]
    # @return [Boolean] whether the result is a refusal (no provider call)
    def self.refusal?(result)
      !result[:ok] && REFUSALS.include?(result[:error])
    end

    # @param task [Symbol]
    # @param provider [Llm::Provider] a provider with cloud? true
    # @param prompt [Llm::Prompt, String]
    # @param style [String]
    # @param options [Hash, nil]
    # @param inline [Boolean]
    # @param step [Integer] the attempt's place in the chain (UsageLog `fallback_step`; PR5)
    def initialize(task:, provider:, prompt:, style:, options:, inline:, step: 0)
      @task = task
      @provider = provider
      @prompt = prompt
      @style = style
      @options = options
      @inline = inline
      @step = step
      @log = { anonymized: true }
    end

    # @return [Hash] the provider's result (restored) plus `provider:`, or a refusal
    def call
      return refuse("prompt_not_segmented") unless @prompt.is_a?(Prompt)
      return refuse("cloud_not_allowed") unless CloudGate.allowed?(@prompt.scope)

      session = @prompt.scope.session
      masked = begin
        session.mask(@prompt)
      rescue Anonymizer::Refused => e
        return refuse("anonymizer_refused", detail: e.kind)
      end
      @log.merge!(masked: masked.counts, secrets: masked.secrets)
      send_masked(session, INSTRUCTION + masked.text)
    end

    private

    def send_masked(session, text)
      result = nil
      begin
        answer = @options.nil? ? @provider.generate(text, style: @style) : @provider.generate(text, style: @style, options: @options)
        result = restore(session, answer).merge(provider: @provider.name)
      ensure
        UsageLog.record(task: @task, provider: @provider, inline: @inline, prompt: text, result: result, cloud: @log, step: @step)
      end
    end

    def restore(session, answer)
      return answer unless answer[:ok]

      unmasked = session.unmask(answer[:text], json: @options.to_h.symbolize_keys[:format].to_s == "json")
      @log.merge!(round_trip: "ok", leftover_out: unmasked.leftovers)
      return failed(answer) if @task == :scan && unmasked.leftovers.positive?

      answer.merge(text: unmasked.text)
    rescue Anonymizer::RoundTripFailed
      failed(answer)
    end

    def failed(answer)
      @log[:round_trip] = "failed"
      answer.merge(ok: false, text: nil, error: ROUND_TRIP_FAILED)
    end

    def refuse(reason, detail: nil)
      result = { ok: false, text: nil, error: reason, latency_ms: 0.0, provider: @provider.name }
      UsageLog.record(task: @task, provider: @provider, inline: @inline, prompt: "", result: result,
                      cloud: @log.merge(refused: reason, refused_detail: detail&.to_s).compact, step: @step)
      result
    end
  end
end
