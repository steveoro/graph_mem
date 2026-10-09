# frozen_string_literal: true

# Token-budget helpers for recall endpoints.
#
# Token counts are estimated deterministically with the common ~4-chars-per-token
# heuristic — no tokenizer or LLM call. Estimates are deliberately rough; the
# guarantee is the packed payload stays under budget, not a precise count.
class TokenBudget
  CHARS_PER_TOKEN = 4
  MAX_TOKENS = 100_000

  Result = Struct.new(:items, :estimated_tokens, :truncated, :items_before, :envelope_tokens, keyword_init: true) do
    def items_after
      items.size
    end

    def dropped_count
      items_before - items.size
    end
  end

  # Worst-case digit width for diagnostics seeds — real values written
  # after a fit are always narrower, so envelopes counted with the seed
  # over-cover the final diagnostics.
  PLACEHOLDER_NUMBER = 9_999_999_999

  # Top-level fields ToolSuccessResponse appends around every tool payload
  # AFTER the services fit their items (version, a next_move hint, and a
  # context block when no project context is active). Padded generously —
  # the real wrapper is ~50 tokens — so envelopes counted before the
  # wrapper lands stay conservative.
  WRAPPER_RESERVE = {
    version: "9.9.9.9",
    next_move: "x" * 120,
    context: { status: "none", next_move: "x" * 120 }
  }.freeze

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
    # @param max_tokens [Integer, nil] nil disables budgeting (validated
    #   Integer upstream — see validate_max_tokens!)
    # @param envelope_tokens [Integer] tokens already spent on the response
    #   envelope (everything except the items); items pack into the remainder
    # @return [Result]
    def fit(items, max_tokens:, envelope_tokens: 0)
      items = Array(items)
      return Result.new(items: items, estimated_tokens: estimate(items), truncated: false,
                        items_before: items.size, envelope_tokens: envelope_tokens.to_i) if max_tokens.blank?

      budget = max_tokens - envelope_tokens.to_i
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

      Result.new(items: kept, estimated_tokens: used, truncated: truncated,
                 items_before: items.size, envelope_tokens: envelope_tokens.to_i)
    end

    # Counts a fixed response envelope once — mode/pagination/retrieval
    # diagnostics and other item-less keys — then packs items into what is
    # left. When the envelope alone exceeds the budget the result is empty
    # and flagged truncated. The envelope hash should be the response
    # skeleton with empty item lists.
    def fit_with_envelope(items, envelope:, max_tokens:)
      fit(items, max_tokens: max_tokens, envelope_tokens: estimate(envelope))
    end

    # Validates a user-supplied max_tokens param: an Integer or base-10 digit
    # String in 1..MAX_TOKENS. Returns the validated Integer (or nil for nil
    # input); callers must use the return value, never re-parse the input.
    def validate_max_tokens!(value, error_class: ArgumentError)
      return nil if value.nil?

      integer = case value
      when Integer then value
      when String then value.strip.match?(/\A\d+\z/) ? value.strip.to_i : nil
      end
      return integer if integer&.between?(1, MAX_TOKENS)

      raise error_class, "max_tokens must be an integer between 1 and #{MAX_TOKENS}"
    end

    def diagnostics(max_tokens:, estimated_tokens:, truncated:, items_before: nil, items_after: nil,
                    envelope_tokens: nil, dropped_on_page: nil)
      {
        max_tokens: max_tokens.to_i,
        estimated_tokens: estimated_tokens,
        truncated: truncated,
        envelope_tokens: envelope_tokens,
        items_before: items_before,
        items_after: items_after,
        dropped_on_page: dropped_on_page
      }.compact
    end

    # A diagnostics hash seeded at worst-case width, to be merged into a
    # response BEFORE its envelope is estimated and overwritten with real
    # values after the fit.
    def diagnostics_placeholder(max_tokens:, dropped_on_page: false)
      diagnostics(
        max_tokens: max_tokens,
        estimated_tokens: PLACEHOLDER_NUMBER,
        truncated: false,
        envelope_tokens: PLACEHOLDER_NUMBER,
        items_before: PLACEHOLDER_NUMBER,
        items_after: PLACEHOLDER_NUMBER,
        dropped_on_page: (PLACEHOLDER_NUMBER if dropped_on_page)
      )
    end
  end
end
