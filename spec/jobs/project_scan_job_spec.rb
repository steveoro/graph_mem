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

  describe ".enqueue" do
    let(:args) do
      { project_root: @project_root, project_name: nil, aliases: nil, mode: "initial", dry_run: true, file_globs: [] }
    end

    it "refuses a second call with a queued scan's id (a concurrent call) and queues one job" do
      scan_id = SecureRandom.uuid
      first = described_class.enqueue(scan_id: scan_id, **args)

      expect {
        expect { described_class.enqueue(scan_id: scan_id, **args) }
          .to raise_error(described_class::ScanIdNotResumable, /is pending, not paused/)
      }.not_to have_enqueued_job(described_class)
      expect(first).to have_attributes(status: "pending", phase: "queued")
      expect(OperationProgress.where(operation_id: scan_id).count).to eq(1)
    end

    it "refuses a running scan's id" do
      scan_id = SecureRandom.uuid
      OperationProgress.start!(operation_type: "project_scan", operation_id: scan_id, total_count: 6)

      expect { described_class.enqueue(scan_id: scan_id, **args) }
        .to raise_error(described_class::ScanIdNotResumable, /is running, not paused/)
    end

    it "resumes a paused scan by claiming its row, so a second resume is refused" do
      scan_id = SecureRandom.uuid
      paused = OperationProgress.start!(operation_type: "project_scan", operation_id: scan_id, total_count: 6)
      paused.pause!(message: "Paused for the next batch")

      result = nil
      expect { result = described_class.enqueue(scan_id: scan_id, **args) }.to have_enqueued_job(described_class)
      expect(result).to be_nil
      expect(paused.reload).to have_attributes(status: "pending", phase: "queued")

      expect { described_class.enqueue(scan_id: scan_id, **args) }
        .to raise_error(described_class::ScanIdNotResumable, /is pending, not paused/)
    end

    it "puts a claimed scan back to paused when enqueuing fails" do
      scan_id = SecureRandom.uuid
      paused = OperationProgress.start!(operation_type: "project_scan", operation_id: scan_id, total_count: 6)
      paused.pause!
      allow(described_class).to receive(:perform_later).and_raise(StandardError, "queue down")

      expect { described_class.enqueue(scan_id: scan_id, **args) }.to raise_error(StandardError, "queue down")
      expect(paused.reload.status).to eq("paused")
    end

    it "refuses a finished scan's id without enqueuing anything" do
      scan_id = SecureRandom.uuid
      OperationProgress.create!(operation_type: "project_scan", operation_id: scan_id, status: "completed",
                                total_count: 6, current_count: 6, percentage: 100)

      expect {
        expect { described_class.enqueue(scan_id: scan_id, **args) }
          .to raise_error(described_class::ScanIdNotResumable, /is completed, not paused; omit scan_id/)
      }.not_to have_enqueued_job(described_class)
    end

    it "refuses another operation's id" do
      export = OperationProgress.start!(operation_type: "export", total_count: 1)

      expect { described_class.enqueue(scan_id: export.operation_id, **args) }
        .to raise_error(described_class::ScanIdNotResumable, /belongs to another operation/)
    end
  end
end
