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
    it "reports progress through its OperationProgress row and completes it" do
      export_id = SecureRandom.uuid
      allow(OperationProgressBroadcaster).to receive(:call).and_call_original

      described_class.new.perform(export_id, [ project.id ])

      expect(OperationProgress.find_by!(operation_id: export_id)).to have_attributes(operation_type: "export", status: "completed")
      expect(OperationProgressBroadcaster).to have_received(:call).at_least(:twice)
      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "takes over the pending operation Projects › Exports wrote, details kept, and completes it" do
      export_id = SecureRandom.uuid
      OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending",
                                details: { "root_names" => [ "TestProject" ] })

      expect { described_class.new.perform(export_id, [ project.id ]) }.not_to change(OperationProgress, :count)

      expect(OperationProgress.sole).to have_attributes(status: "completed", details: { "root_names" => [ "TestProject" ] })
      expect(OperationProgress.sole.started_at).to be_present
    ensure
      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "schedules ExportJob.cleanup_old_exports hourly in development and production" do
      recurring = YAML.load_file(Rails.root.join("config/recurring.yml"))

      %w[development production].each do |env|
        expect(recurring.dig(env, "export_cleanup")).to include("command" => "ExportJob.cleanup_old_exports", "schedule" => "every hour")
      end
    end

    it "creates export file in tmp/exports directory" do
      export_id = SecureRandom.uuid

      described_class.new.perform(export_id, [ project.id ])

      expect(File.exist?(described_class.download_path(export_id))).to be true

      # Cleanup
      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "counts nested Projects as shallow boundaries in progress totals" do
      linked_project = MemoryEntity.create!(
        name: "Linked Export Project",
        entity_type: "Project"
      )
      nested_task = MemoryEntity.create!(
        name: "Nested Export Task",
        entity_type: "Task"
      )
      MemoryRelation.create!(
        from_entity: nested_task,
        to_entity: linked_project,
        relation_type: "part_of"
      )
      MemoryRelation.create!(
        from_entity: linked_project,
        to_entity: project,
        relation_type: "part_of"
      )

      export_id = SecureRandom.uuid
      described_class.new.perform(export_id, [ project.id ])

      # Selected root + shallow linked Project only (nested task excluded)
      expect(OperationProgress.find_by!(operation_id: export_id)).to have_attributes(total_count: 2, current_count: 2)

      exported = JSON.parse(File.read(described_class.download_path(export_id)))
      linked_child = exported["root_nodes"].first["children"].find { |child| child["name"] == linked_project.name }
      expect(linked_child["children"]).to eq([])
      expect(File.read(described_class.download_path(export_id))).not_to include(nested_task.name)

      FileUtils.rm_f(described_class.download_path(export_id))
    end

    it "marks its OperationProgress failed on an error" do
      export_id = SecureRandom.uuid
      allow_any_instance_of(ExportStrategy).to receive(:export_json_with_progress).and_raise(StandardError, "Test error")

      described_class.new.perform(export_id, [ project.id ])

      expect(OperationProgress.find_by!(operation_id: export_id)).to have_attributes(status: "failed", error_message: "Test error")
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
