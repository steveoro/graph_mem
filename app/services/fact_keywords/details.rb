# frozen_string_literal: true

module FactKeywords
  # A fact's details (1.82.0): the versions, numbers and dates it states, read deterministically.
  # Two facts about the same subject whose details differ are the same fact with a different detail
  # ("Developed using Rails 8.0" / "Updated using Rails 8.1"), which may outdate the older one; with
  # the same details they are a rewording.
  #
  #   FactKeywords::Details.extract("Pinned to v1.7.2, a 5s timeout") # => #<Set: {"1.7.2", "5s"}>
  #   FactKeywords::Details.compare("Rails 8.0", "Rails 8.1")          # => :different
  #
  # Digits inside an identifier (gemma3, utf8mb4) aren't details. An incidental number (an issue id,
  # a count) is one: a rewording that changes it reads as a different detail, and the judge decides.
  module Details
    # Tried in this order, each match removed before the next pattern, each with how its match is
    # kept. A match may end a sentence ("Rails 8.0."), but not run into more digits or a word.
    PATTERNS = [
      # ISO dates, with an optional time (2026-11-12T10:00:00Z): the date, and the time on its own
      [ /(?<![\w.])(\d{4}-\d{2}-\d{2})(?:T(\d{2}:\d{2}(?::\d{2})?)Z?)?(?!\w)(?!\.\d)/i, ->(m) { [ m[1], m[2] ] } ],
      # versions and decimals, with an optional unit: 8.0, v2, v1.7.2, 3.4.12, 1.5x
      [ /(?<![\w.])(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+)[a-z]{0,8}(?!\w)(?!\.\d)/i, ->(m) { [ m[0].sub(/\Av(?=\d)/i, "") ] } ],
      # thousands: 1,000 → 1000
      [ /(?<![\w.,])\d{1,3}(?:,\d{3})+(?![\d,])/, ->(m) { [ m[0].delete(",") ] } ],
      # numbers, signed, with an optional unit: 30, -5, 5s, 10mins, 768(-dim), 2025
      [ /(?:(?<=\A)|(?<=[^\w.\-]))-?\d+[a-z]{0,8}\b|(?<![\w.\-])\d+[a-z]{0,8}\b/i, ->(m) { [ m[0] ] } ]
    ].freeze

    module_function

    # @param text [String, nil]
    # @return [Set<String>] the details, lowercase, a version's leading "v" dropped
    def extract(text)
      rest = text.to_s.dup
      PATTERNS.each_with_object(Set.new) do |(pattern, keep), found|
        rest = rest.gsub(pattern) do
          keep.call(Regexp.last_match).compact.each { |token| found << token.downcase }
          " "
        end
      end
    end

    # Directional: the first text is the newer one (the source fact, the scanned fact).
    #
    # @param first_text [String, nil] the newer fact
    # @param second_text [String, nil] the older one
    # @return [Symbol] :none (neither states a detail), :same (in any order), :dropped (only the
    #   older one states details: the newer is a vaguer restatement, never "a different detail") or
    #   :different
    def compare(first_text, second_text)
      first = extract(first_text)
      second = extract(second_text)
      return :none if first.empty? && second.empty?
      return :dropped if first.empty?

      first == second ? :same : :different
    end
  end
end
