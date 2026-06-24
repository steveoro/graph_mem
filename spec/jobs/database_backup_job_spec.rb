# frozen_string_literal: true

require "rails_helper"

RSpec.describe DatabaseBackupJob, type: :job do
  include ActiveJob::TestHelper

  let(:backup_dir) { Rails.root.join("tmp", "test_job_backups") }

  before do
    FileUtils.mkdir_p(backup_dir)
    AppSettings.backup_folder_path = backup_dir.to_s
    AppSettings.enable_scheduled_backups = true
  end

  after do
    FileUtils.rm_rf(backup_dir)
    AppSettings.clear_cache
  end

  describe "#perform" do
    context "when scheduled backups are disabled" do
      before do
        AppSettings.enable_scheduled_backups = false
        FileUtils.rm_rf(backup_dir)
        FileUtils.mkdir_p(backup_dir)
      end

      it "returns early without creating backups" do
        result = described_class.perform_now
        expect(result).to be_nil
        expect(Dir.glob(backup_dir.join("*.sql.bz2"))).to be_empty
      end
    end

    context "when scheduled backups are enabled" do
      before do
        allow(RakeTaskRunner).to receive(:invoke) do |task_name|
          next unless task_name == "db:dump"

          timestamp = Time.current.strftime("%Y%m%d%H%M")
          File.write(backup_dir.join("#{timestamp}_test.sql.bz2"), "backup")
        end
      end

      it "creates a timestamped backup file" do
        described_class.perform_now

        expect(Dir.glob(backup_dir.join("*_test.sql.bz2")).count).to eq(1)
      end

      it "returns job statistics" do
        result = described_class.perform_now

        expect(result).to include(:started_at, :success, :finished_at, :duration)
        expect(result[:success]).to be true
      end
    end

    context "when rake task calls exit 1" do
      before do
        allow(RakeTaskRunner).to receive(:invoke).and_raise(SystemExit.new(1))
      end

      it "converts SystemExit into StandardError" do
        expect { described_class.perform_now }.to raise_error(StandardError, /exited with status 1/)
      end
    end
  end

  describe "job enqueueing" do
    it "enqueues on the low_priority queue" do
      expect { described_class.perform_later }.to have_enqueued_job.on_queue("low_priority")
    end
  end
end
