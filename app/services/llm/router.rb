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
  # The walk and the fallback rule live in Llm::ChainRun (PR5: profiles and backup models); the
  # values in Llm::Chain. The default chain has no next provider, so it returns exactly what Ollama
  # did. An inline call skips providers that aren't `inline?` (the host bridge).
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
    # Every value a llm_chain_<task> setting may hold (a fixed list, not free text; Llm::Chain).
    CHAIN_VALUES = Chain::VALUES
    # The summary client's error for a request that failed (with an http_status when the server answered).
    LOCAL_OUTAGE = ChainRun::LOCAL_OUTAGE
    # PR5: the Solid Queue concurrency group and key every cloud-using job shares (one at a time).
    CLOUD_GROUP = "llm"
    CLOUD_KEY = "llm_cloud"
    # The error of an inline call whose whole chain was skipped.
    INLINE_SKIPPED = ChainRun::INLINE_SKIPPED

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
      # @return [Hash] the provider's result plus `provider:` (its name); when no provider answers,
      #   the last real failure (a cloud refusal only when nothing was tried before it); an inline
      #   call whose whole chain was skipped gets `{ ok: false, error: "inline_skipped", … }`
      # @raise [ArgumentError] for an unknown task
      def generate(task, prompt, style:, options: nil, inline: false)
        check_task!(task)
        ChainRun.new(task: task, prompt: prompt, style: style, options: options, inline: inline).call
      end

      # @param task [Symbol] one of TASKS
      # @return [Array<Symbol>] the entries tried for the task, read from its setting on every call
      #   (CHAIN for the default "ollama", and for a value outside CHAIN_VALUES)
      # @raise [ArgumentError] for an unknown task
      def chain(task)
        check_task!(task)
        value = AppSettings.public_send(:"llm_chain_#{task}").to_s
        value == DEFAULT_CHAIN ? CHAIN : (Chain.parse(value) || CHAIN)
      end

      # @param task [Symbol] one of TASKS
      # @return [Boolean] whether any provider in the task's chain is configured and enabled
      # @raise [ArgumentError] for an unknown task
      def usable?(task)
        chain(task).any? { |name| Chain.profile_entry?(name) ? profile_usable?(name) : Registry.fetch(name).available? }
      end

      # @param task [Symbol] one of TASKS
      # @return [Boolean] whether the task's chain names a cloud provider (an agent-CLI profile, or a
      #   registered provider with cloud? true); read from the setting on every call
      # @raise [ArgumentError] for an unknown task
      def cloud_chain?(task)
        chain(task).any? { |name| Chain.profile_entry?(name) || Registry.fetch(name).cloud? }
      end

      # The concurrency group and key a job uses (PR5): the shared CLOUD_GROUP / CLOUD_KEY while its
      # task's chain is cloud, so at most one cloud-using job runs at once; else the job's own.
      # Solid Queue reads them when the job is enqueued.
      #
      # @param task [Symbol] one of TASKS
      # @param own [String] the job's own group or key
      # @param shared [String] CLOUD_GROUP or CLOUD_KEY
      # @return [String]
      def concurrency_for(task, own, shared)
        cloud_chain?(task) ? shared : own
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

      def profile_usable?(name)
        base = Registry.fetch(:agent_cli)
        profile, model = Chain.models(name).first
        provider = base.respond_to?(:for_attempt) ? base.for_attempt(task: :summary, profile: profile, model: model) : base
        provider.available?
      end

      def check_task!(task)
        raise ArgumentError, "unknown LLM task: #{task.inspect} (one of #{TASKS.join(', ')})" unless TASKS.include?(task)
      end
    end
  end
end
