# frozen_string_literal: true

# Background job that runs a project source scan and reports progress.
class ProjectScanJob < ApplicationJob
  queue_as :default

  def perform(scan_id, project_root, project_name, aliases, mode, dry_run, file_globs)
    operation = OperationProgress.find_by(operation_id: scan_id)

    if operation
      unless operation.status.in?(%w[pending paused running])
        # A completed/failed operation with this ID should not be overwritten.
        # Treat it as a fresh run by creating a new OperationProgress.
        operation = nil
      end
    end

    operation ||= OperationProgress.start!(
      operation_type: "project_scan",
      operation_id: scan_id,
      total_count: 6,
      message: "Starting project scan",
      details: {
        project_root: project_root,
        project_name: project_name,
        mode: mode,
        dry_run: dry_run
      }
    )

    unless operation.status == "running"
      operation.resume!(message: "Resuming project scan") if operation.status == "paused"
      operation.update!(status: "running", started_at: Time.current) unless operation.status == "running"
      OperationProgressBroadcaster.call(operation)
    end

    scanner = ProjectScanner.new(
      project_root: project_root,
      project_name: project_name,
      aliases: aliases,
      mode: mode,
      dry_run: dry_run,
      file_globs: file_globs,
      operation_progress: operation,
      scan_id: scan_id
    )

    result = scanner.call
    operation.reload

    if result.success
      if result.status == "paused"
        operation.pause!(message: result.message || "Project scan validation paused for next batch")
        OperationProgressBroadcaster.call(operation)
      else
        operation.complete!(
          message: "Project scan completed",
          counters: result.to_h.slice(
            :entities_created, :entities_updated, :observations_created, :observations_obsoleted,
            :observations_moved, :relations_created, :relations_deleted, :entities_reparented,
            :dismissed_compaction_items
          ).compact,
          details: operation.details&.merge(
            fallback: result.fallback,
            fallback_reason: result.fallback_reason,
            project_entity_id: result.project_entity&.id,
            project_entity_name: result.project_entity&.name
          )&.compact
        )
        OperationProgressBroadcaster.call(operation)
      end
    else
      operation.fail!(result.errors.join("; "))
      OperationProgressBroadcaster.call(operation)
    end

    result.to_h.merge(scan_id: scan_id, operation_id: operation.operation_id)
  rescue StandardError => e
    Rails.logger.error "ProjectScanJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    operation&.fail!(e)
    OperationProgressBroadcaster.call(operation) if operation
    raise
  end
end
