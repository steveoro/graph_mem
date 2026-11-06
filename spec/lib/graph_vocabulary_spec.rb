# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphVocabulary do
  it "exposes the code-owned canonical type examples" do
    expect(described_class::ENTITY_TYPES).to include("Project", "Feature", "Documentation")
    expect(described_class::RELATION_TYPES).to include("part_of", "integrates_with", "replaces",
                                                       "caused_by")
  end

  it "appends the Rails role types (1.74.0) after the earlier types" do
    roles = %w[Controller Helper Job Mailer Concern View Layout Decorator Validator Strategy Command]

    expect(described_class::ENTITY_TYPES.last(roles.size)).to eq(roles)
    expect(described_class::RAILS_ROLE_TYPES).to include("Model", *roles)
    expect(described_class::RAILS_ROLE_TYPES - described_class::ENTITY_TYPES).to be_empty
    expect(described_class::GENERIC_CODE_TYPES).to eq(%w[Class Module])
  end

  it "maps no variant to two canonical types" do
    owners = described_class::ENTITY_TYPE_MAPPINGS.flat_map { |type, variants| ([ type.downcase ] + variants).uniq.map { |variant| [ variant, type ] } }
    clashes = owners.group_by(&:first).select { |_variant, pairs| pairs.map(&:last).uniq.size > 1 }

    expect(clashes).to be_empty
  end

  it "keeps forward causal verbs out of caused_by variants (direction guard)" do
    # `led_to`/`resulted_in`/`triggered` read FORWARD; canonicalizing them
    # into backward-reading `caused_by` would store edges inverted.
    variants = described_class::RELATION_TYPE_MAPPINGS["caused_by"]
    expect(variants).to include("resulted_from", "triggered_by")
    expect(variants).not_to include("led_to", "resulted_in", "triggered")
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

  it "member_of/component_of stay out of part_of (membership is many-to-many)" do
    variants = described_class::RELATION_TYPE_MAPPINGS["part_of"]
    expect(variants).not_to include("member_of", "component_of")
    # With them un-mapped, `X member_of A` + `X member_of B` can never be
    # collapsed into single-parent part_of edges: unknown variants stay
    # their own literal types (many-to-many-safe).
    expect(described_class::RELATION_TYPE_MAPPINGS["part_of"]).to include("is_part_of")
    expect(
      described_class::RELATION_TYPE_MAPPINGS.values.flatten
    ).not_to include("member_of", "component_of")
  end
end
