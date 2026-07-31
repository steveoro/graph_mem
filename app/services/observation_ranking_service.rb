# frozen_string_literal: true

# Shared observation ordering for read tools and summarization.
class ObservationRankingService
  DEFAULT_LIMIT = nil

  class << self
    def rank(observations, query: nil, mode: nil, limit: DEFAULT_LIMIT)
      observations = Array(observations)
      mode = normalize_mode(mode, query)

      ranked = case mode
      when "relevance"
        rank_by_relevance(observations, query)
      when "trust"
        rank_by_trust(observations)
      else
        observations
      end

      limit.present? && limit.to_i.positive? ? ranked.first(limit.to_i) : ranked
    end

    def normalize_mode(mode, query)
      return mode.to_s if mode.present?

      query.to_s.strip.present? ? "relevance" : "trust"
    end

    private

    def rank_by_trust(observations)
      observations.sort_by.with_index do |observation, index|
        [ -observation.trust_score.to_f, -observation.confidence.to_f, index ]
      end
    end

    def rank_by_relevance(observations, query)
      ranker = ObservationRelevanceRanker.new(query)
      scores = ranker.score_batch(observations)

      observations.each_with_index.sort_by do |observation, index|
        [ -scores[index].to_f, -observation.trust_score.to_f, -observation.confidence.to_f, index ]
      end.map(&:first)
    end
  end
end
