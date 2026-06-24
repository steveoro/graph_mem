# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "db rake tasks", type: :task do
  let(:backup_dir) { Rails.root.join("tmp", "test_db_utils_backups") }

  before do
    Rails.application.load_tasks
    FileUtils.mkdir_p(backup_dir)
    AppSettings.backup_folder_path = backup_dir.to_s
    AppSettings.backup_keep_max = 2

    allow(Kernel).to receive(:system).and_wrap_original do |method, cmd, *rest|
      if cmd.to_s.include?("mariadb-dump")
        backup_file = cmd[/>\s+(\S+)/, 1]
        File.write(backup_file, "fake-backup") if backup_file.present?
        true
      else
        method.call(cmd, *rest)
      end
    end
  end

  after do
    FileUtils.rm_rf(backup_dir)
    AppSettings.clear_cache
    Rake::Task["db:dump"].reenable if Rake::Task.task_defined?("db:dump")
    Rake::Task["db:list_backups"].reenable if Rake::Task.task_defined?("db:list_backups")
  end

  describe "db:dump" do
    it "creates a timestamped backup file for the current environment" do
      Rake::Task["db:dump"].invoke

      backups = Dir.glob(backup_dir.join("*_#{Rails.env}.sql.bz2"))
      expect(backups.size).to eq(1)
      expect(File.size(backups.first)).to be > 0
    end

    it "prunes old backups beyond backup_keep_max" do
      3.times do |i|
        File.write(backup_dir.join("2026010#{i}1200_#{Rails.env}.sql.bz2"), "backup-#{i}")
      end

      Rake::Task["db:dump"].invoke

      backups = Dir.glob(backup_dir.join("*_#{Rails.env}.sql.bz2"))
      expect(backups.size).to eq(2)
    end
  end

  describe "db:list_backups" do
    it "lists all backup files in the folder" do
      File.write(backup_dir.join("202601011200_#{Rails.env}.sql.bz2"), "managed")
      File.write(backup_dir.join("graph_mem-20260303.sql.bz2"), "legacy")

      expect { Rake::Task["db:list_backups"].invoke }.to output(/graph_mem-20260303\.sql\.bz2/).to_stdout
    end
  end
end
