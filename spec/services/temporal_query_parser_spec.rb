# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalQueryParser do
  include ActiveSupport::Testing::TimeHelpers

  describe ".extract" do
    around do |example|
      travel_to(Time.zone.parse("2026-10-07 12:00:00")) { example.run }
    end

    it "returns nil for a non-temporal query" do
      expect(described_class.extract("Swimmer decorator")).to be_nil
    end

    it "parses an ISO month name with year" do
      result = described_class.extract("what changed in October 2026")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-10-01").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-10-31").end_of_day)
    end

    it "parses a bare year" do
      result = described_class.extract("facts during 2024")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2024-01-01").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2024-12-31").end_of_day)
    end

    it "parses an ISO year-month" do
      result = described_class.extract("deploys in 2026-08")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-08-01").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-08-31").end_of_day)
    end

    it "parses a quarter" do
      result = described_class.extract("results from Q3 2026")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-07-01").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-09-30").end_of_day)
    end

    it "parses last week as the previous calendar week" do
      result = described_class.extract("changes from last week")
      expect(result.window.occurred_after).to eq(1.week.ago.beginning_of_week)
      expect(result.window.occurred_before).to eq(1.week.ago.end_of_week)
    end

    it "parses a season qualifier" do
      result = described_class.extract("incidents last spring")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-03-20").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-06-20").end_of_day)
    end

    it "parses yesterday as a day window" do
      result = described_class.extract("what happened yesterday")
      expect(result.window.occurred_after).to eq(1.day.ago.beginning_of_day)
      expect(result.window.occurred_before).to eq(1.day.ago.end_of_day)
    end

    it "labels the matched phrase" do
      expect(described_class.extract("events during 2025").matched).to include("2025")
    end
  end
  describe "false-positive guards" do
    around { |e| travel_to(Time.zone.parse("2026-10-07 12:00:00")) { e.run } }

    %w[market maybe novel junk].each do |word|
      it "does not treat \"#{word}\" as a month" do
        expect(described_class.extract("updates in #{word}")).to be_nil
      end
    end

    [ "login 2024", "migration 2025", "format 2024", "plugin 2023", "chat 2024" ].each do |phrase|
      it "does not parse \"#{phrase}\" (cue word inside a longer word)" do
        expect(described_class.extract(phrase)).to be_nil
      end
    end

    it "rejects years glued to suffixes" do
      expect(described_class.extract("in 2048-bit keys")).to be_nil
      expect(described_class.extract("1920x1080 screens")).to be_nil
      expect(described_class.extract("screen at 1920")).to be_nil
      expect(described_class.extract("on 2024")).to be_nil
    end

    it "rejects bare seasons" do
      expect(described_class.extract("spring boot config")).to be_nil
      expect(described_class.extract("fall back logic")).to be_nil
      expect(described_class.extract("events in autumn")).to be_nil
    end
  end

  describe "qualified seasons" do
    around { |e| travel_to(Time.zone.parse("2026-10-07 12:00:00")) { e.run } }

    it "parses a season with a year" do
      result = described_class.extract("events in autumn 2026")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-09-23").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-12-21").end_of_day)
    end

    it "parses a qualified season" do
      result = described_class.extract("work done last spring")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-03-20").beginning_of_day)
    end
  end

  describe "additional forms" do
    around { |e| travel_to(Time.zone.parse("2026-10-07 12:00:00")) { e.run } }

    it "parses an \"as of\" phrase into a point window" do
      result = described_class.extract("state as of 2026-06-01")
      expect(result.window.as_of).to eq(Time.zone.parse("2026-06-01").end_of_day)
    end

    it "parses relative atoms after connectors" do
      result = described_class.extract("changes since yesterday")
      expect(result.window.occurred_after).to eq(1.day.ago.beginning_of_day)
      expect(result.window.occurred_before).to be_nil
    end

    it "caps absurd \"last N units\" counts" do
      result = described_class.extract("last 99999999 years")
      expect(result.window.occurred_after).to be > Time.zone.parse("1800-01-01")
      expect(result.window.occurred_after).to be_within(1.day).of(100.years.ago)
    end
  end

  describe ".apply capitalization" do
    it "strips capitalized temporal phrases from the effective query" do
      extraction = described_class.apply("Alpha in October 2026")

      expect(extraction.effective_query).to eq("Alpha")
      expect(extraction.window).to be_present
    end

    it "treats a capitalized temporal-only query as temporal-only" do
      extraction = described_class.apply("In October 2026")

      expect(extraction.effective_query).to eq("")
      expect(extraction).to be_temporal_only
    end
  end

  describe "filler-word residuals" do
    it "treats 'what changed in august 2026' as time-only" do
      expect(described_class.apply("what changed in august 2026")).to be_temporal_only
      expect(described_class.apply("What changed In August 2026")).to be_temporal_only
    end

    it "treats 'what happened in Q3 2026' and 'changes last month' as time-only" do
      expect(described_class.apply("what happened in Q3 2026")).to be_temporal_only
      expect(described_class.apply("changes last month")).to be_temporal_only
    end

    it "keeps real residual terms in the effective query" do
      extraction = described_class.apply("alpha changes in august 2026")
      expect(extraction.effective_query).to eq("alpha changes")
      expect(extraction).not_to be_temporal_only
    end

    it "never strips filler when no date phrase matched" do
      extraction = described_class.apply("what changed")
      expect(extraction.effective_query).to eq("what changed")
      expect(extraction.window).to be_nil
    end
  end

  describe "invalid calendar days" do
    it "rejects non-existent dates and keeps leap day only on leap years" do
      expect(described_class.extract("2026-02-30")).to be_nil
      expect(described_class.extract("2026-04-31")).to be_nil
      expect(described_class.extract("2025-02-29")).to be_nil
      expect(described_class.extract("2028-02-29")).not_to be_nil
    end
  end
end
