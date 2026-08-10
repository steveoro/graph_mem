# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanJob, type: :job do
  around do |example|
    Dir.mktmpdir("project_scan_job_test") do |dir|
      @project_root = dir
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
end
