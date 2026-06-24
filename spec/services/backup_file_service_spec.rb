# frozen_string_literal: true

require "rails_helper"

RSpec.describe BackupFileService do
  let(:backup_dir) { Rails.root.join("tmp", "test_backup_service") }
  let(:service) { described_class.new }

  before do
    FileUtils.mkdir_p(backup_dir)
    AppSettings.backup_folder_path = backup_dir.to_s
  end

  after do
    FileUtils.rm_rf(backup_dir)
    AppSettings.clear_cache
  end

  describe "#list" do
    it "returns managed backups sorted newest first by mtime" do
      older = backup_dir.join("202601011200_test.sql.bz2")
      newer = backup_dir.join("202601021200_test.sql.bz2")
      File.write(older, "old")
      sleep 0.01
      File.write(newer, "new")

      filenames = service.list.map { |entry| entry[:filename] }
      expect(filenames).to eq([ newer.basename.to_s, older.basename.to_s ])
    end

    it "includes legacy GraphMem backup filenames" do
      legacy = backup_dir.join("graph_mem-20260303.sql.bz2")
      File.write(legacy, "legacy-backup")

      filenames = service.list.map { |entry| entry[:filename] }
      expect(filenames).to include(legacy.basename.to_s)
    end

    it "excludes hidden and non-backup files" do
      File.write(backup_dir.join("graph_mem-20260303.sql.bz2"), "ok")
      File.write(backup_dir.join(".hidden.sql.bz2"), "hidden")
      File.write(backup_dir.join("notes.txt"), "not a backup")

      filenames = service.list.map { |entry| entry[:filename] }
      expect(filenames).to eq([ "graph_mem-20260303.sql.bz2" ])
    end
  end

  describe "#delete!" do
    it "deletes a managed backup file" do
      file = backup_dir.join("202601011200_test.sql.bz2")
      File.write(file, "backup")

      service.delete!(file.basename.to_s)

      expect(file).not_to exist
    end

    it "deletes a legacy backup file" do
      file = backup_dir.join("graph_mem-wks0-20260403.sql.bz2")
      File.write(file, "backup")

      service.delete!(file.basename.to_s)

      expect(file).not_to exist
    end

    it "rejects path traversal filenames" do
      expect { service.delete!("../secrets.sql.bz2") }.to raise_error(BackupFileService::Error, /Invalid backup filename/)
    end

    it "rejects non-backup extensions" do
      expect { service.delete!("backup.sql") }.to raise_error(BackupFileService::Error, /Invalid backup filename/)
    end
  end

  describe "#resolve_safe_path!" do
    it "rejects files outside the backup directory" do
      outside = Rails.root.join("tmp", "outside_test.sql.bz2")
      File.write(outside, "x")

      expect { service.delete!(outside.basename.to_s) }.to raise_error(BackupFileService::Error, /Backup file not found/)
    ensure
      File.delete(outside) if File.exist?(outside)
    end
  end
end
