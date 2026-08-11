# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe ProjectScanSkillJob, type: :job do
  it "processes the operation and broadcasts" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "README.md"), "# Test\n")
      operation = OperationProgress.create!(
        operation_type: "project_scan_skill",
        operation_id: SecureRandom.uuid,
        status: "pending",
        total_count: ProjectScanSkill::DEPTH_ORDER.size,
        current_count: 0,
        percentage: 0,
        phase: "birds_eye",
        message: "Queued",
        details: { project_root: root, depths: ProjectScanSkill::DEPTH_ORDER, current_depth_index: 0, dry_run: false }
      )

      expect(OperationProgressBroadcaster).to receive(:call).at_least(:once)

      described_class.perform_now(operation.operation_id)

      expect(operation.reload.status).to eq("paused")
    end
  end

  it "does nothing if the operation is completed" do
    operation = OperationProgress.create!(
      operation_type: "project_scan_skill",
      operation_id: SecureRandom.uuid,
      status: "completed",
      total_count: ProjectScanSkill::DEPTH_ORDER.size,
      current_count: ProjectScanSkill::DEPTH_ORDER.size,
      percentage: 100.0,
      phase: "tests_and_docs",
      message: "Done",
      details: { project_root: Dir.tmpdir, depths: ProjectScanSkill::DEPTH_ORDER, current_depth_index: ProjectScanSkill::DEPTH_ORDER.size, dry_run: false }
    )

    expect(OperationProgressBroadcaster).not_to receive(:call)

    described_class.perform_now(operation.operation_id)

    expect(operation.reload.status).to eq("completed")
  end
end
