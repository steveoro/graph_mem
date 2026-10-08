# frozen_string_literal: true

# Extracts a TemporalWindow from free-text queries — deterministic, no LLM.
#
# Supported forms (matched case-insensitively):
#   "in 2024", "during 2024", "throughout 2024"
#   "October 2026", "Oct 2026", "in October 2026", "2026-10", "2026-10-05"
#   "Q3 2026"
#   "last/this/next week|month|year", "today", "yesterday", "tomorrow"
#   "last 3 days|weeks|months|years", "past 6 months"
#   "spring", "last summer", "autumn 2025", "next winter" (season names)
#   "since <expr>", "after <expr>", "before <expr>", "until <expr>", "as of <expr>"
#   "from <expr> to <expr>", "between <expr> and <expr>"
#
# A bare year ("2024") is ignored without a temporal cue — too likely to be a
# name. Month+year, quarters, ISO dates and relative phrases are accepted both
# with and without a cue.
class TemporalQueryParser
  Result = Struct.new(:window, :matched, keyword_init: true)

  YEAR = /(?:19|20)\d{2}/
  MONTH_NAME = /(?:jan|feb|mar|apr|may|june?|july?|aug|sep|sept|oct|nov|dec)[a-z]*/
  ISO_DATE = /\d{4}-\d{2}(?:-\d{2})?/
  QUARTER = /q[1-4]/
  UNIT_PATTERN = Regexp.union(
    /#{MONTH_NAME}\s+#{YEAR}/,
    /#{ISO_DATE}/,
    /#{QUARTER}\s*#{YEAR}/,
    /#{YEAR}/
  ).freeze

  RELATIVE_UNIT = /weeks?|months?|years?|days?/
  SEASON_NAME = /spring|summer|autumn|fall|winter/

  # Astronomical seasons keyed to the year they begin in (winter spans into the
  # next calendar year). Dates are the common UTC approximations.
  SEASON_SPANS = {
    "spring" => [ [ 3, 20 ], [ 6, 20 ] ],
    "summer" => [ [ 6, 21 ], [ 9, 22 ] ],
    "autumn" => [ [ 9, 23 ], [ 12, 21 ] ],
    "fall" => [ [ 9, 23 ], [ 12, 21 ] ],
    "winter" => [ [ 12, 22 ], [ 3, 19 ] ]
  }.freeze

  MONTH_NAMES = %w[january february march april may june july august september october november december]
                .each_with_index.map { |n, i| [ n, i + 1 ] }.freeze

  class << self
    # @param query [String]
    # @return [Result, nil] extracted window + matched text span
    def extract(query)
      text = query.to_s.downcase
      return nil if text.blank?

      extract_as_of(text) ||
        extract_range(text) ||
        extract_bounded(text) ||
        extract_relative(text) ||
        extract_season(text) ||
        extract_cued_unit(text) ||
        extract_uncued_unit(text)
    end

    private

    def build(after:, before:, matched:, as_of: nil)
      Result.new(
        window: TemporalWindow.new(occurred_after: after, occurred_before: before, as_of: as_of),
        matched: matched
      )
    rescue ArgumentError
      nil
    end

    # --- connector forms -------------------------------------------------

    def extract_as_of(text)
      m = text.match(/\bas\s+of\s+(#{UNIT_PATTERN})/)
      return nil unless m

      span = parse_unit(m[1])
      span && build(as_of: span.last, matched: m[0])
    end

    def extract_range(text)
      m = text.match(/(?:between\s+(#{UNIT_PATTERN})\s+and|from\s+(#{UNIT_PATTERN})\s+(?:to|until|through|-))\s+(#{UNIT_PATTERN})/)
      return nil unless m

      first = m[1] || m[2]
      second = m[3]
      a = parse_unit(first)
      b = parse_unit(second)
      return nil unless a && b

      build(after: a.first, before: b.last, matched: m[0])
    end

    def extract_bounded(text)
      if (m = text.match(/(?:since|after)\s+(#{UNIT_PATTERN})/))
        span = parse_unit(m[1])
        return build(after: m[0].start_with?("after") ? span.last : span.first, before: nil, matched: m[0]) if span
      end
      if (m = text.match(/(?:before|until|prior\s+to)\s+(#{UNIT_PATTERN})/))
        span = parse_unit(m[1])
        return build(after: nil, before: span.first, matched: m[0]) if span
      end
      nil
    end

    def extract_relative(text)
      if (m = text.match(/\b(last|this|next)\s+(week|month|year)\b/))
        return build_relative(m[1], m[2], 1, m[0])
      end
      if (m = text.match(/\b(?:last|past)\s+(\d+)\s+(#{RELATIVE_UNIT})\b/))
        return build_relative("last", m[2].sub(/s\z/, ""), m[1].to_i, m[0])
      end
      if (m = text.match(/\b(yesterday|today|tomorrow)\b/))
        day = { "yesterday" => 1.day.ago, "today" => Time.current, "tomorrow" => 1.day.from_now }[m[1]]
        return build(after: day.beginning_of_day, before: day.end_of_day, matched: m[0])
      end
      nil
    end

    def build_relative(qualifier, unit, count, matched)
      now = Time.current
      period =
        case qualifier
        when "last"
          if count == 1
            # "last week|month|year" = previous complete period
            t = now.public_send("prev_#{unit}")
            t.public_send("beginning_of_#{unit}")..t.public_send("end_of_#{unit}")
          else
            # "last N units" / "past N units" = rolling window ending now
            count.public_send(unit.pluralize).ago..now
          end
        when "this"
          now.public_send("beginning_of_#{unit}")..now.public_send("end_of_#{unit}")
        when "next"
          t = now.public_send("next_#{unit}")
          t.public_send("beginning_of_#{unit}")..t.public_send("end_of_#{unit}")
        else
          return nil
        end
      build(after: period.first, before: period.last, matched: matched)
    end

    # "last spring", "in autumn", "winter 2025", "next summer".
    def extract_season(text)
      m = text.match(/\b(?:(last|this|next)\s+)?(#{SEASON_NAME})(?:\s+(#{YEAR}))?\b/)
      return nil unless m

      qualifier, season, year = m[1], m[2], m[3]&.to_i
      span = season_span(season, year, qualifier)
      span && build(after: span.first, before: span.last, matched: m[0])
    end

    # Resolve a season mention to a concrete year span. Without an explicit
    # year: "last" = the most recently finished occurrence (the current year's
    # if it already ended, else the previous year's); "this"/bare = the
    # occurrence containing today, or this year's upcoming one if it hasn't
    # started; "next" = the upcoming occurrence strictly after today's season.
    def season_span(season, explicit_year, qualifier)
      (start_md, end_md), crosses_year = season_bounds(season)
      now = Time.current
      year = explicit_year || season_year_for(start_md, now, qualifier)
      return nil unless year

      start = Time.zone.local(year, *start_md)
      finish = Time.zone.local(crosses_year ? year + 1 : year, *end_md).end_of_day
      start..finish
    end

    def season_year_for(start_md, now, qualifier)
      current_start = Time.zone.local(now.year, *start_md)

      case qualifier
      when "last"
        # Inside it now counts as its most recent occurrence too.
        now >= current_start ? now.year : now.year - 1
      when "next"
        now < current_start ? now.year : now.year + 1
      else
        # "this" or bare: this year's occurrence (current, past, or upcoming).
        now.year
      end
    end

    # @return [Array(Array<Integer,Integer>, Array<Integer,Integer>), Boolean]
    def season_bounds(season)
      span = SEASON_SPANS[season]
      return nil unless span

      [ span, season == "winter" ]
    end

    # --- single unit forms -------------------------------------------------

    # "in 2024", "during October 2026", "on 2026-10-05" — explicit cue required.
    def extract_cued_unit(text)
      m = text.match(/(?:in|during|throughout|on|at)\s+(#{UNIT_PATTERN})/)
      return nil unless m

      span = parse_unit(m[1])
      span && build(after: span.first, before: span.last, matched: m[0])
    end

    # Unambiguous un-cued forms: month+year, quarter, full ISO dates.
    # Bare years are NOT accepted here (could be an entity name).
    def extract_uncued_unit(text)
      m = text.match(/\b#{MONTH_NAME}\s+#{YEAR}\b/) ||
            text.match(/\b#{QUARTER}\s*#{YEAR}\b/) ||
            text.match(/\b\d{4}-\d{2}-\d{2}\b/)
      return nil unless m

      span = parse_unit(m[0])
      span && build(after: span.first, before: span.last, matched: m[0])
    end

    # --- date-expression atoms --------------------------------------------

    # @param fragment [String] e.g. "october 2026", "2026-10-05", "q3 2026", "2026"
    # @return [Range, nil] [start..end] of the period described
    def parse_unit(fragment)
      text = fragment.to_s.strip.downcase

      if (m = text.match(/\A(#{MONTH_NAME})\s+(#{YEAR})\z/))
        year = m[2].to_i
        month = month_number(m[1])
        month ? month_span(year, month) : nil
      elsif (m = text.match(/\A(\d{4})-(\d{2})(?:-(\d{2}))?\z/))
        year, month, day = m[1].to_i, m[2].to_i, m[3]&.to_i
        return nil unless (1..12).cover?(month)

        day ? day_span(year, month, day) : month_span(year, month)
      elsif (m = text.match(/\Aq([1-4])\s*(#{YEAR})\z/))
        quarter_span(m[2].to_i, m[1].to_i)
      elsif (m = text.match(/\A(#{YEAR})\z/))
        year = m[1].to_i
        Time.zone.local(year, 1, 1).beginning_of_day..Time.zone.local(year, 12, 31).end_of_day
      end
    end

    def month_number(name)
      MONTH_NAMES.find { |n, _i| name.start_with?(n[0, 3]) && n.start_with?(name[0, 3]) }&.last
    end

    def month_span(year, month)
      start = Time.zone.local(year, month, 1)
      start..start.end_of_month
    end

    def day_span(year, month, day)
      start = Time.zone.local(year, month, day)
      start..start.end_of_day
    rescue ArgumentError
      nil
    end

    def quarter_span(year, quarter)
      start = Time.zone.local(year, (quarter - 1) * 3 + 1, 1).beginning_of_day
      start..(start.end_of_quarter)
    end
  end
end
