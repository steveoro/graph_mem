# frozen_string_literal: true

require "rake"

# Lists, validates, deletes, and restores database backup files for the operator UI.
class BackupFileService
  class Error < StandardError; end

  SAFE_BACKUP_FILENAME = /\A[^\/\\]+\.sql\.bz2\z/

  def list
    backup_dir = resolve_backup_dir
    return [] unless backup_dir.exist?

    find_all_backups(backup_dir).map { |path| file_entry(path) }
  end

  def delete!(filename)
    path = resolve_safe_path!(filename)
    File.delete(path)
    { filename: path.basename.to_s, deleted: true }
  end

  def restore!(filename)
    path = resolve_safe_path!(filename)

    capture_rake_output do
      with_restore_file(path) { RakeTaskRunner.invoke("db:restore") }
    end

    { filename: path.basename.to_s, restored: true }
  rescue SystemExit => e
    raise Error, "Restore failed with exit status #{e.status}"
  end

  def run_backup!
    capture_rake_output { RakeTaskRunner.invoke("db:dump") }

    { success: true }
  rescue SystemExit => e
    raise Error, "Backup failed with exit status #{e.status}"
  end

  private

  def resolve_backup_dir
    backup_path = AppSettings.backup_folder_path.presence || "db/backup"

    if Pathname.new(backup_path).absolute?
      Pathname.new(backup_path)
    else
      Rails.root.join(backup_path)
    end
  end

  # All safe top-level .sql.bz2 files in the backup folder (includes legacy names).
  def find_all_backups(backup_dir)
    Dir.glob(backup_dir.join("*.sql.bz2"))
       .map { |f| Pathname.new(f) }
       .select { |path| safe_backup_filename?(path.basename.to_s) }
       .sort_by { |path| File.mtime(path) }
       .reverse
  end

  def resolve_safe_path!(filename)
    raise Error, "Filename is required" if filename.blank?
    raise Error, "Invalid backup filename" unless safe_backup_filename?(filename)

    backup_dir = resolve_backup_dir
    path = backup_dir.join(filename).cleanpath
    raise Error, "Backup file not found" unless path.exist?
    raise Error, "Invalid backup path" unless path.to_s.start_with?(backup_dir.to_s)

    path
  end

  def safe_backup_filename?(filename)
    return false if filename.blank?
    return false if filename.start_with?(".")
    return false if filename.include?("..")

    filename.match?(SAFE_BACKUP_FILENAME)
  end

  def file_entry(path)
    {
      filename: path.basename.to_s,
      size_mb: (File.size(path) / 1024.0 / 1024.0).round(2),
      modified_at: File.mtime(path)
    }
  end

  def with_restore_file(path)
    previous = ENV["FILE"]
    ENV["FILE"] = path.to_s
    yield
  ensure
    if previous.nil?
      ENV.delete("FILE")
    else
      ENV["FILE"] = previous
    end
  end

  def capture_rake_output
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    yield

    { stdout: $stdout.string, stderr: $stderr.string }
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end
end
