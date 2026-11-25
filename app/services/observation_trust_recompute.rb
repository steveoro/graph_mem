# frozen_string_literal: true

# Recomputes stored observation trust scores in bulk (ObservationTrustRanker, written with
# update_column, so updated_at stays a content timestamp). The relation after_commit hook runs it per
# created or deleted edge; bulk writers that suppress that hook (the JSON import, the relation-type
# sweep) and the SQL import's follow-up, whose raw SQL skips every callback, call it once.
#
#   ObservationTrustRecompute.call(entity_ids: [ 12, 14 ])                  # their active facts
#   ObservationTrustRecompute.call(entity_ids: [ 12 ], observation_ids: [ 40 ]) # and fact 40, any status
class ObservationTrustRecompute
  # @param entity_ids [Enumerable<Integer>] every active observation of these entities (the
  #   structural boost counts the entity's relations)
  # @param observation_ids [Enumerable<Integer>] these observations too, whatever their status (a
  #   retired one keeps only the structural boost)
  # @return [Integer] the observations rewritten
  def self.call(entity_ids: [], observation_ids: [])
    entity_ids = entity_ids.to_a.compact.uniq
    observation_ids = observation_ids.to_a.compact.uniq
    rewritten = 0
    entity_ids.each_slice(500) do |slice|
      MemoryObservation.where(memory_entity_id: slice, status: MemoryObservation::ACTIVE_STATUS).find_each { |row| rewritten += rank!(row) }
    end
    observation_ids.each_slice(500) do |slice|
      MemoryObservation.where(id: slice).where.not(memory_entity_id: entity_ids, status: MemoryObservation::ACTIVE_STATUS)
                       .find_each { |row| rewritten += rank!(row) }
    end
    rewritten
  end

  def self.rank!(observation)
    observation.update_column(:trust_score, ObservationTrustRanker.rank(observation))
    1
  end
  private_class_method :rank!
end
