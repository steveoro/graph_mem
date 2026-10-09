# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationTypeMapping, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe ".canonicalize" do
    before do
      described_class.create!(canonical_type: "depends_on", variant: "requires")
      described_class.reset_canonicalize_cache!
    end

    it "returns the canonical relation type case-insensitively" do
      expect(described_class.canonicalize(" Requires ")).to eq("depends_on")
    end

    it "returns nil for unmapped relation types" do
      expect(described_class.canonicalize("unknown")).to be_nil
    end

    it "expires cached lookups after the TTL so re-seeded variants take effect" do
      mapping = described_class.find_by!(variant: "requires")
      expect(described_class.canonicalize("requires")).to eq("depends_on")

      # Simulate a re-seed in another process: the row changes underneath
      # this process's memo, and only the TTL bounds the staleness.
      mapping.update_column(:canonical_type, "belongs_to")
      expect(described_class.canonicalize("requires")).to eq("depends_on")

      travel_to(described_class::CANONICALIZE_TTL.from_now + 1.second) do
        expect(described_class.canonicalize("requires")).to eq("belongs_to")
      end
    end
  end

  it "enforces case-insensitive variant uniqueness" do
    described_class.create!(canonical_type: "part_of", variant: "belongs_to")
    duplicate = described_class.new(canonical_type: "part_of", variant: "BELONGS_TO")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:variant]).to be_present
  end
end
