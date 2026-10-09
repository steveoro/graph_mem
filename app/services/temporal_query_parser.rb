# frozen_string_literal: true

# Extracts a TemporalWindow from free-text queries — deterministic, no LLM.
#
# Supported forms (matched case-insensitively):
#   "in 2024", "during 2024", "throughout 2024"
#   "October 2026", "Oct 2026", "in October 2026", "2026-10", "2026-10-05"
#   "Q3 2026"
#   "last/this/next week|month|year", "today", "yesterday", "tomorrow"
#   "last 3 days|weeks|months|years", "past 6 months"
#   "last spring", "winter 2025", "next summer" (seasons need a qualifier or year)
#   "since <atom>", "after <atom>", "before <atom>", "until <atom>", "as of <atom>"
#   "from <atom> to <atom>", "between <atom> and <atom>"
#   (<atom> = unit above, or a relative atom like "yesterday"/"last week")
#
# A bare year ("2024") is ignored without a temporal cue — too likely to be a
# name. Month+year, quarters, ISO dates and relative phrases are accepted both
# with and without a cue. Months come from a closed list ("market", "maybe" and
# "novel" are not months), cue words and seasons require word boundaries
# ("login 2024", "spring boot config", "in 2048-bit keys" do not parse).
class TemporalQueryParser
  Result = Struct.new(:window, :matched, keyword_init: true)

  require "set"

  # Resolution of a query + optional explicit window params into the effective
  # pieces callers need: the window (explicit wins), the phrase that was matched
  # (for diagnostics) and the query text to use for text/vector matching with
  # the temporal phrase stripped out.
  Extraction = Struct.new(:window, :matched, :effective_query, keyword_init: true) do
    # A query that is nothing but the temporal phrase searches by time alone:
    # the temporal channel becomes the base result set.
    def temporal_only?
      window.present? && effective_query.blank?
    end

    # retrieval.temporal diagnostics: resolved window + the matched phrase, so
    # callers can see which text was consumed as the temporal expression.
    def diagnostic
      window.to_h.merge(matched_phrase: matched).compact
    end
  end

  class << self
    # @param query [String]
    # @param temporal_window [TemporalWindow, nil] explicit params win over a
    #   parsed phrase; the phrase is still stripped from the effective query
    # @return [Extraction]
    def apply(query, temporal_window: nil)
      result = extract(query)
      window = temporal_window || result&.window
      # `matched` is the span found in the downcased text; strip the
      # corresponding span from the original query case-insensitively so
      # "In October 2026" still leaves a clean effective query.
      effective =
        if result
          query.to_s.sub(Regexp.new(Regexp.escape(result.matched), Regexp::IGNORECASE), "").squish
        else
          query.to_s
        end

      # A date phrase followed only by question/filler words ("what changed in
      # august 2026") is still a time-only query: no residual terms means there
      # is nothing for the text/vector channels to match. Filler is only
      # stripped when a date phrase was found — plain queries are untouched.
      effective = "" if result && residual_terms(effective).empty?

      Extraction.new(window: window, matched: result&.matched, effective_query: effective)
    end

    # Everyday verbs/question words that carry no lexical signal once the date
    # phrase is gone.
    FILLER_WORDS = %w[
      what which who whom when where how why
      did do does done was were is are be been has have had
      change changed changes changing happen happened happening update updated updates
      new recent recently latest anything something everything stuff
      the a an any all about of on for to from with me my we our us show tell list give
      recall remember know learned noted
    ].to_set.freeze

    # Lexically meaningful tokens left in a stripped query.
    def residual_terms(text)
      text.to_s.downcase.scan(/[[:alnum:]][[:alnum:]_.-]*/).reject { |t| FILLER_WORDS.include?(t) }
    end
  end

  # Year with explicit boundaries: not inside a longer digit run, not part of a
  # hyphenated word ("2048-bit"), not a resolution ("1920x1080").
  YEAR = /(?<!\d)(?:19|20)\d{2}(?!\d|-[a-z]|x\d)/.freeze
  # Closed month list: full names + common abbreviations only.
  MONTH_NAME = %r{(?:
    january|february|march|april|may|june|july|august|september|october|november|december|
    jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec
  )}x.freeze
  ISO_DATE = /(?<!\d)\d{4}-\d{2}(?:-\d{2})?(?!\d)/.freeze
  QUARTER = /\bq[1-4]/.freeze
  UNIT_PATTERN = Regexp.union(
    /#{MONTH_NAME}\s+#{YEAR}/,
    /#{ISO_DATE}/,
    /#{QUARTER}\s*#{YEAR}/,
    /#{YEAR}/
  ).freeze

  RELATIVE_UNIT = /weeks?|months?|years?|days?/.freeze
  RELATIVE_ATOM = /(?:last|this|next)\s+(?:week|month|year)|yesterday|today|tomorrow/.freeze
  # Connector atoms: a unit ("october 2026") or a relative atom ("yesterday",
  # "last week") — so "since yesterday" and "before last week" parse.
  ATOM_PATTERN = Regexp.union(UNIT_PATTERN, RELATIVE_ATOM).freeze
  SEASON_NAME = /spring|summer|autumn|fall|winter/.freeze

  # Cap for "last|past N units" — roughly a century per unit, so
  # "last 99999999 years" cannot produce absurd bounds.
  MAX_RELATIVE_COUNTS = { "day" => 36_500, "week" => 5_200, "month" => 1_200, "year" => 100 }.freeze

  # Astronomical seasons keyed to the year they begin in (winter spans into the
  # next calendar year). Northern-hemisphere dates, common UTC approximations.
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

    def build(after: nil, before: nil, matched:, as_of: nil)
      Result.new(
        window: TemporalWindow.new(occurred_after: after, occurred_before: before, as_of: as_of),
        matched: matched
      )
    rescue ArgumentError
      nil
    end

    # --- connector forms -------------------------------------------------

    def extract_as_of(text)
      m = text.match(/\bas\s+of\s+(#{ATOM_PATTERN})\b/)
      return nil unless m

      span = parse_atom(m[1])
      span && build(as_of: span.last, matched: m[0])
    end

    def extract_range(text)
      m = text.match(/\b(?:between\s+(#{ATOM_PATTERN})\s+and|from\s+(#{ATOM_PATTERN})\s+(?:to|until|through|-))\s+(#{ATOM_PATTERN})\b/)
      return nil unless m

      first = m[1] || m[2]
      second = m[3]
      a = parse_atom(first)
      b = parse_atom(second)
      return nil unless a && b

      build(after: a.first, before: b.last, matched: m[0])
    end

    def extract_bounded(text)
      if (m = text.match(/\b(?:since|after)\s+(#{ATOM_PATTERN})\b/))
        span = parse_atom(m[1])
        return build(after: m[0].start_with?("after") ? span.last : span.first, before: nil, matched: m[0]) if span
      end
      if (m = text.match(/\b(?:before|until|prior\s+to)\s+(#{ATOM_PATTERN})\b/))
        span = parse_atom(m[1])
        return build(after: nil, before: span.first, matched: m[0]) if span
      end
      nil
    end

    def extract_relative(text)
      if (m = text.match(/\b(last|this|next)\s+(week|month|year)\b/))
        return build_relative(m[1], m[2], 1, m[0])
      end
      if (m = text.match(/\b(?:last|past)\s+(\d+)\s+(#{RELATIVE_UNIT})\b/))
        unit = m[2].sub(/s\z/, "")
        count = [ m[1].to_i, MAX_RELATIVE_COUNTS.fetch(unit) ].min
        return build_relative("last", unit, count, m[0])
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

    # Seasons require a qualifier ("last spring", "next winter") or an explicit
    # year ("winter 2025", "spring of 2026") — bare season words are too common
    # in code ("spring boot config", "fall back logic").
    def extract_season(text)
      m = text.match(/\b(?:((?:last|this|next)\s+#{SEASON_NAME})\b|\b(#{SEASON_NAME})\s+(?:of\s+)?(#{YEAR}))/)
      return nil unless m

      qualifier = m[1]&.split&.first
      season = m[2] || m[1]&.split&.last
      year = m[3]&.to_i
      span = season_span(season, year, qualifier)
      span && build(after: span.first, before: span.last, matched: m[0])
    end

    # Resolve a season mention to a concrete year span. Without an explicit
    # year: "last" = the most recently finished occurrence (the current year's
    # if it already ended, else the previous year's); "this" = the occurrence
    # containing today, or this year's upcoming one if it hasn't started;
    # "next" = the upcoming occurrence strictly after today's season.
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
        # "this": this year's occurrence (current, past, or upcoming).
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
    # `on`/`at` demand a fuller unit (no bare year): "screen at 1920" and
    # "on 2024" are not temporal phrases.
    def extract_cued_unit(text)
      m = text.match(/\b(?:in|during|throughout)\s+(#{UNIT_PATTERN})\b/) ||
          text.match(/\b(?:on|at)\s+(?:#{MONTH_NAME}\s+#{YEAR}|#{ISO_DATE}|#{QUARTER}\s*#{YEAR})\b/)
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

    # @param fragment [String] connector atom — a unit or a relative atom
    # @return [Range, nil] [start..end] of the period described
    def parse_atom(fragment)
      text = fragment.to_s.strip.downcase

      if (m = text.match(/\A(last|this|next)\s+(week|month|year)\z/))
        return relative_span(m[1], m[2], 1)
      end

      case text
      when "yesterday" then 1.day.ago.beginning_of_day..1.day.ago.end_of_day
      when "today"     then Time.current.beginning_of_day..Time.current.end_of_day
      when "tomorrow"  then 1.day.from_now.beginning_of_day..1.day.from_now.end_of_day
      else parse_unit(text)
      end
    end

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

    def relative_span(qualifier, unit, count)
      now = Time.current
      case qualifier
      when "last"
        t = now.public_send("prev_#{unit}")
        t.public_send("beginning_of_#{unit}")..t.public_send("end_of_#{unit}")
      when "this"
        now.public_send("beginning_of_#{unit}")..now.public_send("end_of_#{unit}")
      when "next"
        t = now.public_send("next_#{unit}")
        t.public_send("beginning_of_#{unit}")..t.public_send("end_of_#{unit}")
      end
    end

    def month_number(name)
      MONTH_NAMES.find { |n, _i| n == name || n.start_with?(name) }&.last
    end

    def month_span(year, month)
      start = Time.zone.local(year, month, 1)
      start..start.end_of_month
    end

    def day_span(year, month, day)
      # Time.zone.local silently rolls invalid days over (2026-02-30 → Mar 2)
      # instead of raising — validate the calendar date first.
      return nil unless Date.valid_date?(year, month, day)

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
