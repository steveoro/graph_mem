# frozen_string_literal: true

# Background job for running exports with progress updates via ActionCable
#
# This job:
# - Runs the export in the background
# - Broadcasts progress updates to the ExportProgressChannel
# - Saves the export result to a temp file
# - Notifies completion with download path
class ExportJob < ApplicationJob
  queue_as :default

  TEMP_DIR = Rails.root.join("tmp", "exports")

  def perform(export_id, entity_ids)
    ensure_temp_dir

    # Count total nodes first
    strategy = ExportStrategy.new
    total_count = count_total_nodes(entity_ids)

    broadcast_progress(export_id, 0, total_count, "Starting export...")

    begin
      # Export with progress callback
      current_count = 0
      progress_callback = lambda do |node_name|
        current_count += 1
        broadcast_progress(export_id, current_count, total_count, "Exporting: #{node_name}")
      end

      json_content = strategy.export_json_with_progress(entity_ids, progress_callback)

      # Save to temp file
      filename = "export_#{export_id}.json"
      filepath = File.join(TEMP_DIR, filename)
      File.write(filepath, json_content)

      broadcast_complete(export_id, {
        success: true,
        download_path: "/data_exchange/download_export?export_id=#{export_id}",
        message: "Export complete! #{current_count} nodes exported."
      })

    rescue StandardError => e
      Rails.logger.error "ExportJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      broadcast_error(export_id, "Export failed: #{e.message}")
    end
  end

  private

  def ensure_temp_dir
    FileUtils.mkdir_p(TEMP_DIR)
  end

  def count_total_nodes(entity_ids)
    # Count all entities that will be exported (rough estimate)
    count = 0

    entities = MemoryEntity.where(id: entity_ids)
    entities.each do |entity|
      count += count_subtree(entity.id, Set.new)
    end

    [ count, 1 ].max  # At least 1 to avoid division by zero
  end

  def count_subtree(entity_id, visited)
    return 0 if visited.include?(entity_id)

    visited.add(entity_id)
    count = 1  # This entity

    # Count children
    child_ids = MemoryRelation
      .where(to_entity_id: entity_id, relation_type: %w[part_of depends_on])
      .pluck(:from_entity_id)

    child_ids.each do |child_id|
      count += count_subtree(child_id, visited)
    end

    # Count other related entities
    related_ids = MemoryRelation
      .where(from_entity_id: entity_id)
      .where.not(relation_type: %w[part_of depends_on])
      .pluck(:to_entity_id)

    related_ids.each do |related_id|
      count += count_subtree(related_id, visited)
    end

    count
  end

  def broadcast_progress(export_id, current, total, message)
    ExportProgressChannel.broadcast_progress(export_id, {
      current: current,
      total: total,
      message: message
    })
  end

  def broadcast_complete(export_id, result)
    ExportProgressChannel.broadcast_complete(export_id, result)
  end

  def broadcast_error(export_id, error)
    ExportProgressChannel.broadcast_error(export_id, error)
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
