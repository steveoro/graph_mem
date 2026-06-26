# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingsMaintenanceJob, type: :job do
  include ActiveJob::TestHelper

  describe "#perform" do
    it "runs backfill mode" do
      expect(EmbeddingService).to receive(:backfill_all).and_return(entities: 1, observations: 2)

      expect {
        described_class.perform_now("backfill")
      }.to change(MaintenanceReport.by_type("embedding_maintenance"), :count).by(1)

      report = MaintenanceReport.by_type("embedding_maintenance").last
      expect(report.data["mode"]).to eq("backfill")
      expect(report.data["entities"]).to eq(1)
      expect(report.data["observations"]).to eq(2)
    end

    it "runs regenerate mode" do
      expect(EmbeddingService).to receive(:regenerate_all).and_return(entities: 3, observations: 4)

      described_class.perform_now("regenerate")
    end

    it "raises for unknown mode" do
      expect {
        described_class.perform_now("invalid")
      }.to raise_error(ArgumentError, /unknown mode/)
    end
  end
end
