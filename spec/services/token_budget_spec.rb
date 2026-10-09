# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenBudget do
  describe ".estimate" do
    it "estimates ~4 chars per token over the JSON form" do
      # "aaaa…" serializes to 42 chars including quotes -> ceil(42/4) = 11
      expect(described_class.estimate("a" * 40)).to eq(11)
    end
  end

  describe ".fit" do
    let(:items) { [ { v: "a" * 40 }, { v: "b" * 40 }, { v: "c" * 40 } ] }

    it "returns all items unmodified when max_tokens is nil" do
      result = described_class.fit(items, max_tokens: nil)
      expect(result.items).to eq(items)
      expect(result.truncated).to be(false)
    end

    it "packs whole items until the next would exceed the budget" do
      result = described_class.fit(items, max_tokens: described_class.estimate(items.first) * 2 + 5)
      expect(result.items.size).to eq(2)
      expect(result.truncated).to be(true)
    end

    it "returns everything when the budget covers all items" do
      result = described_class.fit(items, max_tokens: 1_000_000)
      expect(result.items.size).to eq(3)
      expect(result.truncated).to be(false)
    end

    it "returns an empty truncated result when the first item alone exceeds the budget" do
      result = described_class.fit(items, max_tokens: 1)
      expect(result.items).to eq([])
      expect(result.truncated).to be(true)
    end
  end

  describe ".validate_max_tokens!" do
    it "rejects hex strings, floats, scientific notation and signed strings" do
      [ "0x10", 5.7, "1e3", "+5" ].each do |bad|
        expect { described_class.validate_max_tokens!(bad) }.to raise_error(ArgumentError)
      end
    end

    it "accepts Integers and base-10 digit strings (with surrounding space)" do
      expect(described_class.validate_max_tokens!(" 7 ")).to eq(7)
      expect(described_class.validate_max_tokens!(7)).to eq(7)
      expect(described_class.validate_max_tokens!(nil)).to be_nil
    end
  end

  describe ".fit_with_envelope" do
    it "packs items into the budget left after the envelope" do
      items = [ { "a" => "x" * 40 }, { "b" => "y" * 40 } ]
      envelope = { "mode" => "summary", "results" => [], "retrieval" => { "scope" => "x" * 60 } }
      envelope_cost = described_class.estimate(envelope)

      result = described_class.fit_with_envelope(items, envelope: envelope, max_tokens: envelope_cost + 12)

      expect(result.envelope_tokens).to eq(envelope_cost)
      expect(result.items.size).to be <= 1
      expect(result.estimated_tokens + result.envelope_tokens).to be <= envelope_cost + 12
    end

    it "returns an empty truncated result when the envelope alone exceeds the budget" do
      result = described_class.fit_with_envelope(
        [ { "a" => 1 } ], envelope: { "pad" => "x" * 400 }, max_tokens: 5
      )
      expect(result.items).to eq([])
      expect(result.truncated).to be(true)
    end
  end
end
