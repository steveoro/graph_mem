# frozen_string_literal: true

# C4 stale-memory revalidation (Hindsight port).
#
# DESIGN (Steve's rule — discovery-anchored staleness, NEVER time-anchored):
# an observation is "stale" only when the graph itself displaced it. There is
# deliberately NO age-based detector here: an old but still-true fact (e.g. a
# to-do on a bug that was never addressed) must keep surfacing; age may only
# order the review list, never seed it. Everything produced by this scanner
# is anchored to a traversal/discovery signal the operator can act on:
#
#   valid_until_elapsed     — the explicit expiry the writer chose passed.
#                             (Not a preset age: the operator set that date.)
#   addressed_by_newer_edge — an Issue/Task has an active obs still claiming
#                             it open AND a solves/replaces/resolves edge
#                             written AFTER the obs = discovered already
#                             addressed during traversal.
#   unrooted_after_rescan   — entity carries a 'Defined at' provenance obs
#                             (i.e. it was DECLARED by a code import, not just
#                             referenced — reference stubs parked in the global
#                             namespace by design are excluded) but is no longer
#                             reachable through any Project's part_of tree.
#                             Covers rescan removal AND manual detachment — the
#                             graph state is identical, so the reason names both.
#
# Flagging only: nothing is auto-deleted. Each signal enqueues a
# `stale_memory` review row; applying it calls `mark_obsolete!` on the listed
# observation ids. Re-runs are idempotent — the row signature
# (entity + sorted observation ids) dedupes repeat detections.
class StaleMemoryScanner
  # Entity types an "addressed" edge meaningfully closes.
  ADDRESSABLE_TYPES = %w[Issue Task].freeze
  # Obs text still asserting the entity is unresolved. Kept tight on purpose:
  # a looser match would flag facts merely mentioning the bug.
  OPEN_MARKERS = /\b(open|unresolved|pending|blocked|outstanding|to-?do|not fixed|still broken|wontfix-yet)\b/i
  # Negation guard: phrases asserting the OPPOSITE state ("no longer open")
  # must not be treated as open claims. Kept equally tight — a bare `not`
  # only negates `open` ("the ticket is not open"): with a whole-content
  # NOT REGEXP, letting it negate `blocked`/`pending` too would hide mixed
  # observations like "issue still open, deploy not blocked".
  NEGATED_MARKERS = /\b(?:no longer|never was|isn'?t|wasn'?t)\s+(?:open|unresolved|pending|blocked|outstanding|broken)\b|\bnot\s+open\b/i
  ADDRESSING_RELATIONS = %w[solves replaces resolves fixes].freeze
  # Vector contradiction detection candidates are bounded by obs activity
  # since the previous scan — a cost bound, not a staleness criterion.
  CONTRADICTION_LOOKBACK = 24.hours
  SCAN_REPORT_TYPE = "stale_memory_scan"

  # Returns { items:, contradiction_items:, next_watermark: } — `next_watermark` is the bound the
  # NEXT scan's contradiction pass should start from. It advances only when
  # the contradiction pass completed: a failed pass must not lose the
  # candidates it never visited (the report row is written regardless, so
  # keying the watermark off report created_at would silently skip them).
  # `contradiction_items` are the review rows for the pairs that pass found (UI-5a).
  def self.scan
    items = []
    items.concat(expired_items)
    items.concat(addressed_items)
    items.concat(unrooted_items)
    next_watermark, contradiction_items = detect_contradictions
    { items: items, contradiction_items: contradiction_items, next_watermark: next_watermark }
  end

  # --- Detector 1: explicit expiry elapsed ---------------------------------
  def self.expired_items
    MemoryObservation.active
                     .where("valid_until IS NOT NULL AND valid_until < ?", Time.current)
                     .group_by(&:memory_entity_id)
                     .filter_map do |entity_id, observations|
      entity = MemoryEntity.find_by(id: entity_id)
      next unless entity

      item(entity.id, entity.name, observations,
           signal: "valid_until_elapsed",
           reason: "valid_until has passed — fact may no longer hold")
    end
  end

  # --- Detector 2: obs claims open, newer edge says addressed --------------
  def self.addressed_items
    rows = MemoryObservation.active
                            .joins(:memory_entity)
                            .where(memory_entities: { entity_type: ADDRESSABLE_TYPES })
                            .where("memory_observations.content REGEXP ?", OPEN_MARKERS.source)
                            .where.not("memory_observations.content REGEXP ?", NEGATED_MARKERS.source)
                            .joins(
                              "INNER JOIN memory_relations addressing " \
                              "ON addressing.to_entity_id = memory_entities.id " \
                              "AND addressing.relation_type IN ('solves','replaces','resolves','fixes') " \
                              "AND addressing.created_at > memory_observations.created_at"
                            )
                            .select("memory_observations.*, " \
                                    "memory_entities.id AS e_id, memory_entities.name AS e_name, " \
                                    "MIN(addressing.relation_type) AS addressing_type")
                            .group("memory_observations.id")
                            .to_a

    rows.group_by(&:e_id).map do |entity_id, observations|
      item(entity_id, observations.first.e_name, observations,
           signal: "addressed_by_newer_edge",
           reason: "observation claims unresolved but a newer " \
                   "'#{observations.first.addressing_type}' edge marks it addressed")
    end
  end

  # --- Detector 3: importer-stamped obs on an unrooted entity --------------
  # Candidates must carry a 'Defined at' provenance obs (any status): only an
  # entity an import actually DECLARED can be "left behind" by a rescan. This
  # excludes reference stubs — globally parked by design, never rooted — which
  # would otherwise flag merely for holding passthrough producer-stamped obs.
  def self.unrooted_items
    declared = "EXISTS (SELECT 1 FROM memory_observations prov " \
               "WHERE prov.memory_entity_id = memory_entities.id " \
               "AND prov.content LIKE 'Defined at %')"
    candidates = MemoryEntity.where.not(entity_type: "Project")
                             .joins(:memory_observations)
                             .where(memory_observations: {
                                      status: MemoryObservation::ACTIVE_STATUS,
                                      source: GraphifyImporter::KNOWN_PRODUCERS
                                    })
                             .where(declared)
                             .distinct
                             .pluck(:id, :name)
    return [] if candidates.empty?

    rooted = MemoryEntity.where(entity_type: "Project").find_each
                         .flat_map { |project| ProjectMembership.member_ids(project.id).to_a }
                         .to_set
    candidates.reject { |id, _name| rooted.include?(id) }
              .filter_map do |entity_id, entity_name|
      observations = MemoryObservation.active.where(memory_entity_id: entity_id).to_a
      next if observations.empty?

      item(entity_id, entity_name, observations,
           signal: "unrooted_after_rescan",
           reason: "imported entity is no longer reachable from any Project " \
                   "tree (removed by a rescan or detached manually) — its " \
                   "imported facts won't surface in project-scoped recall")
    end
  end

  # --- Detector 4: vector+polarity contradictions (bounded candidates) -----
  # ContradictionDetector persists its own 'contradictions' report, so this
  # runs it only for entities with obs activity newer than the last scan —
  # keeps re-runs cheap and avoids duplicate reports. Gated by the same
  # AppSettings + vector flags the detector itself honors.
  # @return [Array(Time, Array<Hash>)] the next watermark and one review item per pair found
  #   (de-duplicated across entities)
  def self.detect_contradictions
    watermark = previous_watermark
    return [ watermark, [] ] unless AppSettings.contradiction_detection_enabled? && EmbeddingService.vector_enabled?

    cutoff = Time.current
    results = MemoryEntity.joins(:memory_observations)
                          .where(memory_observations: { status: MemoryObservation::ACTIVE_STATUS })
                          .where("memory_observations.updated_at > ?", watermark)
                          .distinct
                          .pluck(:id)
                          .flat_map { |entity_id| Array(ContradictionDetector.detect(entity_id)) }
    items = results.uniq { |result| [ result.observation_id_1, result.observation_id_2 ].map(&:to_i).sort }
                   .filter_map { |result| ContradictionDetector.review_item(result) }
    [ cutoff, items ]
  rescue StandardError => e
    # Vector work is best-effort inside a maintenance scan — log, never abort.
    # Return the PREVIOUS watermark so the failed window is retried next run.
    Rails.logger.warn "[StaleMemoryScanner] contradiction pass skipped: #{e.message}"
    [ watermark, [] ]
  end

  # The scan watermark lives in the previous report's `data` (set by the job),
  # falling back to its created_at for reports written before the field
  # existed, then to the bounded lookback on the very first run.
  def self.previous_watermark
    report = MaintenanceReport.where(report_type: SCAN_REPORT_TYPE).order(id: :desc).first
    stored = report&.data.is_a?(Hash) ? report.data["watermark"].presence : nil
    Time.iso8601(stored.to_s) rescue (report&.created_at || CONTRADICTION_LOOKBACK.ago)
  end

  # Apply-time re-check: the graph moves between scan and apply — an
  # addressing edge can be removed, an entity re-rooted, an expiry edited.
  # Only observations a detector STILL flags may be obsoleted; the rest are
  # reported as no-longer-flagged rather than stale. Signals this scanner
  # doesn't know are not second-guessed — every still-active obs counts.
  def self.still_flagged_ids(entity_id:, signal:, observation_ids:)
    scope = MemoryObservation.active.where(id: observation_ids)
    case signal.to_s
    when "valid_until_elapsed"
      scope.where("valid_until IS NOT NULL AND valid_until < ?", Time.current).pluck(:id)
    when "addressed_by_newer_edge"
      scope.select do |obs|
        MemoryRelation.where(to_entity_id: entity_id, relation_type: ADDRESSING_RELATIONS)
                      .where("created_at > ?", obs.created_at).exists?
      end.map(&:id)
    when "unrooted_after_rescan"
      entity_rooted?(entity_id) ? [] : scope.pluck(:id)
    else
      scope.pluck(:id)
    end
  end

  # Single-entity variant of the unrooted detector's membership walk: rooted
  # means reachable through ANY Project's part_of tree. The project_id stamp
  # alone is only a cache — the edge walk is authoritative.
  def self.entity_rooted?(entity_id)
    MemoryEntity.where(entity_type: "Project").pluck(:id).any? do |project_id|
      ProjectMembership.member_ids(project_id).include?(entity_id)
    end
  end

  def self.item(entity_id, entity_name, observations, signal:, reason:)
    {
      id: SecureRandom.uuid,
      kind: "stale_memory",
      entity_id: entity_id,
      entity_name: entity_name,
      observation_ids: observations.map { |o| o.respond_to?(:id) ? o.id : o[:id] }.sort,
      signal: signal,
      reason: reason
    }
  end
end
