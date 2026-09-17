# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntityCatalogService do
  describe ".call" do
    it "returns stable ID-ordered pages and pagination metadata" do
      entities = 3.times.map do |index|
        MemoryEntity.create!(name: "Catalog #{index}", entity_type: "Project")
      end

      result = described_class.call(page: 2, per_page: 2)

      expect(result[:entities].pluck(:entity_id)).to eq([ entities.third.id ])
      expect(result[:pagination]).to eq(
        total_entities: 3,
        per_page: 2,
        current_page: 2,
        total_pages: 2
      )
    end

    it "keeps one empty page for an empty catalog" do
      result = described_class.call

      expect(result[:entities]).to eq([])
      expect(result[:pagination][:total_pages]).to eq(1)
    end

    it "validates page bounds" do
      expect {
        described_class.call(page: 0)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /page must be/)
      expect {
        described_class.call(per_page: 101)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /per_page must be/)
    end
  end
end
