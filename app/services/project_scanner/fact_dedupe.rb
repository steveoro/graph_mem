# frozen_string_literal: true

class ProjectScanner
  # Recognizes a fact the scan restates in other words (1.76.0). A model rewords the facts it found
  # on every scan ("It belongs to a User." / "AdminGrant belongs to a user."), and reconcile used to
  # skip only an exact repeat, so each rescan of unchanged code added near-duplicates.
  #
  # Before a new fact is written, ImportObservationDuplicateDetector compares it with its entity's
  # embedded active facts; one within AppSettings.project_scan_fact_duplicate_max_distance (cosine
  # distance) is the same fact, so it is skipped and counted (`observations_deduped`), and the stored
  # fact is recorded as restated, so this scan's validator doesn't move or obsolete it (else the
  # entity could end up with neither wording). Without embeddings (none configured, or the service
  # down: once down, it isn't asked again in that scan), only the exact check runs, as before: a scan
  # never fails here. Private methods of ProjectScanner; they read and set its instance variables.
  module FactDedupe
    private

    # @param entity [MemoryEntity]
    # @param text [String] the stripped fact
    # @return [Boolean] an active fact of the entity says the same thing in other words
    def reworded_duplicate?(entity, text)
      return false if @fact_dedupe_unavailable || !EmbeddingService.vector_enabled?

      found = fact_duplicate_detector.find_duplicate(entity: entity, content: text)
      return false unless found.duplicate == true

      @observations_deduped = @observations_deduped.to_i + 1
      # The stored wording stands for both: the validator leaves it alone in this scan.
      @restated_observation_ids << found.observation.id if found.observation
      true
    rescue ImportObservationDuplicateDetector::UnavailableError, EmbeddingService::EmbeddingError => e
      # Down once is down for this scan: the retries and timeouts aren't paid again for every fact.
      @fact_dedupe_unavailable = true
      @logger.debug { "ProjectScanner: reworded-fact check skipped: #{e.class}" }
      false
    end

    # Compares only against embedded facts: a Rails code map's facts wait for a deferred backfill.
    def fact_duplicate_detector
      @fact_duplicate_detector ||= ImportObservationDuplicateDetector.new(
        threshold: AppSettings.project_scan_fact_duplicate_max_distance, only_embedded: true
      )
    end
  end
end
