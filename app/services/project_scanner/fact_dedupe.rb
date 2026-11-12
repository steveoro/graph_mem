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
      return false unless found.duplicate == true && same_subject?(entity, text, found.observation)

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

    # 1.78.0: a close fact is the same fact only if the new one mentions nothing the stored one
    # doesn't (its keyword-path mentions are a subset); one that names something more adds
    # information, so it is written. Both paths come from one index of the project, built once every
    # item's entity exists. With fact keywords off, only the detail check below applies.
    #
    # 1.82.0: a close fact with a different detail (a version, a number, a date) is never the same
    # fact ("Developed using Rails 8.0" / "… 8.1"): it is written, as a supersede candidate.
    #
    # 1.83.0: two facts that name no entity compare by their LLM words: the new fact is the same
    # only if its words are a subset of the stored one's. Either side without words: as 1.82.0.
    def same_subject?(entity, text, stored)
      return true unless stored

      content, stored_words, words_at = MemoryObservation.where(id: stored.id).pick(:content, :llm_keywords, :llm_keywords_at)
      return true if content.nil?
      return false if FactKeywords::Details.compare(text, content) == :different
      return true unless @project_entity && AppSettings.fact_keywords_enabled?

      new_mentions = scan_mentions(entity, text)
      stored_mentions = scan_mentions(entity, content)
      words = @scan_llm_words[[ entity.id, text ]]
      if new_mentions.empty? && stored_mentions.empty? && words.present? && words_at.present? && stored_words.present?
        return FactKeywords::LlmWords.keys(words).subset?(FactKeywords::LlmWords.keys(stored_words))
      end

      (new_mentions - stored_mentions).empty?
    end

    # 1.83.0: the LLM words of this scan's new facts that name no entity, asked in batches before
    # their dedupe (FactKeywords::LlmWords). A failed call leaves them pending: FactKeywordsJob asks
    # again, and the dedupe uses the 1.82.0 rule meanwhile.
    #
    # It runs inside the reconcile transaction, so it is bounded: at most SCAN_LLM_BATCHES calls,
    # none after one the LLM didn't answer, and none when the dedupe can't use the words (no
    # vectors). FactKeywordsJob computes the rest after the commit.
    def prepare_scan_llm_words!(reconciled)
      return if @dry_run || @project_entity.nil? || !FactKeywords::LlmWords.enabled?
      return if @fact_dedupe_unavailable || !EmbeddingService.vector_enabled?

      wanted = reconciled.flat_map do |entity, item|
        known = entity.active_memory_observations.pluck(:content).to_set { |content| content.to_s.strip }
        Array(item["observations"]).filter_map do |content|
          text = content.to_s.strip
          [ entity, text ] if text.present? && !known.include?(text) && scan_mentions(entity, text).empty?
        end
      end.uniq { |entity, text| [ entity.id, text ] }
      # Plain integer keys: they are the ids the LLM sees.
      entries = wanted.each_with_index.map { |(entity, text), i| { key: i, text: text, entity: entity } }
      found = FactKeywords::LlmWords.words_for(entries, max_batches: ProjectScanner::SCAN_LLM_BATCHES, stop_on_failure: true)
      found.each { |i, words| @scan_llm_words[[ wanted[i][0].id, wanted[i][1] ]] = words }
    rescue StandardError => e
      @logger.warn "ProjectScanner: LLM words not asked: #{e.class}: #{e.message}"
    end

    # Stores a new fact's LLM words when this scan asked for them.
    def store_scan_llm_words(fact, entity, text)
      words = @scan_llm_words[[ entity.id, text ]]
      fact.update_columns(llm_keywords: words, llm_keywords_at: Time.current) if words
    end

    def scan_mentions(entity, text)
      @fact_term_index ||= FactKeywords::TermIndex.new(@project_entity)
      FactKeywords.mentions(@fact_term_index.path_for(text, owner: entity).path, entity.name)
    end

    # 1.77.0: the keyword paths (FactKeywords) of the facts this scan wrote, computed once every
    # item's entity exists, before the reconcile commits; the after-commit request finds them done.
    def compute_scan_fact_keywords!
      return if @dry_run || @scan_fact_ids.empty? || !AppSettings.fact_keywords_enabled?

      FactKeywords.compute!(MemoryObservation.where(id: @scan_fact_ids).includes(:memory_entity))
    rescue StandardError => e
      # An aid, never a reason to roll the scan back: FactKeywordsJob computes them later.
      @logger.warn "ProjectScanner: fact keywords not computed: #{e.class}: #{e.message}"
    end

    # Compares only against embedded facts: a Rails code map's facts wait for a deferred backfill.
    def fact_duplicate_detector
      @fact_duplicate_detector ||= ImportObservationDuplicateDetector.new(
        threshold: AppSettings.project_scan_fact_duplicate_max_distance, only_embedded: true
      )
    end
  end
end
