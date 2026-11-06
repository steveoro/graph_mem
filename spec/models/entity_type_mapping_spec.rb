# frozen_string_literal: true

require "rails_helper"

# 1.74.0: a variant the table doesn't hold falls back to GraphVocabulary, so new canonical types
# (the Rails roles) canonicalize on an install that hasn't re-run db:seed.
RSpec.describe EntityTypeMapping do
  before { described_class.reset_canonicalize_cache! }
  after { described_class.reset_canonicalize_cache! }

  it "prefers a row of the table" do
    described_class.create!(variant: "widget_controller", canonical_type: "Component")

    expect(described_class.canonicalize("Widget_Controller")).to eq("Component")
  end

  it "falls back to the vocabulary for a variant or type name the table doesn't hold" do
    expect(described_class.canonicalize("controllers")).to eq("Controller")
    expect(described_class.canonicalize("Strategies")).to eq("Strategy")
    expect(described_class.canonicalize("layout")).to eq("Layout")
    expect(described_class.canonicalize("Mailer")).to eq("Mailer")
  end

  it "still answers nil for a type nobody knows" do
    expect(described_class.canonicalize("SynthWidgetKind")).to be_nil
    expect(described_class.canonicalize(" ")).to be_nil
  end
end
