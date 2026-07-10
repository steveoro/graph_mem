# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionRun, type: :model do
  after { described_class.delete_all }

  describe "validations" do
    it "requires a valid status" do
      run = described_class.new(status: "invalid")
      expect(run).not_to be_valid
    end

    it "accepts known phases" do
      %w[orphans tree_walk relationship_discovery].each do |phase|
        run = described_class.new(status: "running", phase: phase)
        expect(run).to be_valid
      end
    end
  end

  describe "#increment_stat!" do
    it "accumulates stats" do
      run = described_class.create!(status: "running", stats: { "entities_processed" => 2 })
      run.increment_stat!("entities_processed")
      run.increment_stat!("merges_auto", 3)

      expect(run.reload.stats).to eq(
        "entities_processed" => 3,
        "merges_auto" => 3
      )
    end
  end

  describe "#pause!" do
    it "marks the run paused and clears pause_requested" do
      run = described_class.create!(status: "running", pause_requested: true)
      run.pause!

      expect(run.reload).to have_attributes(status: "paused", pause_requested: false)
    end
  end

  describe ".dream_state_active?" do
    it "is true only when a run is running" do
      described_class.create!(status: "paused")
      expect(described_class.dream_state_active?).to be false

      described_class.create!(status: "running")
      expect(described_class.dream_state_active?).to be true
    end
  end
end
