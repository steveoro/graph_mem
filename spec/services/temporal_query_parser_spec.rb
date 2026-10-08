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

    it "resolves a bare season to the current year's occurrence" do
      result = described_class.extract("events in autumn")
      expect(result.window.occurred_after).to eq(Time.zone.parse("2026-09-23").beginning_of_day)
      expect(result.window.occurred_before).to eq(Time.zone.parse("2026-12-21").end_of_day)
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
end
