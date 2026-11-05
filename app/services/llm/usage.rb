# frozen_string_literal: true

module Llm
  # Per-day LLM usage counters for the System usage card (agent-CLI PR5), filled from each [llm] line
  # (Llm::UsageLog): `llm:usage:<yyyy-mm-dd>:<task>:<provider>:<field>` in Rails.cache, kept two days.
  # Numbers only: never a prompt, an answer, a project name or a path. A counting failure never fails
  # the call, and a cache that can't be read shows zeros. It runs on every call, Ollama-only chains
  # included: one synchronous Rails.cache.increment per non-zero field (3 for an ok call, at most 4).
  #
  #   Llm::Usage.count(task: "scan", provider: "ollama", outcome: "ok", fallback_step: 1, est_in_tokens: 40, est_out_tokens: 9)
  #   Llm::Usage.day(Time.zone.today)
  #   # => { "scan" => { "ollama" => { calls: 1, ok: 1, errors: 0, fallbacks: 1, refused: 0, est_tokens: 49 } } }
  module Usage
    FIELDS = %i[calls ok errors fallbacks refused est_tokens].freeze
    PROVIDERS = [ OllamaProvider::NAME, AgentCliProvider::NAME ].freeze
    KEEP = 2.days

    module_function

    # @param line [Hash] an [llm] line's fields (symbol keys)
    # @return [void]
    def count(line)
      provider = line[:provider].to_s
      return unless PROVIDERS.include?(provider) && Router::TASKS.map(&:to_s).include?(line[:task].to_s)

      increments(line).each do |field, amount|
        Rails.cache.increment(key(Budget.today, line[:task], provider, field), amount, expires_in: KEEP) if amount.positive?
      end
    rescue StandardError
      nil
    end

    # @param day [Date]
    # @return [Hash{String => Hash{String => Hash{Symbol => Integer}}}] per task and provider, only the
    #   pairs with any count
    def day(day)
      keys = Router::TASKS.product(PROVIDERS, FIELDS).to_h { |task, provider, field| [ key(day, task, provider, field), [ task.to_s, provider, field ] ] }
      values = Rails.cache.read_multi(*keys.keys)
      keys.each_with_object({}) do |(cache_key, (task, provider, field)), table|
        amount = values[cache_key].to_i
        next unless amount.positive?

        ((table[task] ||= {})[provider] ||= FIELDS.index_with(0))[field] = amount
      end
    rescue StandardError
      {}
    end

    def increments(line)
      refused = line[:refused].present?
      { calls: refused ? 0 : 1, ok: line[:outcome] == "ok" ? 1 : 0, errors: !refused && line[:outcome] != "ok" ? 1 : 0,
        fallbacks: line[:fallback_step].to_i.positive? ? 1 : 0, refused: refused ? 1 : 0,
        est_tokens: line[:est_in_tokens].to_i + line[:est_out_tokens].to_i }
    end

    def key(day, task, provider, field)
      "llm:usage:#{day.iso8601}:#{task}:#{provider}:#{field}"
    end
    private_class_method :increments, :key
  end
end
