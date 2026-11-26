# frozen_string_literal: true

# Background job for Projects › Exports: runs the export, reports progress through its
# OperationProgress row (OperationProgressChannel), and saves the result to a temp file that
# Projects::ExportsController#download serves. The format ("sql", a graph_mem-sql script written by
# SqlExport::Writer, or "json", the GraphMem JSON tree) is read from the row's details; a row without one
# is a JSON export.
#
#   ExportJob.perform_later(export_id, [ project.id ])                    # as the row's details say
#   ExportJob.perform_later(export_id, [ project.id ], format: "sql")     # a run without a row
class ExportJob < ApplicationJob
  queue_as :default

  TEMP_DIR = Rails.root.join("tmp", "exports")
  FORMATS = %w[sql json].freeze
  DEFAULT_FORMAT = "json"

  # @param export_id [String] the OperationProgress operation id (a UUID)
  # @param entity_ids [Array<Integer>] the roots
  # @param format [String, nil] "sql" or "json"; nil reads the row's details, then falls back to JSON
  def perform(export_id, entity_ids, format: nil)
    ensure_temp_dir
    operation = start_operation(export_id)
    broadcast_operation(operation)

    begin
      given = format
      format = self.class.format_of(operation, given)
      remember_format(operation, format) if given
      filepath = self.class.download_path(export_id, format: format)
      current_count = format == "sql" ? write_sql(operation, entity_ids, filepath) : write_json(operation, entity_ids, filepath)

      operation.complete!(current: current_count, message: "Export complete")
      broadcast_operation(operation)

    rescue StandardError => e
      Rails.logger.error "ExportJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      FileUtils.rm_f(Dir.glob(self.class.download_path(export_id, format: "*")))
      operation&.fail!(e)
      broadcast_operation(operation) if operation
    end
  end

  # @param operation [OperationProgress, nil] an export row
  # @param requested [String, nil] a format given to the job
  # @return [String] "sql" or "json"
  # @raise [ArgumentError] for any other value
  def self.format_of(operation, requested = nil)
    format = (requested.presence || operation&.details&.dig("format").presence || DEFAULT_FORMAT).to_s
    raise ArgumentError, "unknown export format '#{format}' (use #{FORMATS.join(' or ')})" unless FORMATS.include?(format)

    format
  end

  private

  # A format given to the job (not read from the row) is written to the row, so the download finds the file.
  def remember_format(operation, format)
    return if operation.details&.dig("format") == format

    operation.update!(details: (operation.details || {}).merge("format" => format))
  end

  # Projects › Exports writes the pending row before queueing, so its progress page exists at once;
  # a job queued without one (a console run) starts it.
  # The total is a placeholder until the format's writer knows its steps.
  def start_operation(export_id)
    operation = OperationProgress.find_by(operation_id: export_id, operation_type: "export")
    return OperationProgress.start!(operation_type: "export", operation_id: export_id, total_count: 1, message: "Starting export") unless operation

    operation.update!(status: "running", total_count: 1, started_at: Time.current, message: "Starting export")
    operation
  end

  # The JSON tree, one progress step per node.
  # @return [Integer] the steps done
  def write_json(operation, entity_ids, filepath)
    total_count = count_total_nodes(entity_ids)
    operation.update_progress!(current: 0, total: total_count, message: "Starting export")
    broadcast_operation(operation)

    current_count = 0
    progress_callback = lambda do |node_name|
      current_count += 1
      operation.update_progress!(current: current_count, total: total_count, message: "Exporting: #{node_name}")
      broadcast_operation(operation)
    end

    File.write(filepath, ExportStrategy.new.export_json_with_progress(entity_ids, progress_callback))
    current_count
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

  def count_total_nodes(entity_ids)
    count = 0

    entities = MemoryEntity.where(id: entity_ids)
    entities.each do |entity|
      count += count_subtree(entity.id, Set.new, nested: false)
    end

    [ count, 1 ].max  # At least 1 to avoid division by zero
  end

  def count_subtree(entity_id, visited, nested:)
    return 0 if visited.include?(entity_id)

    visited.add(entity_id)
    count = 1  # This entity

    # Nested Projects are export boundaries: count the shallow node only.
    entity = MemoryEntity.find_by(id: entity_id)
    return count if nested && entity&.entity_type == ExportStrategy::PROJECT_ENTITY_TYPE

    # Count children
    child_ids = MemoryRelation
      .where(to_entity_id: entity_id, relation_type: ExportStrategy::PARENT_TO_CHILD_RELATION_TYPES)
      .pluck(:from_entity_id)

    child_ids.each do |child_id|
      count += count_subtree(child_id, visited.dup, nested: true)
    end

    # Count other related entities
    related_ids = MemoryRelation
      .where(from_entity_id: entity_id)
      .where.not(relation_type: ExportStrategy::PARENT_TO_CHILD_RELATION_TYPES)
      .pluck(:to_entity_id)

    related_ids.each do |related_id|
      count += count_subtree(related_id, visited.dup, nested: true)
    end

    count
  end

  def broadcast_operation(operation)
    OperationProgressBroadcaster.call(operation)
  end

  # @param export_id [String] a known export's UUID
  # @param format [String] "sql" or "json"
  # @return [String] where the export's file is (or will be)
  def self.download_path(export_id, format: DEFAULT_FORMAT)
    File.join(TEMP_DIR, "export_#{export_id}.#{format}")
  end

  # @return [Boolean] whether the export's file in that format is still there
  def self.export_exists?(export_id, format: DEFAULT_FORMAT)
    File.exist?(download_path(export_id, format: format))
  end

  # Class method to cleanup old export files
  def self.cleanup_old_exports(max_age: 1.hour)
    return unless Dir.exist?(TEMP_DIR)

    cutoff_time = Time.current - max_age

    Dir.glob(File.join(TEMP_DIR, "export_*.{#{FORMATS.join(",")}}")).each do |file|
      FileUtils.rm_f(file) if File.mtime(file) < cutoff_time
    end
  end
end
