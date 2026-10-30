# frozen_string_literal: true

class ProjectScanner
  # The scan's token estimate (F-3): bytes, not characters, at 3 bytes per token by default
  # (setting project_scan_bytes_per_token), so source code (denser than prose) and non-ASCII text
  # are over-counted, never under-counted. No tokenizer.
  #
  #   ProjectScanner::TokenEstimate.tokens("x" * 3000)                               # => 1000
  #   ProjectScanner::TokenEstimate.input_budget(num_ctx: 8192, num_predict: 2048, prompt_tokens: 700) # => 4900
  module TokenEstimate
    BYTES_PER_TOKEN = 3
    # The share of the free window the files may fill.
    MARGIN = 0.9

    module_function

    # @param text [String, nil]
    # @param bytes_per_token [Numeric]
    # @return [Integer] the estimated tokens
    def tokens(text, bytes_per_token: BYTES_PER_TOKEN)
      (text.to_s.bytesize / bytes_per_token.to_f).ceil
    end

    # @param tokens [Integer]
    # @param bytes_per_token [Numeric]
    # @return [Integer] the bytes that estimate at most `tokens`
    def bytes(tokens, bytes_per_token: BYTES_PER_TOKEN)
      (tokens.to_i * bytes_per_token.to_f).floor
    end

    # floor((num_ctx − num_predict − prompt_tokens) × MARGIN), never below 0.
    #
    # @param num_ctx [Integer] the model's context window
    # @param num_predict [Integer] the answer budget
    # @param prompt_tokens [Integer] the estimate of the prompt without files
    # @return [Integer] the tokens one part's files may use
    def input_budget(num_ctx:, num_predict:, prompt_tokens:)
      [ ((num_ctx.to_i - num_predict.to_i - prompt_tokens.to_i) * MARGIN).floor, 0 ].max
    end
  end
end
