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

    it "re-enqueues itself after a deferred backfill and records deferred in the report" do
      expect(EmbeddingService).to receive(:backfill_all)
        .and_return(entities: 0, observations: 0, deferred: true)

      expect {
        described_class.perform_now("backfill")
      }.to have_enqueued_job(described_class).with("backfill")
        .at(a_value_within(2).of(described_class::DEFERRED_RETRY_INTERVAL.from_now))

      report = MaintenanceReport.by_type("embedding_maintenance").last
      expect(report.data["mode"]).to eq("backfill")
      expect(report.data["deferred"]).to be true
    end

    it "does not re-enqueue when the backfill is not deferred" do
      expect(EmbeddingService).to receive(:backfill_all)
        .and_return(entities: 1, observations: 0, deferred: false)

      expect {
        described_class.perform_now("backfill")
      }.not_to have_enqueued_job(described_class)

      report = MaintenanceReport.by_type("embedding_maintenance").last
      expect(report.data["deferred"]).to be false
    end

    it "raises for unknown mode" do
      expect {
        described_class.perform_now("invalid")
      }.to raise_error(ArgumentError, /unknown mode/)
    end
  end
end
