# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntityPanel do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  def observation(content, trust:, confidence:)
    MemoryObservation.create!(memory_entity: widget, content: content).tap do |record|
      record.update_columns(trust_score: trust, confidence: confidence)
    end
  end

  describe "#page_of" do
    it "finds the page in the panel's own ordering: trust, then confidence with NULLs last, then id" do
      stub_const("#{described_class}::OBSERVATIONS_PER_PAGE", 2)
      high = observation("SynthWidget high.", trust: 0.9, confidence: nil)
      sure = observation("SynthWidget sure.", trust: 0.5, confidence: 0.8)
      unsure = observation("SynthWidget unsure.", trust: 0.5, confidence: nil)
      tie = observation("SynthWidget tie.", trust: 0.5, confidence: nil)
      low = observation("SynthWidget low.", trust: 0.1, confidence: 0.9)

      panel = described_class.new(widget)
      ordered = [ high, sure, unsure, tie, low ]
      expect(ordered.map { |record| panel.page_of(record) }).to eq([ 1, 1, 2, 2, 3 ])
      expect(described_class.new(widget, page: 2).observations).to eq([ unsure, tie ])
    end
  end
end
