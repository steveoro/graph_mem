# frozen_string_literal: true

module MemoryObservationSerializer
  module_function

  def call(observation, id_key: :observation_id, content_key: :content, include_entity_id: false)
    result = {
      id_key => observation.id,
      content_key => observation.content,
      confidence: observation.confidence,
      trust_score: observation.trust_score,
      source: observation.source,
      valid_from: observation.valid_from&.iso8601,
      valid_until: observation.valid_until&.iso8601,
      tags: observation.tags,
      status: observation.status,
      obsoleted_at: observation.obsoleted_at&.iso8601,
      obsolescence_reason: observation.obsolescence_reason,
      superseded_by_id: observation.superseded_by_id,
      created_at: observation.created_at.iso8601,
      updated_at: observation.updated_at.iso8601
    }
    result[:memory_entity_id] = observation.memory_entity_id if include_entity_id
    result
  end
end
