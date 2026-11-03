# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Prompt do
  it "joins trusted and data segments as they are, in order" do
    prompt = described_class.new.trusted("Entity: ").data("SynthWidget").trusted("\nNotes: ").data(nil).data("Alpha Service\n")

    expect(prompt.to_s).to eq("Entity: SynthWidget\nNotes: Alpha Service\n")
    expect(prompt.segments.map { |segment| [ segment.kind, segment.text ] })
      .to eq([ [ :trusted, "Entity: " ], [ :data, "SynthWidget" ], [ :trusted, "\nNotes: " ], [ :data, "" ], [ :data, "Alpha Service\n" ] ])
  end

  it "hands out a copy of its segments" do
    prompt = described_class.new.data("Gadget Project")
    prompt.segments.clear

    expect(prompt.to_s).to eq("Gadget Project")
  end
end
