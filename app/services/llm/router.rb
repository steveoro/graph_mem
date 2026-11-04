# frozen_string_literal: true

module Llm
  # The one way app code reaches a model (agent-CLI train PR1). Each call names its task:
  # `:summary` (SummarizerService), `:scan` (a project scan part) or `:judge` (fact supersede).
  # PR1 sends every task to the `:ollama` provider and returns its result Hash unchanged except
  # for one added key, `provider:`; error strings are not rewritten (the summarizer shows them as
  # `fallback_reason`). After each call it writes one UsageLog line. A provider with `cloud?` true
  # (none until PR4) goes through Llm::CloudCall: gate, anonymize, restore.
  #
  #   Llm::Router.usable?(:summary)                                   # => true
  #   Llm::Router.generate(:summary, prompt, style: "concise")
  #   # => { ok: true, text: "…", error: nil, latency_ms: 812.4, prompt_tokens: 1201, done_reason: "stop", provider: "ollama" }
  #   Llm::Router.client(:judge, inline: true).generate(prompt, style: "concise", options: { format: "json" })
  module Router
    TASKS = %i[summary scan judge].freeze
    # The providers tried for every task, in order (PR4 makes the chain per task).
    CHAIN = %i[ollama].freeze

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
      # Tries the CHAIN's providers in order; a cloud provider's refusal (no provider call) moves on
      # to the next one, any other result is returned.
      #
      # @param task [Symbol] one of TASKS
      # @param prompt [String, Llm::Prompt] a local provider gets `prompt.to_s`; a cloud provider
      #   needs a scoped Llm::Prompt (see Llm::CloudCall)
      # @param style [String] "concise" or "detailed"
      # @param options [Hash, nil] the request options, passed on only when given
      # @param inline [Boolean] true when the call runs inside an MCP request (detect_contradictions)
      # @return [Hash] the provider's result plus `provider:` (its name)
      # @raise [ArgumentError] for an unknown task
      def generate(task, prompt, style:, options: nil, inline: false)
        check_task!(task)
        result = nil
        CHAIN.each do |name|
          provider = Registry.fetch(name)
          if provider.cloud?
            provider = provider.for_task(task) if provider.respond_to?(:for_task)
            result = CloudCall.new(task: task, provider: provider, prompt: prompt, style: style, options: options, inline: inline).call
            next if CloudCall.refusal?(result)
          else
            result = local(task, provider, prompt.to_s, style, options, inline)
          end
          break
        end
        result
      end

      # @param task [Symbol] one of TASKS
      # @return [Boolean] whether the task's provider is configured and enabled
      # @raise [ArgumentError] for an unknown task
      def usable?(task)
        check_task!(task)
        Registry.fetch(CHAIN.first).available?
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

      def check_task!(task)
        raise ArgumentError, "unknown LLM task: #{task.inspect} (one of #{TASKS.join(', ')})" unless TASKS.include?(task)
      end
    end
  end
end
