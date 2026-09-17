# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphVocabulary do
  it "exposes the code-owned canonical type examples" do
    expect(described_class::ENTITY_TYPES).to include("Project", "Feature", "Documentation")
    expect(described_class::RELATION_TYPES).to include("part_of", "integrates_with", "replaces")
  end

  describe ".suggestion" do
    it "suggests likely misspellings without treating custom values as invalid" do
      expect(
        described_class.suggestion("Projct", described_class::ENTITY_TYPES)
      ).to eq(submitted: "Projct", suggested: "Project")
      expect(
        described_class.suggestion("CompletelyNovelDomainConcept", described_class::ENTITY_TYPES)
      ).to be_nil
    end

    it "does not suggest for canonical values" do
      expect(
        described_class.suggestion("project", described_class::ENTITY_TYPES)
      ).to be_nil
    end
  end
end
