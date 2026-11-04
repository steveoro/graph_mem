# frozen_string_literal: true

module Llm
  # Turns an agent CLI's answer (the bridge's `text`, already unwrapped from the CLI's envelope)
  # into what the call sites expect from Ollama (agent-CLI PR4). It runs before Llm::CloudCall
  # restores the tokens, so it only ever sees masked text.
  #
  # With `format: "json"` (scan, judge) it drops one surrounding Markdown fence and the prose
  # around the outermost (the longest) JSON object or array, found by a bracket scan that respects strings (no
  # regex backtracking; answers over SCAN_CAP are left as they are). Without a parseable value the
  # text goes on unchanged, to the caller's own "not valid JSON" path. Otherwise (summary) it
  # trims. Then it applies the caller's `max_output_length`, the same cut the summary client makes
  # (DEFAULT_MAX_OUTPUT_LENGTH, nil for none), never splitting a ⟦…⟧ token.
  #
  #   Llm::ResponseNormalizer.call("Sure!\n```json\n{\"a\": 1}\n```", { format: "json" }) # => "{\"a\": 1}"
  #   Llm::ResponseNormalizer.call("  A summary.\n", nil)                                  # => "A summary."
  module ResponseNormalizer
    SCAN_CAP = 256 * 1024
    # The summary client's default cut (its MAX_OUTPUT_LENGTH; the spec checks they match).
    DEFAULT_MAX_OUTPUT_LENGTH = 8_192
    # How many opening brackets the scan tries before giving up (prose may hold a stray one).
    MAX_TRIES = 16
    OPENERS = { "{" => "}", "[" => "]" }.freeze

    module_function

    # @param text [String] the answer
    # @param options [Hash, nil] the caller's request options (`format:`, `max_output_length:`)
    # @return [String]
    def call(text, options)
      opts = options.to_h.symbolize_keys
      body = opts[:format].to_s == "json" ? json_body(text.to_s) : text.to_s.strip
      cut(body, opts.key?(:max_output_length) ? opts[:max_output_length] : DEFAULT_MAX_OUTPUT_LENGTH)
    end

    # @param text [String]
    # @return [String] the outermost JSON value in the text, or the text unchanged
    def json_body(text)
      return text if text.bytesize > SCAN_CAP

      chars = unfenced(text.strip).chars # an Array: String#[] on UTF-8 text is linear per call
      best = outermost(chars)
      best ? chars[best].join : text
    end

    # @return [Range, nil] the longest bracketed span that parses as JSON, among the first MAX_TRIES
    #   openers outside a span already found (so a stray "[1]" in the prose never wins over the answer)
    def outermost(chars)
      best = nil
      tries = 0
      chars.each_index do |start|
        next unless OPENERS.key?(chars[start]) && !best&.cover?(start)
        break if (tries += 1) > MAX_TRIES

        stop = closing(chars, start)
        next unless stop && parses?(chars[start..stop].join)

        best = (start..stop) if best.nil? || (stop - start) > (best.end - best.begin)
      end
      best
    end

    # @return [String] the text inside one surrounding ``` fence (an info string like `json` is
    #   dropped), or the text as it is
    def unfenced(text)
      return text unless text.start_with?("```") && text.end_with?("```") && text.length > 6

      first_break = text.index("\n")
      return text unless first_break

      text[(first_break + 1)...-3].strip
    end

    # @return [Integer, nil] the index of the bracket that closes the one at `start`
    def closing(chars, start)
      stack = []
      in_string = false
      escaped = false
      (start...chars.length).each do |i|
        char = chars[i]
        if in_string
          if escaped then escaped = false
          elsif char == "\\" then escaped = true
          elsif char == '"' then in_string = false
          end
        elsif char == '"' then in_string = true
        elsif OPENERS.key?(char) then stack << OPENERS[char]
        elsif OPENERS.value?(char)
          return nil unless stack.pop == char
          return i if stack.empty?
        end
      end
      nil
    end

    def parses?(candidate)
      JSON.parse(candidate)
      true
    rescue JSON::ParserError
      false
    end

    # @return [String] the first `max_length` characters, backed off to before a ⟦…⟧ token the cut
    #   would split
    def cut(text, max_length)
      return text if max_length.nil? || text.length <= max_length.to_i

      kept = text[0, max_length.to_i]
      open = kept.rindex("⟦")
      open && !kept.index("⟧", open) ? kept[0, open] : kept
    end
    private_class_method :outermost, :unfenced, :closing, :parses?, :cut
  end
end
