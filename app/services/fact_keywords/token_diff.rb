# frozen_string_literal: true

module FactKeywords
  # The tokens two facts differ in, and whether the difference is a plain value change (1.92.0):
  # the same fact written again with another value ("Port: 3000", later "Port: 3001"). Used by
  # ContradictionDetector (pairing), ReviewPolicies::AutoApplyContradiction (the gate) and the
  # contradiction card (the highlight). Deterministic, in memory, no LLM.
  #
  #   FactKeywords::TokenDiff.value_change("Port: 3000", "Port: 3001")
  #   # => { class: :key_value, key: "port", from: "3000", to: "3001", count: 1 }
  #   FactKeywords::TokenDiff.value_change("Timeout: 5s", "Timeout: 5m") # => nil (the unit changed)
  #   FactKeywords::TokenDiff.diff("Port: 3000", "Port: 3001")
  #   # => { left: [#<data Span offset=6, length=4, text="3000">], right: [#<data Span … "3001">] }
  #
  # A value is a boolean word, a whole number, or a dotted number or version; two values compare
  # only within one of those kinds and with the same unit. Everything unsure answers nil: the pair
  # then stays an ordinary review row.
  module TokenDiff
    # A token of the text: `offset` and `length` in characters.
    Span = Data.define(:offset, :length, :text)

    # The view highlights only when each side has 1..HIGHLIGHT_MAX differing tokens.
    HIGHLIGHT_MAX = 3
    # The most differing tokens a free-text value change may have (per side).
    FREE_TEXT_MAX = 2
    # Texts longer than this many tokens aren't diffed with the LCS (the card shows 300 characters).
    DIFF_TOKEN_LIMIT = 400

    # Dates as one token (never a value), then numbers and versions with an attached unit, then words.
    TOKEN = /
      \d{4}-\d{2}-\d{2}(?!\d)
      | (?<![\w.])-?\d{1,3}(?:,\d{3})+(?![\w,])
      | (?<![\w.])-?(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)*)(?:[a-z]{1,8}|%)?(?![\w])
      | [[:alnum:]_]+(?:['’][[:alnum:]_]+)*
    /xi

    BOOLEANS = %w[true false yes no on off enabled disabled].freeze
    NUMBER = /\A(?<number>-?(?:\d{1,3}(?:,\d{3})+|\d+))(?<unit>[a-z]{1,8}|%)?\z/i
    DOTTED = /\A(?<number>-?(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+))(?<unit>[a-z]{1,8}|%)?\z/i
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    # One "Key: value" or "key = value" line, with an optional final period.
    KEY_VALUE = /\A(?<key>[^:=\n]*[[:alpha:]][^:=\n]*?)\s*[:=]\s*(?<value>[^:=\n]+?)\s*\.?\z/
    LIST_MARK = /[,;|]|\band\b|\bor\b/i

    module_function

    # @param text [String, nil]
    # @return [Array<Span>] the tokens in order
    def tokens(text)
      found = []
      text.to_s.scan(TOKEN) do
        match = Regexp.last_match
        found << Span.new(offset: match.begin(0), length: match[0].length, text: match[0])
      end
      found
    end

    # The tokens of each text outside their longest common token subsequence (case-insensitive).
    #
    # @param first [String, nil]
    # @param second [String, nil]
    # @return [Hash{Symbol => Array<Span>}] `{ left:, right: }`; both empty when a text is too long to diff
    def diff(first, second)
      left = tokens(first)
      right = tokens(second)
      return { left: [], right: [] } if left.size > DIFF_TOKEN_LIMIT || right.size > DIFF_TOKEN_LIMIT

      kept_left, kept_right = common(left.map { |t| t.text.downcase }, right.map { |t| t.text.downcase })
      { left: left.each_index.reject { |i| kept_left.include?(i) }.map { |i| left[i] },
        right: right.each_index.reject { |i| kept_right.include?(i) }.map { |i| right[i] } }
    end

    # Whether the second text is the first one with another value.
    #
    # @param first [String, nil] the older fact's text (its values are `from`)
    # @param second [String, nil] the newer one's (`to`)
    # @return [Hash, nil] `{ class: :key_value | :free_text, key:, from:, to:, count: }` (key nil for
    #   free text; from/to joined with ", " when two tokens changed), or nil when it isn't one
    def value_change(first, second)
      first = first.to_s.strip
      second = second.to_s.strip
      return nil if first.empty? || second.empty? || first.casecmp?(second)
      return nil if first.include?("\n") || second.include?("\n")
      return nil if ContradictionDetector::DATED_EVENT.match?(first) || ContradictionDetector::DATED_EVENT.match?(second)

      pair = [ KEY_VALUE.match(first), KEY_VALUE.match(second) ]
      # Two key-value lines are judged as such only: a different key or a list never falls back to free text.
      return key_value_change(*pair) if pair.all?

      free_text_change(first, second)
    end

    # @param token [String]
    # @return [Hash, nil] `{ kind: :boolean | :number | :dotted, value:, unit: }`, nil when not a value
    def value(token)
      text = token.to_s.downcase
      return { kind: :boolean, value: text, unit: nil } if BOOLEANS.include?(text)
      return nil if DATE.match?(text)

      if (match = NUMBER.match(text))
        { kind: :number, value: match[:number].delete(","), unit: match[:unit] }
      elsif (match = DOTTED.match(text))
        { kind: :dotted, value: match[:number].sub(/\Av/, ""), unit: match[:unit] }
      end
    end

    # --- private helpers (module_function makes them callable; treat as internal) ----------------

    def key_value_change(first, second)
      return nil unless normalize(first[:key]) == normalize(second[:key])

      from = single_value(first[:value])
      to = single_value(second[:value])
      return nil unless from && to && comparable?(from, to)

      { class: :key_value, key: normalize(first[:key]), from: from[:text], to: to[:text], count: 1 }
    end

    # A value part that is one value, with an optional unit word after a number ("10 MB").
    def single_value(part)
      return nil if LIST_MARK.match?(part)

      words = tokens(part)
      found = value(words.first&.text)
      return nil unless found && words.size <= 2 && tokens_only?(part, words)
      return found.merge(text: words.first.text) if words.size == 1
      return nil unless found[:kind] != :boolean && found[:unit].nil? && words.last.text.match?(/\A[[:alpha:]%]+\z/)

      found.merge(unit: words.last.text.downcase, text: part.strip)
    end

    # Nothing but the tokens and blanks: no brackets, slashes or other marks around the value.
    def tokens_only?(part, words)
      part.gsub(/\s+/, "") == words.map(&:text).join
    end

    def free_text_change(first, second)
      left = tokens(first)
      right = tokens(second)
      return nil unless left.size == right.size

      changed = left.each_index.reject { |i| left[i].text.casecmp?(right[i].text) }
      return nil unless (1..FREE_TEXT_MAX).cover?(changed.size)
      return nil unless changed.all? { |i| comparable?(value(left[i].text), value(right[i].text)) }
      return nil if changed.any? { |i| listed?(first, left, i) || listed?(second, right, i) }

      { class: :free_text, key: nil, from: changed.map { |i| left[i].text }.join(", "),
        to: changed.map { |i| right[i].text }.join(", "), count: changed.size }
    end

    # Two values of the same kind and unit that differ.
    def comparable?(from, to)
      from && to && from[:kind] == to[:kind] && from[:unit] == to[:unit] && from[:value] != to[:value]
    end

    # Whether the token sits in a list: a list mark right before or after it, or "and" / "or" next to it.
    def listed?(text, words, index)
      span = words[index]
      before = text[0...span.offset].to_s.rstrip[-1]
      after = text[(span.offset + span.length)..].to_s.lstrip[0]
      neighbours = [ (words[index - 1] if index.positive?), words[index + 1] ].compact.map { |word| word.text.downcase }
      [ before, after ].any? { |mark| mark && ",;|/".include?(mark) } || neighbours.intersect?(%w[and or])
    end

    def normalize(key)
      key.to_s.downcase.gsub(/\s+/, " ").strip
    end

    # The indexes of a longest common subsequence in each list.
    def common(left, right)
      table = Array.new(left.size + 1) { Array.new(right.size + 1, 0) }
      left.each_index do |i|
        right.each_index do |j|
          table[i + 1][j + 1] = left[i] == right[j] ? table[i][j] + 1 : [ table[i][j + 1], table[i + 1][j] ].max
        end
      end
      walk_back(table, left, right)
    end

    def walk_back(table, left, right)
      kept_left = Set.new
      kept_right = Set.new
      i = left.size
      j = right.size
      while i.positive? && j.positive?
        if left[i - 1] == right[j - 1]
          kept_left << (i - 1)
          kept_right << (j - 1)
          i -= 1
          j -= 1
        elsif table[i - 1][j] >= table[i][j - 1]
          i -= 1
        else
          j -= 1
        end
      end
      [ kept_left, kept_right ]
    end
  end
end
