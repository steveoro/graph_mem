# frozen_string_literal: true

module SqlImport
  # The review rows an SQL import's follow-up proposes (compaction_review, source "sql_import", the
  # operation id as source_ref), for what its exact-key merge leaves behind:
  #
  # - entity_merge: a written entity whose name or an alias is the name or an alias of another entity
  #   of the same type in the same scope (an ambiguous alias inserts a copy), scored with
  #   EntityMergeEvidence;
  # - delete_observation: a new active observation whose nearest active sibling on the same entity is
  #   within AppSettings.import_observation_duplicate_max_distance, read from the stored embeddings
  #   (the follow-up's backfill ran first; nothing is embedded here). A new observation without an
  #   embedding can't be checked: it is counted in `unchecked`, for the report to say so.
  #
  #   result = SqlImport::ReviewSeeds.call(touched, operation_id: "…")
  #   result.rows      # => [MaintenanceReportRow, …] the rows seeded
  #   result.unchecked # => 2 new observations the near-duplicate check couldn't compare
  class ReviewSeeds
    SOURCE = "sql_import"
    REPORT_TYPE = "compaction_review"
    PROJECT = NodeOperationsStrategy::PROJECT_ENTITY_TYPE

    Result = Data.define(:rows, :checked, :unchecked)

    # @param touched [SqlImport::Touched]
    # @param operation_id [String]
    # @return [Result]
    def self.call(touched, operation_id:)
      new(touched, operation_id).call
    end

    def initialize(touched, operation_id)
      @touched = touched
      @operation_id = operation_id
      @checked = 0
      @unchecked = 0
    end

    # @return [Result]
    def call
      items = merge_items + duplicate_items
      rows = CompactionReviewService.seed_report(report_type: REPORT_TYPE, source: SOURCE, source_ref: @operation_id, items: items)
      Result.new(rows: rows, checked: @checked, unchecked: @unchecked)
    end

    private

    # One scope's names and aliases are read once; each pair is proposed once.
    def merge_items
      written = MemoryEntity.where(id: @touched.written_entity_ids).where.not(entity_type: PROJECT).to_a
      pairs = written.group_by(&:project_scope).flat_map do |scope, entities|
        index = term_index(scope)
        entities.flat_map do |entity|
          (terms(entity.name, entity.aliases).flat_map { |term| index.fetch([ entity.entity_type, term ], []) }.uniq - [ entity.id ])
            .map { |other_id| [ entity, other_id ] }
        end
      end
      others = MemoryEntity.where(id: pairs.map(&:last).uniq).index_by(&:id)
      seen = Set.new
      pairs.filter_map { |entity, other_id| merge_item(entity, others.fetch(other_id)) if seen.add?([ entity.id, other_id ].sort) }
    end

    # @return [Hash{Array(String, String) => Array<Integer>}] (type, lowercased name or alias) => ids in the scope
    def term_index(scope)
      index = Hash.new { |hash, key| hash[key] = [] }
      MemoryEntity.where(project_scope: scope).where.not(entity_type: PROJECT).pluck(:id, :entity_type, :name, :aliases).each do |id, type, name, aliases|
        terms(name, aliases).each { |term| index[[ type, term ]] << id }
      end
      index
    end

    def terms(name, aliases)
      [ name, *aliases.to_s.split(/[,|;]/) ].map { |term| term.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def merge_item(entity, other)
      match = EntityMergeEvidence.score(entity, other)
      source, target = EntityMergeEvidence.pick_survivor(entity, other)
      { id: SecureRandom.uuid, kind: "entity_merge", entity_a: brief(source), entity_b: brief(target),
        cosine_distance: match.distance&.round(4), score: match.score, recommendation: "review_manually",
        reason: "SQL import #{@operation_id}: they share a name or an alias" }.compact
    end

    def brief(entity) = { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type }

    def duplicate_items
      threshold = AppSettings.import_observation_duplicate_max_distance.to_f
      proposed = Set.new
      MemoryObservation.active.where(id: @touched.new_observation_ids).order(:id).filter_map do |observation|
        unless EmbeddingService.vector_enabled? && observation.embedded_at
          @unchecked += 1
          next
        end

        @checked += 1
        sibling_id, distance = nearest_sibling(observation)
        # Two new rewordings of one fact: only the first one is proposed.
        next if sibling_id.nil? || distance.to_f > threshold || proposed.include?(sibling_id)

        proposed << observation.id
        { id: SecureRandom.uuid, kind: "delete_observation", observation_id: observation.id, similar_observation_id: sibling_id,
          cosine_distance: distance.to_f.round(4),
          reason: "SQL import #{@operation_id}: within #{threshold} of fact ##{sibling_id} on the same entity (a reworded duplicate?)" }
      end
    end

    # The nearest embedded active sibling, from the two stored vectors. Ordering on (d + 0) keeps the
    # exact, filtered order (ImportObservationDuplicateDetector#nearest_observation explains why).
    def nearest_sibling(observation)
      ActiveRecord::Base.connection.select_rows(<<~SQL.squish).first
        SELECT s.id, VEC_DISTANCE_COSINE(s.embedding, n.embedding) AS d
        FROM memory_observations n JOIN memory_observations s ON s.memory_entity_id = n.memory_entity_id AND s.id <> n.id
        WHERE n.id = #{observation.id.to_i} AND s.status = #{MemoryObservation.connection.quote(MemoryObservation::ACTIVE_STATUS)}
          AND s.embedded_at IS NOT NULL
        ORDER BY (d + 0) ASC LIMIT 1
      SQL
    end
  end
end
