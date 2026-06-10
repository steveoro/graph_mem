# frozen_string_literal: true

require "rails_helper"

RSpec.describe DreamStateStatusTool, type: :model do
  let(:tool) { described_class.new }

  after { CompactionRun.delete_all }

  describe "#call" do
    it "returns idle when no runs exist" do
      expect(tool.call).to eq(dream_state: "idle")
    end

    it "returns the current run snapshot" do
      run = CompactionRun.create!(
        status: "running",
        phase: "orphans",
        cursor_entity_id: 7,
        stats: { "entities_processed" => 1 },
        started_at: Time.current
      )

      result = tool.call

      expect(result[:dream_state]).to eq("running")
      expect(result[:run_id]).to eq(run.id)
      expect(result[:phase]).to eq("orphans")
      expect(result[:cursor_entity_id]).to eq(7)
    end
  end
end
