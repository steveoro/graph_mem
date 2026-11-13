# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntityMergeEvidence do
  # Unit vectors in the first two dimensions: distance between [1, 0] and [cos, sin] is 1 - cos.
  def embed(entity, angle_cosine)
    assign_test_embedding!(entity, angle_cosine, Math.sqrt(1 - (angle_cosine**2)))
  end

  def pair_at_distance(distance, names: %w[MergeLeft MergeRight], type: "Task")
    left = MemoryEntity.create!(name: names.first, entity_type: type)
    right = MemoryEntity.create!(name: names.last, entity_type: type)
    assign_test_embedding!(left, 1.0, 0.0)
    embed(right, 1.0 - distance)
    [ left.reload, right.reload ]
  end

  def share(entities, content)
    entities.each { |entity| MemoryObservation.create!(memory_entity: entity, content: content) }
  end

  describe "constants" do
    it "keeps auto-merge at 10 and raises the review floor above the distance-only score" do
      expect(described_class::AUTO_SCORE).to eq(10)
      expect(described_class::REVIEW_SCORE).to eq(6)
    end
  end

  describe ".candidates_for" do
    it "does not queue a distance-only pair at 0.2" do
      left, = pair_at_distance(0.2)

      expect(described_class.candidates_for(left)).to be_empty
    end

    it "still scores a pair under 0.10 at 8 for distance alone" do
      left, right = pair_at_distance(0.05)

      match = described_class.send(:score_pair, left, right, 0.05)

      expect(match.score).to eq(8)
    end

    it "queues a 0.2 pair that shares one distinctive 60-char fact" do
      left, right = pair_at_distance(0.2)
      share([ left, right ], "The importer retries three times with exponential backoff, always.")

      matches = described_class.candidates_for(left)

      expect(matches.map(&:target)).to eq([ right ])
      expect(matches.first.score).to eq(6)
      expect(matches.first.reasons).to include("shared_observations=1")
    end

    it "gives no merge credit for a boilerplate clique sharing 'Status: Completed'" do
      clique = 5.times.map { |index| MemoryEntity.create!(name: "Clique#{index}", entity_type: "Task") }
      clique.each { |member| assign_test_embedding!(member, 1.0, 0.0) }
      share(clique, "Status: Completed")
      share(clique, "Successfully refactored to use fast-mcp syntax.")

      match = described_class.send(:score_pair, clique.first.reload, clique.last.reload, 0.2)

      expect(match.score).to eq(4)
      expect(match.reasons.join).not_to include("shared_observations")
    end

    it "does not count a long fact held by three entities" do
      left, right = pair_at_distance(0.2)
      third = MemoryEntity.create!(name: "MergeThird", entity_type: "Task")
      share([ left, right, third ], "The importer retries three times with exponential backoff, always.")

      expect(described_class.candidates_for(left)).to be_empty
    end
  end

  describe ".qualifies?" do
    it "is false for a distance-only pair in the review band" do
      left, right = pair_at_distance(0.2)

      expect(described_class.qualifies?(left, right)).to be(false)
    end

    it "is true for a review-band pair with distinctive shared evidence" do
      left, right = pair_at_distance(0.2)
      share([ left, right ], "The importer retries three times with exponential backoff, always.")

      expect(described_class.qualifies?(left, right)).to be(true)
    end

    it "is true for a pair under the auto distance" do
      left, right = pair_at_distance(0.05)

      expect(described_class.qualifies?(left, right)).to be(true)
    end

    it "is false when the pair drifted past the review distance, even with evidence" do
      left, right = pair_at_distance(0.5)
      share([ left, right ], "The importer retries three times with exponential backoff, always.")

      expect(described_class.qualifies?(left, right)).to be(false)
    end

    it "is false for entities of different types or without embeddings" do
      left, right = pair_at_distance(0.05)
      right.update_columns(entity_type: "Issue")
      stranger = MemoryEntity.create!(name: "NoEmbedding", entity_type: "Task")

      expect(described_class.qualifies?(left, right)).to be(false)
      expect(described_class.qualifies?(left, stranger)).to be(false)
    end

    it "is false when either entity no longer exists" do
      left, right = pair_at_distance(0.05)

      expect(described_class.qualifies?(left, nil)).to be(false)
      expect(described_class.qualifies?(nil, right)).to be(false)
    end
  end
end
