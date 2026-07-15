# frozen_string_literal: true

# Computes a deterministic trust score for a MemoryObservation.
#
# Score is in [0, 1]. It blends the explicit confidence, validity window,
# status, source authority, and structural support from the parent entity.
class ObservationTrustRanker
  HIGH_TRUST_SOURCES = %w[official verified system user doc docs documentation].to_set.freeze
  LOW_TRUST_SOURCES = %w[guess hearsay unsure unverified unknown].to_set.freeze

  STRUCTURAL_BOOST_FACTOR = 0.05
  HIGH_SOURCE_MULTIPLIER = 1.15
  LOW_SOURCE_MULTIPLIER = 0.85
  FUTURE_VALIDITY_PENALTY = 0.5
  EXPIRED_VALIDITY_PENALTY = 0.0

  class << self
    def rank(observation)
      return 0.0 unless observation.is_a?(MemoryObservation)

      base = (observation.confidence || 0.5).to_f
      score = base * status_factor(observation) * validity_factor(observation) * source_factor(observation)
      score += structural_boost(observation)
      score.round(4).clamp(0.0, 1.0)
    end

    private

    def status_factor(observation)
      observation.active? ? 1.0 : 0.0
    end

    def validity_factor(observation)
      now = Time.current

      if observation.valid_from.present? && now < observation.valid_from
        return FUTURE_VALIDITY_PENALTY
      end

      if observation.valid_until.present? && now > observation.valid_until
        return EXPIRED_VALIDITY_PENALTY
      end

      1.0
    end

    def source_factor(observation)
      return 1.0 if observation.source.blank?

      normalized = observation.source.to_s.downcase.strip
      return HIGH_SOURCE_MULTIPLIER if HIGH_TRUST_SOURCES.any? { |s| normalized.include?(s) }
      return LOW_SOURCE_MULTIPLIER if LOW_TRUST_SOURCES.any? { |s| normalized.include?(s) }

      1.0
    end

    def structural_boost(observation)
      entity_id = observation.memory_entity_id
      return 0.0 if entity_id.blank?

      count = MemoryRelation.where(from_entity_id: entity_id).count +
              MemoryRelation.where(to_entity_id: entity_id).count

      [ Math.log2(1 + count) * STRUCTURAL_BOOST_FACTOR, 0.2 ].min
    end
  end
end
