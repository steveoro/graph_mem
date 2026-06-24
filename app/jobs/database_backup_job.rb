# frozen_string_literal: true

require "rake"

# Background job for automated database backups.
class DatabaseBackupJob < ApplicationJob
  queue_as :low_priority

  def perform
    return unless AppSettings.scheduled_backups_enabled?

    stats = {
      started_at: Time.current,
      success: false,
      backup_file: nil,
      error: nil
    }

    Rails.logger.info("[DatabaseBackupJob] Starting scheduled database backup")

    begin
      backup_result = capture_rake_output { RakeTaskRunner.invoke("db:dump") }

      stats[:success] = true
      stats[:output] = backup_result

      Rails.logger.info("[DatabaseBackupJob] Database backup completed successfully")
    rescue SystemExit => e
      stats[:success] = false
      stats[:error] = "Rake task exited with status #{e.status}"
      Rails.logger.error("[DatabaseBackupJob] #{stats[:error]}")
      raise StandardError, stats[:error]
    rescue StandardError => e
      stats[:success] = false
      stats[:error] = e.message
      Rails.logger.error("[DatabaseBackupJob] #{e.class.name}: #{e.message}")
      raise
    ensure
      stats[:finished_at] = Time.current
      stats[:duration] = stats[:finished_at] - stats[:started_at]
      Rails.logger.info(
        "[DatabaseBackupJob] Finished in #{stats[:duration].round(2)}s: success=#{stats[:success]}"
      )
    end

    stats
  end

  private

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
