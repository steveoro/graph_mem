# frozen_string_literal: true

require "rails_helper"

# 1.82.0: a fact's details (versions, numbers, dates), read deterministically, so "the same fact
# with a different detail" can be told from a duplicate.
RSpec.describe FactKeywords::Details do
  it "reads versions, numbers with their unit, dates and years" do
    expect(described_class.extract("Developed using Rails 8.0")).to eq(Set["8.0"])
    expect(described_class.extract("Pinned to v1.7.2, on Ruby 3.4.12")).to eq(Set["1.7.2", "3.4.12"])
    expect(described_class.extract("A 5s timeout and 768-dim vectors")).to eq(Set["5s", "768"])
    expect(described_class.extract("Backed up since 2026-11-12, every year since 2025")).to eq(Set["2026-11-12", "2025"])
    expect(described_class.extract("Fixed in #4227")).to eq(Set["4227"])
  end

  it "reads date-times, decimals and long units, a sign and thousands (1.83.0)" do
    expect(described_class.extract("Backed up at 2026-11-12T10:00:00Z")).to include("2026-11-12")
    expect(described_class.compare("Backed up at 2026-11-12T10:00:00Z", "Backed up at 2026-11-13T10:00:00Z")).to eq(:different)
    expect(described_class.extract("Renders 1.5x faster")).to eq(Set["1.5x"])
    expect(described_class.compare("Renders 1.5x faster", "Renders 1.8x faster")).to eq(:different)
    expect(described_class.extract("Retries after 10mins")).to eq(Set["10mins"])
    expect(described_class.compare("An offset of -5", "An offset of 5")).to eq(:different)
    expect(described_class.extract("Keeps 1,000 rows")).to eq(Set["1000"])
  end

  it "keeps a number right after a hyphen: ranges and names like gpt-4 (final review)" do
    expect(described_class.extract("Retries 3-5 times")).to eq(Set["3", "5"])
    expect(described_class.compare("Retries 3-7 times", "Retries 3-5 times")).to eq(:different)
    expect(described_class.compare("Uses gpt-5", "Uses gpt-4")).to eq(:different)
    expect(described_class.extract("A 768-dim vector")).to eq(Set["768"])
    expect(described_class.compare("An offset of -5", "An offset of 5")).to eq(:different)
  end

  it "leaves out digits inside identifiers, and finds nothing in plain text" do
    expect(described_class.extract("Runs gemma3 with utf8mb4 tables")).to be_empty
    expect(described_class.extract("Validates presence of name")).to be_empty
  end

  it "compares two texts' details: none, the same (in any order), different, or dropped by the newer one" do
    expect(described_class.compare("No numbers", "None here either")).to eq(:none)
    expect(described_class.compare("Ruby 3.4.12 and Rails 8.1", "Rails 8.1 with Ruby 3.4.12")).to eq(:same)
    expect(described_class.compare("Rails 8.0", "Rails 8.1")).to eq(:different)
    expect(described_class.compare("Uses Rails 8.1", "Uses Rails")).to eq(:different) # the newer one adds a detail
    expect(described_class.compare("Uses Rails", "Uses Rails 8.1")).to eq(:dropped)   # the newer one states less
    expect(described_class.compare("Rails 8.0", "Rails 8")).to eq(:different)
  end
end
