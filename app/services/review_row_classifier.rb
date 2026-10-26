# frozen_string_literal: true

# Classifies a review row (UI-5a, `ui-dashboard-plan.md` §2.5.1): the group it belongs to, the
# entity it is about, that entity's project, a normalized confidence and a 0-100 priority that is
# comparable across kinds. Called by CompactionReviewService.seed_report for every new row, by
# ReviewRowClassifier::Backfill for rows seeded before UI-5a, and by the nightly policy run to
# refresh priorities (age raises them).
#
#   ReviewRowClassifier.call(row)
#   # => { group_key: "relationship_proposal|12-40", anchor_entity_id: 12, project_id: 3,
#   #      confidence: 0.9, priority: 72 }
#
# The kind lists below are the single source of truth for what may be bulk-, group- or
# policy-applied.
class ReviewRowClassifier
  include Anchors

  # Applied one by one only: never bulk-, group- or policy-applied.
  DESTRUCTIVE_KINDS = %w[entity_merge delete_entity delete_relation delete_observation reparent_entity
                         move_observation].freeze
  # The only kinds bulk apply, group apply and auto-apply policies may touch.
  SAFE_BULK_KINDS = %w[relationship_proposal stale_memory].freeze
  # Apply needs a per-row choice (which observation to keep); dismiss and snooze work as usual.
  CHOICE_KINDS = %w[contradiction].freeze
  ERROR_KINDS = %w[entity_error embedding_backfill_failed lifecycle_corruption].freeze
  SCAN_KINDS = %w[delete_entity delete_relation delete_observation reparent_entity move_observation].freeze

  # Most rows one seed run (one source_ref) may add per kind; the best by priority are kept.
  RUN_CAPS = { "relationship_proposal" => 200, "entity_merge" => 100, "orphan_parent" => 100, "contradiction" => 100 }.freeze

  # §2.5.1: how much acting on a kind changes the graph (0-1) and fixed confidences.
  IMPACT = Hash.new(0.5).merge(
    "relationship_proposal" => 0.3, "entity_merge" => 0.8, "orphan_parent" => 0.5, "stale_memory" => 0.6,
    "contradiction" => 0.6, "relation_integrity" => 0.4,
    **ERROR_KINDS.index_with(0.7), **SCAN_KINDS.index_with(0.6)
  ).freeze
  CONFIDENCE = {
    "relation_integrity" => 0.9, **ERROR_KINDS.index_with(1.0), **SCAN_KINDS.index_with(0.7)
  }.freeze
  BAND_CONFIDENCE = { "high" => 0.9, "medium" => 0.6, "low" => 0.3 }.freeze
  # A relationship score nudges the band's confidence by at most ±BAND_NUDGE (never across bands).
  BAND_NUDGE = 0.05
  RELATIONSHIP_SCORE_RANGE = (8..20)
  SIGNAL_CONFIDENCE = { "valid_until_elapsed" => 0.95, "addressed_by_newer_edge" => 0.75, "unrooted_after_rescan" => 0.6 }.freeze
  ENTITY_MERGE_SCORE_MAX = 24.0
  # Project roots (and orphan rows with project suggestions) used to sort first (root_first?).
  ROOT_IMPACT_BUMP = 0.1
  DEGREE_THRESHOLD = 20
  DEGREE_BUMP = 10
  # The default attention threshold: error rows never sort below it.
  ATTENTION_FLOOR_ERRORS = 40
  AGE_BOOST_DAYS = 14

  AnchorEntity = Struct.new(:id, :project_id, :entity_type)

  # @param row_or_attrs [MaintenanceReportRow, Hash] a row, or `{ kind:, payload:, created_at: }`
  # @return [Hash] `{ group_key:, anchor_entity_id:, project_id:, confidence:, priority: }`
  def self.call(row_or_attrs)
    new.classify(row_or_attrs)
  end

  # Classifies rows seeded before UI-5a and dedupes symmetric proposals; see Backfill.
  # @return [Hash] counts per step
  def self.backfill!(batch_size: 1_000, limit: nil, progress: nil, symmetric: true)
    Backfill.call(batch_size: batch_size, limit: limit, progress: progress, symmetric: symmetric)
  end

  # One classifier can classify many rows; entity, degree and owner lookups are cached.
  def initialize
    @entities = {}
    @degrees = {}
  end

  # @see .call
  def classify(row_or_attrs)
    kind, payload, created_at, row_uuid = unpack(row_or_attrs)
    group_key, anchor_id = group_and_anchor(kind, payload, row_uuid)
    anchor = entity(anchor_id)
    confidence = confidence_for(kind, payload).clamp(0.0, 1.0).round(3)
    {
      group_key: group_key.truncate(191, omission: ""),
      anchor_entity_id: anchor_id,
      project_id: anchor&.project_id,
      confidence: confidence,
      priority: priority_for(kind, payload, anchor, confidence, created_at)
    }
  end

  private

  def unpack(row_or_attrs)
    if row_or_attrs.is_a?(MaintenanceReportRow)
      row = row_or_attrs
      return [ row.kind, row.effective_payload.to_h.deep_stringify_keys, row.created_at, row.row_uuid ]
    end

    attrs = row_or_attrs.to_h.with_indifferent_access
    payload = attrs[:payload].to_h.deep_stringify_keys
    [ (attrs[:kind] || payload["kind"]).to_s, payload, attrs[:created_at], attrs[:row_uuid] || attrs[:id] ]
  end

  def confidence_for(kind, payload)
    case kind
    when "relationship_proposal" then relationship_confidence(payload)
    when "entity_merge" then merge_confidence(payload)
    when "orphan_parent" then orphan_confidence(payload)
    when "stale_memory" then SIGNAL_CONFIDENCE.fetch(payload["signal"].to_s, 0.6)
    when "contradiction" then payload["confidence"].to_f
    else CONFIDENCE.fetch(kind, 0.5)
    end
  end

  def relationship_confidence(payload)
    base = BAND_CONFIDENCE.fetch(payload["confidence_band"].to_s, BAND_CONFIDENCE["low"])
    score = payload["score"]
    return base if score.nil?

    span = RELATIONSHIP_SCORE_RANGE.max - RELATIONSHIP_SCORE_RANGE.min
    position = (score.to_f.clamp(RELATIONSHIP_SCORE_RANGE.min, RELATIONSHIP_SCORE_RANGE.max) - RELATIONSHIP_SCORE_RANGE.min) / span
    base + ((position * 2) - 1) * BAND_NUDGE
  end

  # min(score / 24, 1) × (1 − cosine distance); suggest_merges rows carry no score: distance only.
  def merge_confidence(payload)
    similarity = 1.0 - payload["cosine_distance"].to_f
    return similarity if payload["score"].nil?

    [ payload["score"].to_f / ENTITY_MERGE_SCORE_MAX, 1.0 ].min * similarity
  end

  # The matcher's score has no fixed top; AUTO_PARENT_SCORE is where it would act on its own.
  def orphan_confidence(payload)
    top = Array(payload["suggested_parents"]).filter_map { |parent| parent.is_a?(Hash) ? parent["score"].to_f : nil }.max
    return 0.0 unless top

    [ top / OrphanMatchingStrategy::AUTO_PARENT_SCORE, 1.0 ].min
  end

  def priority_for(kind, payload, anchor, confidence, created_at)
    impact = impact_for(kind, payload, anchor)
    age_days = created_at ? ((Time.current - created_at) / 1.day).clamp(0, AGE_BOOST_DAYS) : 0
    age_boost = 1 + (age_days / (AGE_BOOST_DAYS * 2.0))
    priority = (100 * ((0.6 * impact) + (0.4 * confidence)) * age_boost).round
    priority += DEGREE_BUMP if anchor && degree(anchor.id) > DEGREE_THRESHOLD
    priority = [ priority, ATTENTION_FLOOR_ERRORS ].max if ERROR_KINDS.include?(kind)
    priority.clamp(0, 100)
  end

  def impact_for(kind, payload, anchor)
    impact = IMPACT[kind]
    impact *= [ Array(payload["observation_ids"]).size / 5.0, 1.0 ].min if kind == "stale_memory"
    root = anchor&.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE ||
           (kind == "orphan_parent" && payload["suggested_parents"].present?)
    root ? impact + ROOT_IMPACT_BUMP : impact
  end

  def entity(id)
    return unless id
    return @entities[id] if @entities.key?(id)

    found = MemoryEntity.where(id: id).pick(:project_id, :entity_type)
    @entities[id] = found && AnchorEntity.new(id, *found)
  end

  def degree(entity_id)
    @degrees[entity_id] ||= MemoryRelation.where(from_entity_id: entity_id).or(MemoryRelation.where(to_entity_id: entity_id)).count
  end
end
