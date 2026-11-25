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
      fs_member!(linked_project, nested_task)
      fs_member!(project, linked_project)

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

    context "with the SQL format" do
      let(:export_id) { SecureRandom.uuid }
      let(:sql_path) { described_class.download_path(export_id, format: "sql") }

      after { FileUtils.rm_f(Dir.glob(described_class.download_path(export_id, format: "*"))) }

      def sql_operation(details: { "format" => "sql", "root_names" => [ "TestProject" ] })
        OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending", details: details)
      end

      it "writes export_<uuid>.sql through SqlExport::Writer, steps one table at a time, and keeps the row's details" do
        member = fs_member!(project, "SynthWidget", "Component")
        fs_observe!(member, "SynthWidget renders tiles.")
        sql_operation
        allow(OperationProgressBroadcaster).to receive(:call).and_call_original

        described_class.new.perform(export_id, [ project.id ])

        operation = OperationProgress.sole
        steps = SqlExport::Template::COLUMNS.size
        expect(operation).to have_attributes(status: "completed", current_count: steps, total_count: steps,
                                             details: { "format" => "sql", "root_names" => [ "TestProject" ] })
        expect(File.exist?(sql_path)).to be(true)
        expect(described_class.export_exists?(export_id, format: "sql")).to be(true)
        expect(described_class.export_exists?(export_id)).to be(false)
        script = File.read(sql_path)
        expect(script.lines.first).to start_with("-- graph_mem-sql v")
        expect(script).to include("SynthWidget renders tiles.")
        expect { SqlImport::Validator.validate(script) }.not_to raise_error
        expect(OperationProgressBroadcaster).to have_received(:call).at_least(steps).times
      end

      it "takes the format from the argument for a run without a row, and records it" do
        described_class.new.perform(export_id, [ project.id ], format: "sql")

        expect(File.exist?(sql_path)).to be(true)
        expect(OperationProgress.sole).to have_attributes(status: "completed", details: include("format" => "sql"))
      end

      it "fails the row, naming a root a script can't carry, and leaves no file" do
        member = fs_member!(project, "SynthWidget", "Component")
        sql_operation

        described_class.new.perform(export_id, [ member.id ])

        expect(OperationProgress.sole).to have_attributes(status: "failed", error_message: include("member of a project"))
        expect(File.exist?(sql_path)).to be(false)
      end

      it "fails the row for an unknown format" do
        sql_operation(details: { "format" => "xml" })

        described_class.new.perform(export_id, [ project.id ])

        expect(OperationProgress.sole).to have_attributes(status: "failed", error_message: include("unknown export format 'xml'"))
      end
    end

    it "writes JSON when the row says json, and when it says nothing" do
      [ { "format" => "json" }, {} ].each do |details|
        export_id = SecureRandom.uuid
        OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending", details: details)

        described_class.new.perform(export_id, [ project.id ])

        expect(JSON.parse(File.read(described_class.download_path(export_id)))["root_nodes"].first["name"]).to eq("TestProject")
        expect(File.exist?(described_class.download_path(export_id, format: "sql"))).to be(false)
      ensure
        FileUtils.rm_f(described_class.download_path(export_id))
      end
    end

    it "marks its OperationProgress failed on an error" do
      export_id = SecureRandom.uuid
      allow_any_instance_of(ExportStrategy).to receive(:export_json_with_progress).and_raise(StandardError, "Test error")

      described_class.new.perform(export_id, [ project.id ])

      expect(OperationProgress.find_by!(operation_id: export_id)).to have_attributes(status: "failed", error_message: "Test error")
    end
  end

  describe ".cleanup_old_exports" do
    it "removes expired files of both formats and keeps fresh ones" do
      FileUtils.mkdir_p(described_class::TEMP_DIR)
      old_ids = Array.new(2) { SecureRandom.uuid }
      fresh = SecureRandom.uuid
      paths = [ [ old_ids[0], "json" ], [ old_ids[1], "sql" ], [ fresh, "sql" ] ].map do |id, format|
        described_class.download_path(id, format: format).tap { |path| File.write(path, "x") }
      end
      [ paths[0], paths[1] ].each { |path| File.utime(Time.now - 7200, Time.now - 7200, path) }

      described_class.cleanup_old_exports

      expect(paths.map { |path| File.exist?(path) }).to eq([ false, false, true ])
    ensure
      FileUtils.rm_f(paths)
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
