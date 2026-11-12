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
    # Tried in this order, each match removed before the next pattern.
    # A match may end a sentence ("Rails 8.0."), but not run into more digits or a word.
    PATTERNS = [
      /(?<![\w.])\d{4}-\d{2}-\d{2}(?!\w)(?!\.\d)/,                   # ISO dates
      /(?<![\w.])(?:v\d+(?:\.\d+)*|\d+(?:\.\d+)+)(?!\w)(?!\.\d)/i,   # versions: 8.0, v2, v1.7.2, 3.4.12
      /(?<![\w.])\d+[a-z]{0,3}\b/i                                     # numbers with an optional unit: 30, 5s, 768(-dim), 2025
    ].freeze

    module_function

    # @param text [String, nil]
    # @return [Set<String>] the details, lowercase, a version's leading "v" dropped
    def extract(text)
      rest = text.to_s.dup
      PATTERNS.each_with_object(Set.new) do |pattern, found|
        rest = rest.gsub(pattern) do |match|
          found << match.downcase.sub(/\Av(?=\d)/, "")
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
