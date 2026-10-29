# frozen_string_literal: true

require "rails_helper"

RSpec.describe MemoryObservationResource, type: :model do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  def contents_for(params)
    JSON.parse(described_class.new(params).content)["observations"].map { |observation| observation["content"] }
  end

  it "treats % and _ in the content filter as literal characters" do
    %w[100%\ done 1000\ rows a_b axb].each { |text| MemoryObservation.create!(memory_entity: widget, content: "SynthWidget #{text}") }

    expect(contents_for(content: "100%")).to contain_exactly("SynthWidget 100% done")
    expect(contents_for(content: "a_b")).to contain_exactly("SynthWidget a_b")
  end
end
