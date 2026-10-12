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
#   unrooted_after_rescan   — entity carries importer-stamped (world) obs but
#                             is no longer reachable through any Project's
#                             part_of tree = its file/module was removed.
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
  ADDRESSING_RELATIONS = %w[solves replaces resolves fixes].freeze
  # Vector contradiction detection candidates are bounded by obs activity
  # since the previous scan — a cost bound, not a staleness criterion.
  CONTRADICTION_LOOKBACK = 24.hours
  SCAN_REPORT_TYPE = "stale_memory_scan"

  def self.scan
    items = []
    items.concat(expired_items)
    items.concat(addressed_items)
    items.concat(unrooted_items)
    detect_contradictions
    items
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
  def self.unrooted_items
    candidates = MemoryEntity.where.not(entity_type: "Project")
                             .joins(:memory_observations)
                             .where(memory_observations: {
                                      status: MemoryObservation::ACTIVE_STATUS,
                                      source: GraphifyImporter::KNOWN_PRODUCERS
                                    })
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
                   "tree — its file/module was likely removed")
    end
  end

  # --- Detector 4: vector+polarity contradictions (bounded candidates) -----
  # ContradictionDetector persists its own 'contradictions' report, so this
  # runs it only for entities with obs activity newer than the last scan —
  # keeps re-runs cheap and avoids duplicate reports. Gated by the same
  # AppSettings + vector flags the detector itself honors.
  def self.detect_contradictions
    return unless AppSettings.contradiction_detection_enabled? && EmbeddingService.vector_enabled?

    watermark = MaintenanceReport.where(report_type: SCAN_REPORT_TYPE)
                                 .order(id: :desc).pick(:created_at) || CONTRADICTION_LOOKBACK.ago
    MemoryEntity.joins(:memory_observations)
                .where(memory_observations: { status: MemoryObservation::ACTIVE_STATUS })
                .where("memory_observations.updated_at > ?", watermark)
                .distinct
                .pluck(:id)
                .each { |entity_id| ContradictionDetector.detect(entity_id) }
  rescue StandardError => e
    # Vector work is best-effort inside a maintenance scan — log, never abort.
    Rails.logger.warn "[StaleMemoryScanner] contradiction pass skipped: #{e.message}"
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
