# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingScheduledBackfillJob, type: :job do
  include ActiveJob::TestHelper

  before { AppSettings.clear_cache }

  after { AppSettings.clear_cache }

  describe "#perform" do
    it "skips when scheduled backfill is disabled" do
      AppSettings.enable_scheduled_embedding_backfill = false

      expect(EmbeddingsMaintenanceJob).not_to receive(:perform_now)

      described_class.perform_now
    end

    it "runs backfill when enabled" do
      AppSettings.enable_scheduled_embedding_backfill = true

      expect(EmbeddingsMaintenanceJob).to receive(:perform_now).with("backfill")

      described_class.perform_now
    end
  end
end
