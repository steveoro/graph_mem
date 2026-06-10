# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionValve, type: :service do
  after { CompactionRun.delete_all }

  describe ".request_pause_if_running!" do
    it "returns false when no compaction is running" do
      expect(described_class.request_pause_if_running!).to be false
    end

    it "sets pause_requested and waits until the run is paused" do
      run = CompactionRun.create!(status: "running", phase: "orphans", stats: {})

      Thread.new do
        sleep 0.05
        run.pause!
      end

      expect(described_class.request_pause_if_running!).to be true
      expect(run.reload).to be_paused
    end
  end
end
