# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanJob, type: :job do
  around do |example|
    with_scan_project("job_test") do |project|
      @project_root = project
      example.run
    end
  end

  before do
    File.write(File.join(@project_root, "README.md"), "# JobTestProject")

    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true,
      text: {
        project: {
          name: "JobTestProject",
          aliases: [],
          description: "A job test project"
        },
        architecture: []
      }.to_json
    )
  end

  it "creates an OperationProgress record and runs the scanner" do
    expect {
      described_class.perform_now(
        SecureRandom.uuid,
        @project_root,
        "JobTestProject",
        nil,
        "initial",
        false,
        []
      )
    }.to change { OperationProgress.where(operation_type: "project_scan").count }.by(1)

    operation = OperationProgress.find_by(operation_type: "project_scan")
    expect(operation.status).to eq("completed")
  end

  it "broadcasts progress snapshots while running and on completion" do
    allow(OperationProgressBroadcaster).to receive(:call)

    described_class.perform_now(
      SecureRandom.uuid,
      @project_root,
      "JobTestProject",
      nil,
      "initial",
      false,
      []
    )

    expect(OperationProgressBroadcaster).to have_received(:call).at_least(:once)
  end

  it "fails the operation with the policy message when the folder left the filter after enqueue" do
    scan_id = SecureRandom.uuid
    write_scan_subfolders_raw("work")

    result = described_class.perform_now(scan_id, @project_root, "JobTestProject", nil, "initial", false, [])

    expect(result).to include(success: false, code: :outside_filter)
    expect(OperationProgress.find_by(operation_id: scan_id)).to have_attributes(status: "failed")
    expect(OperationProgress.find_by(operation_id: scan_id).error_message).to include("outside the scan filter")
    expect(SummaryGenerationClient).not_to have_received(:generate)
  end
end
