# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationTypeMapping, type: :model do
  describe ".canonicalize" do
    before do
      described_class.create!(canonical_type: "depends_on", variant: "requires")
    end

    it "returns the canonical relation type case-insensitively" do
      expect(described_class.canonicalize(" Requires ")).to eq("depends_on")
    end

    it "returns nil for unmapped relation types" do
      expect(described_class.canonicalize("unknown")).to be_nil
    end
  end

  it "enforces case-insensitive variant uniqueness" do
    described_class.create!(canonical_type: "part_of", variant: "belongs_to")
    duplicate = described_class.new(canonical_type: "part_of", variant: "BELONGS_TO")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:variant]).to be_present
  end
end
