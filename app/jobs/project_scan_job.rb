# frozen_string_literal: true

# Background job that runs a project source scan and reports progress.
class ProjectScanJob < ApplicationJob
  queue_as :default

  def perform(scan_id, project_root, project_name, aliases, mode, dry_run, file_globs)
    operation = OperationProgress.find_by(operation_id: scan_id)
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
      operation.update!(status: "running", started_at: Time.current)
      OperationProgressBroadcaster.call(operation)
    end

    scanner = ProjectScanner.new(
      project_root: project_root,
      project_name: project_name,
      aliases: aliases,
      mode: mode,
      dry_run: dry_run,
      file_globs: file_globs,
      operation_progress: operation
    )

    result = scanner.call
    if result.success
      operation.reload
      operation.complete!(
        message: "Project scan completed",
        counters: result.to_h.slice(:entities_created, :entities_updated, :observations_created, :observations_obsoleted, :relations_created, :dismissed_compaction_items).compact,
        details: operation.details&.merge(
          fallback: result.fallback,
          fallback_reason: result.fallback_reason,
          project_entity_id: result.project_entity&.id,
          project_entity_name: result.project_entity&.name
        )&.compact
      )
      OperationProgressBroadcaster.call(operation)
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
