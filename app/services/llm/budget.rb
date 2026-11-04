# frozen_string_literal: true

module Llm
  # Daily cloud budgets per task (agent-CLI PR5): llm_budget_<task>_calls and llm_budget_<task>_tokens,
  # 0 = no limit (the default). Counted per calendar day in the app time zone, in Rails.cache, under
  # `llm:budget:<yyyy-mm-dd>:<task>:{calls,tokens}` (kept two days). Every cloud send counts, retries
  # and backup models included, but only when a model answered (ok, or a CLI-level failure): a send
  # the bridge refused or never got (not configured, unreachable, busy, a gate problem) costs nothing.
  # Tokens are the [llm] line's estimates (prompt plus answer). A new day is a new key: no timestamp is
  # compared. Counting is best effort: increments are atomic per key, and the check comes before the
  # send, so each concurrent sender can overshoot by one call (cloud jobs run one at a time; opted-in
  # summaries don't). The cache must be shared across processes for one count: production's
  # solid_cache_store is; development's memory_store counts per process. Llm::CloudCall checks it
  # before each send.
  #
  #   Llm::Budget.exhausted?(:scan)            # => false
  #   Llm::Budget.charge(:scan, tokens: 1500)
  #   Llm::Budget.used(:scan)                  # => { calls: 1, tokens: 1500 }
  module Budget
    KINDS = %i[calls tokens].freeze
    EXHAUSTED = "budget_exhausted"
    KEEP = 2.days

    module_function

    # @param task [Symbol]
    # @return [Hash{Symbol => Integer}] each kind's daily limit (0 = none)
    def limits(task)
      KINDS.index_with { |kind| AppSettings.public_send(:"llm_budget_#{task}_#{kind}").to_i }
    end

    # @param task [Symbol]
    # @param day [Date]
    # @return [Hash{Symbol => Integer}] what the task used that day
    def used(task, day: today)
      KINDS.index_with { |kind| Rails.cache.read(key(day, task, kind)).to_i }
    end

    # @param task [Symbol]
    # @return [Boolean] whether a set limit is reached today; with no limit set it reads nothing. A
    #   cache that can't be read refuses (a budget is a hard stop).
    def exhausted?(task)
      set = limits(task).select { |_kind, limit| limit.positive? }
      return false if set.empty?

      spent = used(task)
      set.any? { |kind, limit| spent[kind] >= limit }
    rescue StandardError
      true
    end

    # Counts one cloud send.
    # @param task [Symbol]
    # @param tokens [Integer] estimated prompt plus answer tokens
    # @return [void]
    def charge(task, tokens:)
      day = today
      Rails.cache.increment(key(day, task, :calls), 1, expires_in: KEEP)
      Rails.cache.increment(key(day, task, :tokens), tokens.to_i, expires_in: KEEP)
    rescue StandardError
      nil
    end

    # @param answer [Hash] a provider result
    # @return [Boolean] whether a model answered (ok, or an agent CLI's own failure), so the send counts
    def chargeable?(answer)
      answer[:ok] || answer[:error].to_s.start_with?("#{AgentCliProvider::NAME}_")
    end

    # @param texts [Array<String, nil>]
    # @return [Integer] the estimated tokens of the texts (TokenBudget::CHARS_PER_TOKEN, as UsageLog)
    def estimate(*texts)
      texts.sum { |text| (text.to_s.length.to_f / TokenBudget::CHARS_PER_TOKEN).ceil }
    end

    # @return [Date] today in the app time zone
    def today
      Time.zone.today
    end

    # @return [String]
    def key(day, task, kind)
      "llm:budget:#{day.iso8601}:#{task}:#{kind}"
    end
  end
end
