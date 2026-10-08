# frozen_string_literal: true

# Token-budget helpers for recall endpoints.
#
# Token counts are estimated deterministically with the common ~4-chars-per-token
# heuristic — no tokenizer or LLM call. Estimates are deliberately rough; the
# guarantee is the packed payload stays under budget, not a precise count.
class TokenBudget
  CHARS_PER_TOKEN = 4

  Result = Struct.new(:items, :estimated_tokens, :truncated, keyword_init: true)

  class << self
    # @param payload [Object] anything JSON-serializable
    # @return [Integer] estimated token count
    def estimate(payload)
      (JSON.generate(payload).length.to_f / CHARS_PER_TOKEN).ceil
    end

    # Greedily packs items (already ranked) until the next item would exceed
    # `max_tokens`. Whole items only — nothing is cut mid-item, so a first item
    # larger than the budget yields an empty result flagged as truncated.
    #
    # @param items [Array<Object>] JSON-serializable payload items
    # @param max_tokens [Integer, nil] nil disables budgeting
    # @return [Result]
    def fit(items, max_tokens:)
      items = Array(items)
      return Result.new(items: items, estimated_tokens: estimate(items), truncated: false) if max_tokens.blank?

      budget = max_tokens.to_i
      kept = []
      used = 0
      truncated = false

      items.each do |item|
        cost = estimate(item)
        if used + cost > budget
          truncated = true
          break
        end
        kept << item
        used += cost
      end

      Result.new(items: kept, estimated_tokens: used, truncated: truncated)
    end

    def diagnostics(max_tokens:, estimated_tokens:, truncated:)
      {
        max_tokens: max_tokens.to_i,
        estimated_tokens: estimated_tokens,
        truncated: truncated
      }
    end
  end
end
