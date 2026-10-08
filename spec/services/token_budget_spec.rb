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
end
