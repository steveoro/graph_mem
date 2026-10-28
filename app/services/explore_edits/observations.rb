# frozen_string_literal: true

class ExploreEdits
  # Add, edit (supersede, so history is kept) and retire observations from the panel.
  module Observations
    # A TEXT column holds 65,535 bytes: at four bytes a character, this always fits.
    MAX_OBSERVATION_LENGTH = 16_000
    DUPLICATE_OBSERVATION = "This observation already exists."
    SIMILAR_OBSERVATION = "A similar observation already exists."
    INACTIVE = "Only active observations can be changed."

    # The exact duplicate always blocks; a semantic match blocks unless `force`; with vectors
    # unavailable the semantic check is skipped and the message says so (Decision 3).
    #
    # @param entity [MemoryEntity]
    # @param content [String]
    # @param perspective [String, nil] one of MemoryObservation::PERSPECTIVES, or blank
    # @param force [Boolean] add despite a semantic match ("Add anyway")
    # @return [Hash] on a match: `duplicate_id:` (exact) or `similar:` ({ id:, content: })
    def add_observation(entity, content:, perspective: nil, force: false)
      content = content.to_s.strip
      perspective = perspective.presence
      error = observation_input_error(content, perspective)
      return refused(error) if error

      exact = MemoryObservation.active.find_by(memory_entity_id: entity.id, content: content)
      return refused(DUPLICATE_OBSERVATION, duplicate_id: exact.id) if exact

      checked = true
      unless force
        similar, checked = similar_observation(entity, content)
        return refused(SIMILAR_OBSERVATION, similar: similar) if similar
      end

      record("explore.observation_add", entity, "added an observation to '#{entity.name}'") do
        MemoryObservation.create!(memory_entity: entity, content: content, perspective: perspective, confidence: nil,
                                  source: "explore", valid_from: nil, valid_until: nil, tags: [])
        done(checked ? "Observation added." : "Observation added (similarity not checked: embeddings unavailable).", entity)
      end
    end

    # Supersedes the observation with the new text and perspective (the old one stays, superseded).
    #
    # @param observation [MemoryObservation]
    # @return [Hash]
    def update_observation(observation, content:, perspective: nil)
      return refused(INACTIVE) unless observation.active?

      content = content.to_s.strip
      perspective = perspective.presence
      error = observation_input_error(content, perspective)
      return refused(error) if error
      return refused(NOTHING_CHANGED) if content == observation.content && perspective == observation.perspective

      entity = observation.memory_entity
      record("explore.observation_edit", entity, "edited an observation of '#{entity.name}'") do
        GraphEditService.execute_one("update_observation", { observation_id: observation.id, text_content: content,
                                                             perspective: perspective, supersede: true, reason: "edited in Explore" })
        done("Observation updated.", entity)
      end
    end

    # @param observation [MemoryObservation]
    # @param reason [String, nil] at most MAX_REASON_LENGTH characters
    # @return [Hash]
    def retire_observation(observation, reason: nil)
      return refused(INACTIVE) unless observation.active?
      return refused("The reason is too long (at most #{MAX_REASON_LENGTH} characters).") if reason.to_s.length > MAX_REASON_LENGTH

      entity = observation.memory_entity
      record("explore.observation_retire", entity, "retired an observation of '#{entity.name}'") do
        observation.mark_obsolete!(reason: reason.to_s.strip.presence || "retired in Explore")
        done("Observation retired.", entity)
      end
    end

    private

    def observation_input_error(content, perspective)
      return "Observation text can't be blank." if content.blank?
      return "Observation text is too long (at most #{MAX_OBSERVATION_LENGTH} characters)." if content.length > MAX_OBSERVATION_LENGTH

      "Perspective must be one of: #{MemoryObservation::PERSPECTIVES.join(', ')}." if perspective && !MemoryObservation::PERSPECTIVES.include?(perspective)
    end

    # @return [Array(Hash, Boolean)] the similar observation (or nil), and whether the check ran
    def similar_observation(entity, content)
      match = ImportObservationDuplicateDetector.new.find_duplicate(entity: entity, content: content)
      return [ nil, true ] unless match.duplicate && match.observation

      [ { id: match.observation.id, content: match.observation.content.to_s }, true ]
    rescue ImportObservationDuplicateDetector::UnavailableError, EmbeddingService::EmbeddingError
      [ nil, false ]
    end
  end
end
