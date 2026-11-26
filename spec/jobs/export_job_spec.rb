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
                                details: { "root_names" => [ "TestProject" ], "format" => "sql" })

      expect { described_class.new.perform(export_id, [ project.id ]) }.not_to change(OperationProgress, :count)

      expect(OperationProgress.sole).to have_attributes(status: "completed", details: { "root_names" => [ "TestProject" ], "format" => "sql" })
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

    context "writing the script" do
      let(:export_id) { SecureRandom.uuid }
      let(:sql_path) { described_class.download_path(export_id) }

      after { FileUtils.rm_f(sql_path) }

      def export_operation(details: { "format" => "sql", "root_names" => [ "TestProject" ] })
        OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending", details: details)
      end

      it "writes export_<uuid>.sql through SqlExport::Writer, steps one table at a time, and keeps the row's details" do
        member = fs_member!(project, "SynthWidget", "Component")
        fs_observe!(member, "SynthWidget renders tiles.")
        export_operation
        allow(OperationProgressBroadcaster).to receive(:call).and_call_original

        described_class.new.perform(export_id, [ project.id ])

        operation = OperationProgress.sole
        steps = SqlExport::Template::COLUMNS.size
        expect(operation).to have_attributes(status: "completed", current_count: steps, total_count: steps,
                                             details: { "format" => "sql", "root_names" => [ "TestProject" ] })
        expect(sql_path).to end_with("export_#{export_id}.sql")
        expect(described_class.export_exists?(export_id)).to be(true)
        script = File.read(sql_path)
        expect(script.lines.first).to start_with("-- graph_mem-sql v")
        expect(script).to include("SynthWidget renders tiles.")
        expect { SqlImport::Validator.validate(script) }.not_to raise_error
        expect(OperationProgressBroadcaster).to have_received(:call).at_least(steps).times
      end

      it "writes a script for a row that names no format, and records the format on it" do
        export_operation(details: { "root_names" => [ "TestProject" ] })

        described_class.new.perform(export_id, [ project.id ])

        expect(File.exist?(sql_path)).to be(true)
        expect(OperationProgress.sole).to have_attributes(status: "completed", details: { "root_names" => [ "TestProject" ], "format" => "sql" })
      end

      it "fails the row, naming a root a script can't carry, and leaves no file" do
        member = fs_member!(project, "SynthWidget", "Component")
        export_operation

        described_class.new.perform(export_id, [ member.id ])

        expect(OperationProgress.sole).to have_attributes(status: "failed", error_message: include("member of a project"))
        expect(File.exist?(sql_path)).to be(false)
      end

      it "fails a JSON row, saying the JSON export was retired, and writes no file" do
        export_operation(details: { "format" => "json" })

        described_class.new.perform(export_id, [ project.id ])

        expect(OperationProgress.sole).to have_attributes(status: "failed", error_message: include("JSON export was retired in 1.94.0"))
        expect(Dir.glob(File.join(described_class::TEMP_DIR, "export_#{export_id}.*"))).to be_empty
      end

      it "fails the row for an unknown format" do
        export_operation(details: { "format" => "xml" })

        described_class.new.perform(export_id, [ project.id ])

        expect(OperationProgress.sole).to have_attributes(status: "failed", error_message: include("unknown export format 'xml'"))
      end
    end

    it "marks its OperationProgress failed on an error" do
      export_id = SecureRandom.uuid
      allow_any_instance_of(SqlExport::Writer).to receive(:write_file).and_raise(StandardError, "Test error")

      described_class.new.perform(export_id, [ project.id ])

      expect(OperationProgress.find_by!(operation_id: export_id)).to have_attributes(status: "failed", error_message: "Test error")
    end
  end

  describe ".cleanup_old_exports" do
    it "removes expired scripts and the JSON files the retired JSON export left, and keeps fresh ones" do
      FileUtils.mkdir_p(described_class::TEMP_DIR)
      old_ids = Array.new(2) { SecureRandom.uuid }
      fresh = SecureRandom.uuid
      paths = [ [ old_ids[0], "json" ], [ old_ids[1], "sql" ], [ fresh, "sql" ] ].map do |id, extension|
        File.join(described_class::TEMP_DIR, "export_#{id}.#{extension}").tap { |path| File.write(path, "x") }
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
      File.write(filepath, "-- graph_mem-sql v1\n")

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
