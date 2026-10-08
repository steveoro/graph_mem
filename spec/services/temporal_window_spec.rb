# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalWindow do
  let(:window) do
    described_class.new(
      occurred_after: Time.zone.parse("2026-01-01"),
      occurred_before: Time.zone.parse("2026-01-31")
    )
  end

  describe ".from_params" do
    it "returns nil when no temporal params are given" do
      expect(described_class.from_params).to be_nil
    end

    it "rejects as_of combined with occurred bounds" do
      expect {
        described_class.from_params(as_of: "2026-01-15", occurred_after: "2026-01-01")
      }.to raise_error(ArgumentError, /cannot be combined/)
    end

    it "rejects unparsable bounds" do
      expect {
        described_class.from_params(occurred_after: "not-a-date")
      }.to raise_error(ArgumentError, /invalid temporal bound/)
    end

    it "rejects a window whose bounds are inverted" do
      expect {
        described_class.from_params(occurred_after: "2026-02-01", occurred_before: "2026-01-01")
      }.to raise_error(ArgumentError, /must be on or before/)
    end

    it "builds an as_of window" do
      built = described_class.from_params(as_of: "2026-01-15T10:00:00Z")
      expect(built.as_of).to eq(Time.zone.parse("2026-01-15T10:00:00Z"))
    end

    it "reads a bare occurred_after date as the start of that day" do
      built = described_class.from_params(occurred_after: "2026-01-15")
      expect(built.occurred_after).to eq(Time.zone.parse("2026-01-15").beginning_of_day)
    end

    it "reads a bare occurred_before date as the end of that day" do
      built = described_class.from_params(occurred_before: "2026-01-31")
      expect(built.occurred_before).to eq(Time.zone.parse("2026-01-31").end_of_day)
    end

    it "reads a bare as_of date as the end of that day" do
      built = described_class.from_params(as_of: "2026-01-15")
      expect(built.as_of).to eq(Time.zone.parse("2026-01-15").end_of_day)
    end

    it "keeps full datetimes unchanged on occurred_before" do
      built = described_class.from_params(occurred_before: "2026-01-31T12:30:00Z")
      expect(built.occurred_before).to eq(Time.zone.parse("2026-01-31T12:30:00Z"))
    end
  end

  describe "#covers?" do
    let!(:entity) { MemoryEntity.create!(name: "Temporal Entity", entity_type: "Project") }

    def observation(valid_from: nil, valid_until: nil, created_at: Time.zone.parse("2026-01-10"))
      MemoryObservation.create!(
        memory_entity: entity, content: "fact",
        valid_from: valid_from, valid_until: valid_until, created_at: created_at
      )
    end

    it "includes an undated observation retained inside the window" do
      expect(window.covers?(observation)).to be(true)
    end

    it "excludes an undated observation retained outside the window" do
      expect(window.covers?(observation(created_at: Time.zone.parse("2026-03-01")))).to be(false)
    end

    it "includes an observation whose validity overlaps the window" do
      expect(window.covers?(observation(valid_from: "2026-01-15", valid_until: "2026-02-15"))).to be(true)
      expect(window.covers?(observation(valid_until: "2026-01-10"))).to be(true)
      expect(window.covers?(observation(valid_from: "2026-01-25"))).to be(true)
    end

    it "excludes an observation whose validity is disjoint from the window" do
      expect(window.covers?(observation(valid_from: "2025-01-01", valid_until: "2025-06-01"))).to be(false)
      expect(window.covers?(observation(valid_from: "2026-02-01"))).to be(false)
    end

    it "treats always-valid observations as covering every window" do
      expect(window.covers?(observation(valid_from: "2020-01-01", valid_until: "2030-01-01"))).to be(true)
    end
  end

  describe "#covers? with as_of" do
    let(:as_of_window) { described_class.new(as_of: Time.zone.parse("2026-01-15T12:00:00")) }
    let!(:entity) { MemoryEntity.create!(name: "AsOf Entity", entity_type: "Project") }

    def observation(valid_from: nil, valid_until: nil, created_at: Time.zone.parse("2026-01-10"))
      MemoryObservation.create!(
        memory_entity: entity, content: "fact",
        valid_from: valid_from, valid_until: valid_until, created_at: created_at
      )
    end

    it "includes an undated observation retained before the instant" do
      expect(as_of_window.covers?(observation)).to be(true)
      expect(as_of_window.covers?(observation(created_at: Time.zone.parse("2026-02-01")))).to be(false)
    end

    it "includes only observations whose validity contains the instant" do
      expect(as_of_window.covers?(observation(valid_from: "2026-01-14", valid_until: "2026-01-16"))).to be(true)
      expect(as_of_window.covers?(observation(valid_from: "2026-01-16"))).to be(false)
      expect(as_of_window.covers?(observation(valid_until: "2026-01-14"))).to be(false)
    end
  end

  describe "#observation_predicate" do
    it "produces a usable SQL predicate for a window" do
      sql, binds = window.observation_predicate
      rows = MemoryObservation.where(sql, **binds)
      expect { rows.load }.not_to raise_error
    end
  end
  describe "strict ISO 8601 parsing" do
    it "rejects non-ISO input" do
      [ "10", "October", "next tuesday" ].each do |bad|
        expect { described_class.new(occurred_after: bad) }
          .to raise_error(ArgumentError, /expected ISO 8601/)
      end
    end

    it "rejects invalid calendar dates instead of rolling over" do
      [ "2026-02-30", "2026-13-45" ].each do |bad|
        expect { described_class.new(occurred_after: bad) }.to raise_error(ArgumentError)
      end
    end

    it "widens a bare year-month for the upper bound" do
      w = described_class.new(occurred_before: "2026-02")
      expect(w.occurred_before).to eq(Time.zone.parse("2026-02-28").end_of_day)
    end

    it "widens a bare year for both bounds" do
      w = described_class.new(occurred_after: "2026", occurred_before: "2026")
      expect(w.occurred_after).to eq(Time.zone.parse("2026-01-01").beginning_of_day)
      expect(w.occurred_before).to eq(Time.zone.parse("2026-12-31").end_of_day)
    end
  end
end
