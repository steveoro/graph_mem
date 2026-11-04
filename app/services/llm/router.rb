# frozen_string_literal: true

module Llm
  # The one way app code reaches a model (agent-CLI train PR1). Each call names its task:
  # `:summary` (SummarizerService), `:scan` (a project scan part) or `:judge` (fact supersede).
  # Each task has a chain of providers (PR4: AppSettings llm_chain_<task>, "ollama" by default, so
  # with no configuration every task runs exactly as in PR1). The result Hash comes back unchanged
  # except for one added key, `provider:`; error strings are not rewritten (the summarizer shows
  # them as `fallback_reason`). After each call it writes one UsageLog line. A provider with
  # `cloud?` true (`agent_cli`) goes through Llm::CloudCall: gate, anonymize, restore.
  #
  # The fallback rule: a CloudCall refusal (no provider call), an `agent_cli` failure
  # (Llm::BridgeClient.fall_through?) or an Ollama outage (no answer at all) moves on to the next
  # provider; a too-long prompt (413, so a scan part splits), a refused prompt and tool use are
  # returned. The default chain has no next provider, so it returns exactly what Ollama did. An inline call skips providers that aren't
  # `inline?` (the host bridge), so an MCP request never waits on one.
  #
  #   Llm::Router.usable?(:summary)                                   # => true
  #   Llm::Router.generate(:summary, prompt, style: "concise")
  #   # => { ok: true, text: "…", error: nil, latency_ms: 812.4, prompt_tokens: 1201, done_reason: "stop", provider: "ollama" }
  #   Llm::Router.client(:judge, inline: true).generate(prompt, style: "concise", options: { format: "json" })
  module Router
    TASKS = %i[summary scan judge].freeze
    # The default chain (every task's setting defaults to "ollama"), in order.
    CHAIN = %i[ollama].freeze
    DEFAULT_CHAIN = "ollama"
    # The other values a llm_chain_<task> setting may hold (a fixed list, not free text).
    CHAINS = { "agent_cli" => %i[agent_cli], "agent_cli,ollama" => %i[agent_cli ollama], "ollama,agent_cli" => %i[ollama agent_cli] }.freeze
    CHAIN_VALUES = [ DEFAULT_CHAIN, *CHAINS.keys ].freeze
    # The summary client's error for a request that failed (with an http_status when the server answered).
    LOCAL_OUTAGE = "provider_unavailable"
    # The error of an inline call whose whole chain was skipped.
    INLINE_SKIPPED = "inline_skipped"

    # A `#generate(prompt, style:, options:)` object bound to one task, for code that takes a
    # client (FactSupersede::Judge).
    Client = Data.define(:task, :inline) do
      # @param prompt [String]
      # @param style [String]
      # @param options [Hash, nil]
      # @return [Hash] see Router.generate
      def generate(prompt, style: "concise", options: nil)
        Router.generate(task, prompt, style: style, options: options, inline: inline)
      end
    end

    class << self
      # Tries the task's chain in order (see the fallback rule above).
      #
      # @param task [Symbol] one of TASKS
      # @param prompt [String, Llm::Prompt] a local provider gets `prompt.to_s`; a cloud provider
      #   needs a scoped Llm::Prompt (see Llm::CloudCall)
      # @param style [String] "concise" or "detailed"
      # @param options [Hash, nil] the request options, passed on only when given
      # @param inline [Boolean] true when the call runs inside an MCP request (detect_contradictions)
      # @return [Hash] the provider's result plus `provider:` (its name); an inline call whose whole
      #   chain was skipped gets `{ ok: false, error: "inline_skipped", … }`
      # @raise [ArgumentError] for an unknown task
      def generate(task, prompt, style:, options: nil, inline: false)
        result = nil
        skipped = nil
        chain(task).each do |name|
          provider = Registry.fetch(name)
          if inline && !provider.inline?
            skipped ||= provider
            next
          end
          if provider.cloud?
            provider = provider.for_task(task) if provider.respond_to?(:for_task)
            result = CloudCall.new(task: task, provider: provider, prompt: prompt, style: style, options: options, inline: inline).call
            next if CloudCall.refusal?(result) || BridgeClient.fall_through?(result)
          else
            result = local(task, provider, prompt.to_s, style, options, inline)
            next if local_outage?(result)
          end
          break
        end
        result || skip(task, skipped)
      end

      # @param task [Symbol] one of TASKS
      # @return [Array<Symbol>] the providers tried for the task, read from its setting on every call
      #   (CHAIN for the default "ollama", and for a value outside CHAIN_VALUES)
      # @raise [ArgumentError] for an unknown task
      def chain(task)
        check_task!(task)
        value = AppSettings.public_send(:"llm_chain_#{task}").to_s
        CHAINS.fetch(value, CHAIN)
      end

      # @param task [Symbol] one of TASKS
      # @return [Boolean] whether any provider in the task's chain is configured and enabled
      # @raise [ArgumentError] for an unknown task
      def usable?(task)
        chain(task).any? { |name| Registry.fetch(name).available? }
      end

      # @param task [Symbol] one of TASKS
      # @param inline [Boolean]
      # @return [Client]
      # @raise [ArgumentError] for an unknown task
      def client(task, inline: false)
        check_task!(task)
        Client.new(task: task, inline: inline)
      end

      private

      def local(task, provider, prompt, style, options, inline)
        result = nil
        begin
          result = provider.generate(prompt, style: style, options: options).merge(provider: provider.name)
        ensure
          UsageLog.record(task: task, provider: provider, inline: inline, prompt: prompt, result: result)
        end
      end

      # Ollama didn't answer at all (no HTTP status: refused, timed out): the next provider may. A
      # refusal with a status (400/413, an over-long prompt) is returned, so a scan part splits.
      def local_outage?(result)
        !result[:ok] && result[:error] == LOCAL_OUTAGE && result[:http_status].nil?
      end

      def skip(task, provider)
        result = { ok: false, text: nil, error: INLINE_SKIPPED, latency_ms: 0.0, provider: provider.name }
        UsageLog.record(task: task, provider: provider, inline: true, prompt: "", result: result, cloud: { refused: INLINE_SKIPPED })
        result
      end

      def check_task!(task)
        raise ArgumentError, "unknown LLM task: #{task.inspect} (one of #{TASKS.join(', ')})" unless TASKS.include?(task)
      end
    end
  end
end
