# frozen_string_literal: true

# Background job for Projects › Exports: writes a graph_mem-sql script for the roots (SqlExport::Writer),
# reports progress through its OperationProgress row (OperationProgressChannel), and saves it to a temp
# file that Projects::ExportsController#download serves.
#
# The JSON export was retired in 1.94.0: a row whose details say "json" fails with that message. A row
# without a format (a run without a row starts one) is an SQL export, and the job writes the format to it.
#
#   ExportJob.perform_later(export_id, [ project.id ])
class ExportJob < ApplicationJob
  queue_as :default

  TEMP_DIR = Rails.root.join("tmp", "exports")
  FORMAT = "sql"
  # The hourly cleanup also removes the export_<uuid>.json files the retired JSON export left.
  CLEANED_EXTENSIONS = [ FORMAT, "json" ].freeze
  RETIRED_JSON = "The JSON export was retired in 1.94.0: export the graph_mem-sql script instead"

  # @param export_id [String] the OperationProgress operation id (a UUID)
  # @param entity_ids [Array<Integer>] the roots
  def perform(export_id, entity_ids)
    ensure_temp_dir
    operation = start_operation(export_id)
    broadcast_operation(operation)

    begin
      check_format!(operation)
      current_count = write_sql(operation, entity_ids, self.class.download_path(export_id))

      operation.complete!(current: current_count, message: "Export complete")
      broadcast_operation(operation)

    rescue StandardError => e
      Rails.logger.error "ExportJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      FileUtils.rm_f(self.class.download_path(export_id))
      operation&.fail!(e)
      broadcast_operation(operation) if operation
    end
  end

  private

  # A row that names no format is written as an SQL export, so the download finds the file.
  # @raise [ArgumentError] for "json" (retired) or any other format
  def check_format!(operation)
    format = operation.details&.dig("format").presence
    raise ArgumentError, RETIRED_JSON if format == "json"
    raise ArgumentError, "unknown export format '#{format}' (use #{FORMAT})" unless format.nil? || format == FORMAT
    return if format

    operation.update!(details: (operation.details || {}).merge("format" => FORMAT))
  end

  # Projects › Exports writes the pending row before queueing, so its progress page exists at once;
  # a job queued without one (a console run) starts it.
  # The total is a placeholder until the writer knows its steps.
  def start_operation(export_id)
    operation = OperationProgress.find_by(operation_id: export_id, operation_type: "export")
    return OperationProgress.start!(operation_type: "export", operation_id: export_id, total_count: 1, message: "Starting export") unless operation

    operation.update!(status: "running", total_count: 1, started_at: Time.current, message: "Starting export")
    operation
  end

  # The graph_mem-sql script, one progress step per staging table.
  # @return [Integer] the steps done
  def write_sql(operation, entity_ids, filepath)
    writer = SqlExport::Writer.new(entity_ids)
    total = SqlExport::Template::COLUMNS.size
    operation.update_progress!(current: 0, total: total, message: "Starting export")
    broadcast_operation(operation)

    current_count = 0
    writer.write_file(filepath) do |table, rows|
      current_count += 1
      operation.update_progress!(current: current_count, total: total, message: "Exporting: #{table} (#{rows} rows)")
      broadcast_operation(operation)
    end
    current_count
  end

  def ensure_temp_dir
    FileUtils.mkdir_p(TEMP_DIR)
  end

  def broadcast_operation(operation)
    OperationProgressBroadcaster.call(operation)
  end

  # @param export_id [String] a known export's UUID
  # @return [String] where the export's script is (or will be)
  def self.download_path(export_id)
    File.join(TEMP_DIR, "export_#{export_id}.#{FORMAT}")
  end

  # @param export_id [String] a known export's UUID
  # @return [Boolean] whether the export's script is still there
  def self.export_exists?(export_id)
    File.exist?(download_path(export_id))
  end

  # Removes export files older than max_age (scripts, and JSON files the retired JSON export left).
  # @param max_age [ActiveSupport::Duration]
  def self.cleanup_old_exports(max_age: 1.hour)
    return unless Dir.exist?(TEMP_DIR)

    cutoff_time = Time.current - max_age

    Dir.glob(File.join(TEMP_DIR, "export_*.{#{CLEANED_EXTENSIONS.join(",")}}")).each do |file|
      FileUtils.rm_f(file) if File.mtime(file) < cutoff_time
    end
  end
end
