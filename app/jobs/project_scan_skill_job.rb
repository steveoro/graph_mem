# frozen_string_literal: true

# Processes one depth of a human-guided project scan skill and pauses.
# The dashboard continues the scan by enqueuing another job.
class ProjectScanSkillJob < ApplicationJob
  queue_as :default

  def perform(operation_id)
    operation = OperationProgress.find_by(operation_id: operation_id)
    return unless operation
    return unless operation.status.in?(%w[pending paused])

    ProjectScanSkill.process!(operation)
  end
end
