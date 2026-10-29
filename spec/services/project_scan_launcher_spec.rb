# frozen_string_literal: true

require "rails_helper"

# UI-6 P3: the one place the web forms start or steer a scan, enqueuing exactly what the two
# Maintenance hub controllers did.
RSpec.describe ProjectScanLauncher do
  it "enqueues a normal scan through ProjectScanJob.enqueue with the resolved path" do
    with_scan_project do |project|
      allow(ProjectScanJob).to receive(:enqueue).and_call_original

      result = described_class.call(project_root: "#{project}/", project_name: "Alpha Service", aliases: "alpha", mode: "Rescan",
                                    dry_run: "1", file_globs: "README*\npackage.json")

      expect(result).to have_attributes(ok?: true, path: project, warnings: "")
      expect(ProjectScanJob).to have_received(:enqueue).with(
        scan_id: result.operation_id, project_root: project, project_name: "Alpha Service", aliases: "alpha", mode: "rescan",
        dry_run: true, file_globs: %w[README* package.json]
      )
    end
  end

  it "writes a guided scan's pending operation (all steps by default) and queues ProjectScanSkillJob" do
    with_scan_project do |project|
      result = nil
      expect { result = described_class.call(project_root: project, guided: "1") }.to have_enqueued_job(ProjectScanSkillJob)

      operation = OperationProgress.find_by!(operation_id: result.operation_id)
      expect(operation).to have_attributes(operation_type: "project_scan_skill", status: "pending", phase: "birds_eye",
                                           total_count: ProjectScanSkill::DEPTH_ORDER.size)
      expect(operation.details).to include("project_root" => project, "depths" => ProjectScanSkill::DEPTH_ORDER, "dry_run" => false)
    end
  end

  it "refuses a path ScanRootPolicy refuses, before anything is written or queued" do
    with_scan_home do |home|
      result = nil
      expect { result = described_class.call(project_root: File.join(home, "Projects", "missing")) }.not_to have_enqueued_job

      expect(result.ok?).to be(false)
      expect(result.error).to include("was not found")
      expect(OperationProgress.count).to eq(0)
    end
  end

  it "continues a paused guided scan and refuses a finished one" do
    operation = OperationProgress.create!(operation_type: "project_scan_skill", operation_id: SecureRandom.uuid, status: "paused",
                                          details: { "depths" => %w[birds_eye] })

    expect(described_class.steer(operation, "continue")).to eq([ true, "Guided project scan resumed. Scan ID: #{operation.operation_id}" ])
    operation.update!(status: "completed")
    expect(described_class.steer(operation, "continue").first).to be(false)
    expect(described_class.steer(operation, "bogus")).to eq([ false, "Unknown skill action." ])
  end
end
