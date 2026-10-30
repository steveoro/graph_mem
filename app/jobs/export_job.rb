# frozen_string_literal: true

# Background job for Projects › Exports: runs the export, reports progress through its
# OperationProgress row (OperationProgressChannel), and saves the result to a temp file that
# Projects::ExportsController#download serves.
class ExportJob < ApplicationJob
  queue_as :default

  TEMP_DIR = Rails.root.join("tmp", "exports")

  def perform(export_id, entity_ids)
    ensure_temp_dir

    # Count total nodes first
    strategy = ExportStrategy.new
    total_count = count_total_nodes(entity_ids)
    operation = start_operation(export_id, total_count)
    broadcast_operation(operation)

    begin
      # Export with progress callback
      current_count = 0
      progress_callback = lambda do |node_name|
        current_count += 1
        operation.update_progress!(current: current_count, total: total_count, message: "Exporting: #{node_name}")
        broadcast_operation(operation)
      end

      json_content = strategy.export_json_with_progress(entity_ids, progress_callback)

      # Save to temp file
      filename = "export_#{export_id}.json"
      filepath = File.join(TEMP_DIR, filename)
      File.write(filepath, json_content)

      operation.complete!(current: current_count, message: "Export complete")
      broadcast_operation(operation)

    rescue StandardError => e
      Rails.logger.error "ExportJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      operation&.fail!(e)
      broadcast_operation(operation) if operation
    end
  end

  private

  # Projects › Exports writes the pending row before queueing, so its progress page exists at once;
  # a job queued without one (a console run) starts it.
  def start_operation(export_id, total_count)
    operation = OperationProgress.find_by(operation_id: export_id, operation_type: "export")
    return OperationProgress.start!(operation_type: "export", operation_id: export_id, total_count: total_count, message: "Starting export") unless operation

    operation.update!(status: "running", total_count: total_count, started_at: Time.current, message: "Starting export")
    operation
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

  # Class method to get the download path for an export
  def self.download_path(export_id)
    File.join(TEMP_DIR, "export_#{export_id}.json")
  end

  # Class method to check if export file exists
  def self.export_exists?(export_id)
    File.exist?(download_path(export_id))
  end

  # Class method to cleanup old export files
  def self.cleanup_old_exports(max_age: 1.hour)
    return unless Dir.exist?(TEMP_DIR)

    cutoff_time = Time.current - max_age

    Dir.glob(File.join(TEMP_DIR, "export_*.json")).each do |file|
      FileUtils.rm_f(file) if File.mtime(file) < cutoff_time
    end
  end
end
