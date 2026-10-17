# frozen_string_literal: true

require "rails_helper"
load Rails.root.join("db/migrate/20261013120000_seed_caused_by_relation_mappings.rb")

RSpec.describe SeedCausedByRelationMappings do
  describe "#down" do
    it "removes only variants that still map to caused_by" do
      caused = RelationTypeMapping.find_or_initialize_by(variant: "triggered_by")
      caused.update!(canonical_type: "caused_by")
      remapped = RelationTypeMapping.find_or_initialize_by(variant: "consequence_of")
      remapped.update!(canonical_type: "depends_on")

      described_class.new.down

      expect(RelationTypeMapping.find_by(variant: "triggered_by")).to be_nil
      expect(RelationTypeMapping.find_by(variant: "consequence_of").canonical_type).to eq("depends_on")
    end
  end
end
