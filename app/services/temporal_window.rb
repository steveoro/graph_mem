# frozen_string_literal: true

# Value object describing a temporal query window used by the temporal recall
# channel and by observation-level filtering.
#
# Semantics (deterministic, no LLM):
# - A "dated" observation (valid_from and/or valid_until set) matches a range
#   window when its [valid_from, valid_until] span intersects it; open bounds
#   count as -infinity/+infinity.
# - An "undated" observation (no valid_* bounds) falls back to its retention
#   time (created_at) — it is relevant while inside the window because that is
#   when it was learned. This maps Hindsight's occurred vs mentioned split onto
#   the existing columns (valid_* = occurred, created_at = mentioned).
# - `as_of` is a point window: dated observations must contain the instant;
#   undated observations must have already been retained by it (created_at <= t).
class TemporalWindow
  FAR_PAST = Time.utc(1000, 1, 1).freeze
  FAR_FUTURE = Time.utc(9999, 12, 31, 23, 59, 59).freeze

  attr_reader :occurred_after, :occurred_before, :as_of
  alias_method :after, :occurred_after
  alias_method :before, :occurred_before

  def initialize(occurred_after: nil, occurred_before: nil, as_of: nil)
    @occurred_after = self.class.coerce_time(occurred_after)
    @occurred_before = self.class.coerce_time(occurred_before, end_of_day: true)
    @as_of = self.class.coerce_time(as_of, end_of_day: true)

    if @as_of.present? && (@occurred_after.present? || @occurred_before.present?)
      raise ArgumentError, "as_of cannot be combined with occurred_after/occurred_before"
    end
    raise ArgumentError, "provide at least one temporal bound" if @as_of.nil? && @occurred_after.nil? && @occurred_before.nil?
    if @occurred_after.present? && @occurred_before.present? && @occurred_after > @occurred_before
      raise ArgumentError, "occurred_after must be on or before occurred_before"
    end
  end

  # Strict ISO 8601 inputs only: "YYYY", "YYYY-MM", "YYYY-MM-DD", or full
  # datetimes "YYYY-MM-DDTHH:MM[:SS[.fff]][Z|±HH[:]MM]". Bare year/month
  # fragments widen to their covered period (upper bounds and `as_of` get the
  # period's end). Results are clamped to [FAR_PAST, FAR_FUTURE].
  ISO_PERIOD = /\A(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?\z/.freeze
  ISO_DATETIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.freeze

  def self.coerce_time(value, end_of_day: false)
    return nil if value.nil?
    return value if value.is_a?(Time) || value.is_a?(DateTime)
    return day_bound(Time.zone.local(value.year, value.month, value.day), end_of_day) if value.is_a?(Date)

    text = value.to_s.strip
    return nil if text.blank?

    parsed = coerce_string(text, end_of_day)
    raise ArgumentError, "invalid temporal bound (expected ISO 8601): #{value.inspect}" unless parsed

    clamp(parsed)
  end

  def self.coerce_string(text, end_of_day)
    if (m = text.match(ISO_PERIOD))
      year, month, day = m[1].to_i, (m[2]&.to_i || 1), (m[3]&.to_i || 1)
      return nil unless (1..12).cover?(month) && (m[3].nil? || Date.valid_date?(year, month, day))

      point = begin
        Time.zone.local(year, month, day)
      rescue ArgumentError, RangeError
        return nil
      end
      return point unless end_of_day

      m[3] ? point.end_of_day : (m[2] ? point.end_of_month : point.end_of_year)
    elsif text.match?(ISO_DATETIME)
      begin
        Time.zone.iso8601(text)
      rescue ArgumentError
        nil
      end
    end
  end

  def self.day_bound(time, end_of_day)
    end_of_day ? time.end_of_day : time
  end

  def self.clamp(time)
    [ [ time, FAR_PAST ].max, FAR_FUTURE ].min
  end

  # Build a window from explicit tool params. Returns nil when no bound is given.
  def self.from_params(occurred_after: nil, occurred_before: nil, as_of: nil)
    return nil if occurred_after.blank? && occurred_before.blank? && as_of.blank?

    new(occurred_after: occurred_after, occurred_before: occurred_before, as_of: as_of)
  end

  def as_of?
    @as_of.present?
  end

  def lower_bound
    @occurred_after || FAR_PAST
  end

  def upper_bound
    @occurred_before || FAR_FUTURE
  end

  # SQL predicate over the memory_observations table.
  # @return [Array(String, Hash)] sql fragment + named binds
  def observation_predicate
    dated = "(memory_observations.valid_from IS NOT NULL OR memory_observations.valid_until IS NOT NULL)"
    undated = "(memory_observations.valid_from IS NULL AND memory_observations.valid_until IS NULL)"

    if as_of?
      [
        "(#{dated} " \
        "AND (memory_observations.valid_from IS NULL OR memory_observations.valid_from <= :t) " \
        "AND (memory_observations.valid_until IS NULL OR memory_observations.valid_until >= :t)) " \
        "OR (#{undated} AND memory_observations.created_at <= :t)",
        { t: @as_of }
      ]
    else
      [
        "(#{dated} " \
        "AND (memory_observations.valid_from IS NULL OR memory_observations.valid_from <= :before) " \
        "AND (memory_observations.valid_until IS NULL OR memory_observations.valid_until >= :after)) " \
        "OR (#{undated} " \
        "AND memory_observations.created_at >= :after AND memory_observations.created_at <= :before)",
        { after: lower_bound, before: upper_bound }
      ]
    end
  end

  # Ruby-side predicate with the same semantics as #observation_predicate.
  # @param observation [MemoryObservation, #valid_from, #valid_until, #created_at]
  def covers?(observation)
    dated = observation.valid_from.present? || observation.valid_until.present?

    if as_of?
      dated ? within_validity?(observation, @as_of, @as_of) : observation.created_at <= @as_of
    elsif dated
      within_validity?(observation, lower_bound, upper_bound)
    else
      observation.created_at >= lower_bound && observation.created_at <= upper_bound
    end
  end

  def to_h
    {
      occurred_after: @occurred_after&.iso8601,
      occurred_before: @occurred_before&.iso8601,
      as_of: @as_of&.iso8601
    }.compact
  end

  private

  # Validity-window intersection for a dated observation: [valid_from, valid_until]
  # overlaps [low, high], open bounds counting as infinite.
  def within_validity?(observation, low, high)
    (observation.valid_from.nil? || observation.valid_from <= high) &&
      (observation.valid_until.nil? || observation.valid_until >= low)
  end
end
