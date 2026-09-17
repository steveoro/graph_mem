# frozen_string_literal: true

require "rails_helper"

RSpec.describe SubgraphSearchService do
  let(:vector_strategy) { instance_double(VectorSearchStrategy, search: []) }

  before { allow(VectorSearchStrategy).to receive(:new).and_return(vector_strategy) }

  describe ".call" do
    it "returns matched entities, observations, and internal relations" do
      first = MemoryEntity.create!(name: "Shared Alpha", entity_type: "Project")
      second = MemoryEntity.create!(name: "Shared Beta", entity_type: "Task")
      observation = MemoryObservation.create!(memory_entity: first, content: "Shared fact")
      relation = MemoryRelation.create!(from_entity: second, to_entity: first, relation_type: "part_of")

      result = described_class.call(query: "Shared")

      expect(result[:entities].pluck(:entity_id)).to contain_exactly(first.id, second.id)
      first_payload = result[:entities].find { |entity| entity[:entity_id] == first.id }
      expect(first_payload[:observations].pluck(:observation_id)).to include(observation.id)
      expect(result[:relations].pluck(:relation_id)).to include(relation.id)
    end

    it "omits unrequested projections" do
      MemoryEntity.create!(name: "Projection target", entity_type: "Project")

      result = described_class.call(
        query: "Projection",
        include_observations: false,
        include_relations: false
      )

      expect(result).not_to have_key(:relations)
      expect(result[:entities].first).not_to have_key(:observations)
    end

    it "preserves field and paging validations" do
      expect {
        described_class.call(query: "")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /blank/)
      expect {
        described_class.call(
          query: "x",
          search_in_name: false,
          search_in_type: false,
          search_in_aliases: false,
          search_in_observations: false
        )
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one/)
      expect {
        described_class.call(query: "x", page: 0)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Page number/)
    end
  end
end
