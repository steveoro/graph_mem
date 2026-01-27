# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExportJob, type: :job do
  include ActiveJob::TestHelper

  let!(:project) do
    MemoryEntity.create!(
      name: "TestProject",
      entity_type: "Project",
      aliases: ""
    )
  end

  let!(:observation) do
    MemoryObservation.create!(
      memory_entity: project,
      content: "Test observation"
    )
  end

  describe "#perform" do
    it "broadcasts progress updates" do
      export_id = SecureRandom.uuid

      expect(ExportProgressChannel).to receive(:broadcast_progress).at_least(:once)
      expect(ExportProgressChannel).to receive(:broadcast_complete).with(
        export_id,
        hash_including(success: true)
      )

      described_class.new.perform(export_id, [ project.id ])
    end

    it "creates export file in tmp/exports directory" do
      export_id = SecureRandom.uuid

      allow(ExportProgressChannel).to receive(:broadcast_progress)
      allow(ExportProgressChannel).to receive(:broadcast_complete)

      described_class.new.perform(export_id, [ project.id ])

      expect(File.exist?(described_class.download_path(export_id))).to be true

      # Cleanup
      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "includes download path in completion message" do
      export_id = SecureRandom.uuid

      allow(ExportProgressChannel).to receive(:broadcast_progress)

      expect(ExportProgressChannel).to receive(:broadcast_complete).with(
        export_id,
        hash_including(download_path: "/data_exchange/download_export?export_id=#{export_id}")
      )

      described_class.new.perform(export_id, [ project.id ])

      # Cleanup
      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "broadcasts error on failure" do
      export_id = SecureRandom.uuid

      # Force an error by passing invalid entity IDs that will cause issues
      allow_any_instance_of(ExportStrategy).to receive(:export_json_with_progress).and_raise(StandardError, "Test error")

      expect(ExportProgressChannel).to receive(:broadcast_progress)
      expect(ExportProgressChannel).to receive(:broadcast_error).with(
        export_id,
        "Export failed: Test error"
      )

      described_class.new.perform(export_id, [ project.id ])
    end
  end

  describe ".export_exists?" do
    it "returns true when file exists" do
      export_id = SecureRandom.uuid
      filepath = described_class.download_path(export_id)

      FileUtils.mkdir_p(File.dirname(filepath))
      File.write(filepath, "{}")

      expect(described_class.export_exists?(export_id)).to be true

      # Cleanup
      FileUtils.rm_f(filepath)
    end

    it "returns false when file does not exist" do
      expect(described_class.export_exists?("non-existent")).to be false
    end
  end

  describe "job queueing" do
    it "queues the job" do
      expect {
        described_class.perform_later("test-id", [ 1 ])
      }.to have_enqueued_job(described_class).with("test-id", [ 1 ])
    end
  end
end
