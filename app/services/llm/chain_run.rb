# frozen_string_literal: true

module Llm
  # One Llm::Router.generate call walking its task's chain (agent-CLI PR4, PR5). Each attempt writes
  # its own UsageLog line, numbered by `fallback_step` (0 = the first attempt), and every cloud
  # attempt goes through Llm::CloudCall (gate, budget, mask, restore).
  #
  # The fall-through rule:
  # - an agent-CLI profile entry tries its models in order (primary, then backups) while the failure
  #   is about the model (BACKUP_TRIGGERS); any other bridge or CLI failure, and a CloudCall refusal,
  #   moves on to the next chain entry;
  # - an unusable cloud answer (CloudCall::UNUSABLE: invalid JSON after the one retry, a failed
  #   round trip) skips every other cloud attempt, so a chain that lists Ollama ends there;
  # - a too-long prompt and tool use are returned (BridgeClient::STAYS), never hidden by a fallback;
  # - an Ollama outage (no answer at all) moves on; any other Ollama result is returned;
  # - a refusal (nothing sent) never replaces an earlier failure.
  #
  # A request-bound call (inline, or a summary: the summarize tool, POST /api/v1/summaries, and since
  # 1.83.0 FactKeywords::LlmWords' short JSON batches from FactKeywordsJob and scans) never uses a provider that isn't `inline?` (the host bridge) unless the
  # operator opted the summary task in (llm_inline_cloud_tasks); then it makes one cloud attempt,
  # primary model only, with the timeout capped at llm_inline_cloud_timeout. detect_contradictions
  # (inline judge) never does. The summary keeps its `inline: false` in the [llm] line (1.70.0's).
  #
  #   Llm::ChainRun.new(task: :scan, prompt: prompt, style: "concise", options: { format: "json" }, inline: false).call
  class ChainRun
    # Failures about the model, not the profile: the profile's next model may answer.
    BACKUP_TRIGGERS = %w[agent_cli_model_unavailable agent_cli_payment_required agent_cli_quota agent_cli_rate_limited
                         bridge_gate_missing].freeze
    # Tasks treated as request-bound: :summary (SummarizerService, and FactKeywords::LlmWords, whose
    # short batches follow the same rules; a skipped cloud attempt leaves its facts pending).
    REQUEST_TASKS = %i[summary].freeze
    INLINE_TIMEOUTS = (5..60)
    LOCAL_OUTAGE = "provider_unavailable"
    INLINE_SKIPPED = "inline_skipped"

    # @param task [Symbol] one of Router::TASKS
    # @param prompt [String, Llm::Prompt]
    # @param style [String]
    # @param options [Hash, nil]
    # @param inline [Boolean]
    def initialize(task:, prompt:, style:, options:, inline:)
      @task = task
      @prompt = prompt
      @style = style
      @options = options
      @inline = inline
      @step = 0
      @result = nil
      @stop = false
      @cloud_over = false
      @skipped = nil
    end

    # @return [Hash] the answering provider's result plus `provider:`, else the last real failure;
    #   `{ ok: false, error: "inline_skipped", … }` when the whole chain was skipped
    def call
      Router.chain(@task).each do |name|
        Chain.profile_entry?(name) ? run_profile(name) : run_named(name)
        break if @stop
      end
      @result || skip_result
    end

    private

    def run_profile(name)
      base = Registry.fetch(:agent_cli)
      return skip(base) if request_bound? && !inline_cloud?

      Chain.models(name).each_with_index do |(profile, model), index|
        break if @cloud_over || (index.positive? && request_bound?)

        provider = base.respond_to?(:for_attempt) ? base.for_attempt(task: @task, profile: profile, model: model, timeout_cap: timeout_cap) : base
        break unless cloud(provider) == :next_model
      end
    end

    def run_named(name)
      provider = Registry.fetch(name)
      return skip(provider) if request_bound? && !provider.inline? && !inline_cloud?

      if provider.cloud?
        return if @cloud_over

        cloud(provider.respond_to?(:for_task) ? provider.for_task(@task) : provider)
      else
        local(provider)
      end
    end

    # @return [Symbol] :next_model or :next_entry (or :stop, with @stop set)
    def cloud(provider)
      attempt = CloudCall.new(task: @task, provider: provider, prompt: @prompt, style: @style, options: @options, inline: @inline,
                              step: next_step).call
      refused = CloudCall.refusal?(attempt)
      @result = attempt unless @result && refused
      @cloud_over = true if request_bound? && !refused
      classify(attempt, refused)
    end

    def classify(attempt, refused)
      error = attempt[:error].to_s
      return :next_entry if refused
      return stop if BridgeClient::STAYS.include?(error)
      return (@cloud_over = true) && :next_entry if CloudCall::UNUSABLE.include?(error)
      return :next_model if BACKUP_TRIGGERS.include?(error)
      return :next_entry if BridgeClient.fall_through?(attempt)

      stop
    end

    def local(provider)
      step = next_step
      result = nil
      begin
        result = @options.nil? ? provider.generate(@prompt.to_s, style: @style) : provider.generate(@prompt.to_s, style: @style, options: @options)
        result = result.merge(provider: provider.name)
      ensure
        UsageLog.record(task: @task, provider: provider, inline: @inline, prompt: @prompt.to_s, result: result, step: step)
      end
      @result = result
      @stop = true unless !result[:ok] && result[:error] == LOCAL_OUTAGE && result[:http_status].nil?
    end

    def stop
      @stop = true
      :stop
    end

    def skip(provider)
      @skipped ||= provider
      nil
    end

    def skip_result
      result = { ok: false, text: nil, error: INLINE_SKIPPED, latency_ms: 0.0, provider: @skipped.name }
      UsageLog.record(task: @task, provider: @skipped, inline: @inline, prompt: "", result: result, cloud: { refused: INLINE_SKIPPED })
      result
    end

    def next_step
      (@step += 1) - 1
    end

    def request_bound?
      @inline || REQUEST_TASKS.include?(@task)
    end

    # The operator opted this task in to the cloud on request-bound calls (summary only; never inline).
    def inline_cloud?
      !@inline && REQUEST_TASKS.include?(@task) && Chain.split_models(AppSettings.llm_inline_cloud_tasks).include?(@task.to_s)
    end

    def timeout_cap
      request_bound? ? AppSettings.llm_inline_cloud_timeout.to_i.clamp(INLINE_TIMEOUTS.min, INLINE_TIMEOUTS.max) : nil
    end
  end
end
