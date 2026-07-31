# frozen_string_literal: true

# Shared tokenization for query-aware ranking and search relevance.
class QueryTokenizer
  STOPWORDS = %w[
    a an and are as at be by for from has have in into is it its of on or that the their this to was were will with
  ].freeze

  class << self
    def tokenize(text, min_length: 2, stopwords: STOPWORDS)
      normalize(text)
        .split(/\s+/)
        .map(&:strip)
        .reject(&:blank?)
        .reject { |token| token.length < min_length }
        .reject { |token| stopwords.include?(token) }
        .uniq
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[^\p{Alnum}\s]+/u, " ").squeeze(" ").strip
    end

    def overlap_score(query_tokens, content)
      content_tokens = tokenize(content)
      return 0.0 if query_tokens.empty? || content_tokens.empty?

      matches = query_tokens.count { |token| content_tokens.include?(token) }
      matches.to_f / query_tokens.size
    end

    def vector_literal(vector)
      return nil if vector.blank?

      "[#{Array(vector).join(',')}]"
    end
  end
end
