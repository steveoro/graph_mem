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

  it "leaves out digits inside identifiers, and finds nothing in plain text" do
    expect(described_class.extract("Runs gemma3 with utf8mb4 tables")).to be_empty
    expect(described_class.extract("Validates presence of name")).to be_empty
  end

  it "compares two texts' details: none, the same (in any order) or different" do
    expect(described_class.compare("No numbers", "None here either")).to eq(:none)
    expect(described_class.compare("Ruby 3.4.12 and Rails 8.1", "Rails 8.1 with Ruby 3.4.12")).to eq(:same)
    expect(described_class.compare("Rails 8.0", "Rails 8.1")).to eq(:different)
    expect(described_class.compare("Uses Rails", "Uses Rails 8.1")).to eq(:different)
    expect(described_class.compare("Rails 8.0", "Rails 8")).to eq(:different)
  end
end
