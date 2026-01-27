# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExportProgressChannel, type: :channel do
  describe ".broadcast_progress" do
    it "broadcasts progress update to the channel" do
      export_id = "test-export-123"

      expect(ActionCable.server).to receive(:broadcast).with(
        "export_progress_#{export_id}",
        hash_including(
          type: "progress",
          current: 5,
          total: 10,
          percentage: 50.0,
          message: "Exporting: Test Node"
        )
      )

      described_class.broadcast_progress(export_id, {
        current: 5,
        total: 10,
        message: "Exporting: Test Node"
      })
    end
  end

  describe ".broadcast_complete" do
    it "broadcasts completion message to the channel" do
      export_id = "test-export-123"

      expect(ActionCable.server).to receive(:broadcast).with(
        "export_progress_#{export_id}",
        hash_including(
          type: "complete",
          success: true,
          download_path: "/download/path"
        )
      )

      described_class.broadcast_complete(export_id, {
        success: true,
        download_path: "/download/path",
        message: "Export complete!"
      })
    end
  end

  describe ".broadcast_error" do
    it "broadcasts error message to the channel" do
      export_id = "test-export-123"

      expect(ActionCable.server).to receive(:broadcast).with(
        "export_progress_#{export_id}",
        hash_including(
          type: "error",
          error: "Something went wrong"
        )
      )

      described_class.broadcast_error(export_id, "Something went wrong")
    end
  end

  describe "subscription" do
    it "subscribes with export_id parameter" do
      subscribe(export_id: "test-123")
      expect(subscription).to be_confirmed
    end

    it "rejects without export_id parameter" do
      subscribe(export_id: nil)
      expect(subscription).to be_rejected
    end
  end
end
