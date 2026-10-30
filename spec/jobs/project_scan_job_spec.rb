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

  describe "scan parts and resume (F-3)" do
    let(:scan_id) { SecureRandom.uuid }
    let(:architecture) do
      [ { entity: { name: "SynthWidget", type: "Component" }, observations: [ "SynthWidget renders gadgets." ],
          relations: [ { to: "Gadget Project", type: "part_of", confidence: 0.9 } ] } ]
    end

    before do
      allow(SummarizationConfig).to receive(:llm_usable?).and_return(true)
      allow(SummaryGenerationClient).to receive(:generate).and_return(
        ok: true, done_reason: "stop", prompt_tokens: 900, text: { project: { name: "Gadget Project" }, architecture: architecture }.to_json
      )
    end

    def run_scan
      described_class.perform_now(scan_id, @project_root, "Gadget Project", nil, "rescan", false, [])
    end

    # Three earlier entities to validate, one per batch, so the first run pauses.
    def paused_first_batch
      AppSettings.project_scan_validation_batch_size = 1
      project = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
      %w[Alpha Beta Gamma].each do |name|
        entity = MemoryEntity.create!(name: "#{name} Service", entity_type: "Service", project_id: project.id)
        MemoryRelation.create!(from_entity: entity, to_entity: project, relation_type: "part_of")
      end
      run_scan
      OperationProgress.find_by!(operation_id: scan_id)
    end

    it "stores the part counters and details.extraction on completion" do
      run_scan

      operation = OperationProgress.find_by!(operation_id: scan_id)
      expect(operation.counters).to include("parts_total" => 1, "parts_failed" => 0, "files_too_large" => 0, "files_over_budget" => 0)
      expect(operation.details).to include("partial" => false, "mode" => "rescan", "project_root" => @project_root)
      expect(operation.details["extraction"]).to include("parts_total" => 1, "parts_done" => 1, "files_read" => 1, "num_ctx" => 8192,
                                                         "num_predict" => 2048, "reconciled" => true, "names" => [ "SynthWidget" ])
    end

    it "end to end: a ~40 KB tree at summary_num_ctx 8192 is 3 parts, 3 calls, one merged result and a cross-part relation" do
      FileUtils.rm_f(File.join(@project_root, "README.md"))
      FileUtils.mkdir_p(File.join(@project_root, "docs"))
      %w[alpha beta gamma].each do |name|
        File.write(File.join(@project_root, "docs", "#{name}.md"), "# #{name}\n" + ("The #{name} part of Gadget Project.\n" * 380))
      end
      prompts = []
      allow(SummaryGenerationClient).to receive(:generate) do |prompt, **options|
        prompts << [ prompt, options[:options] ]
        name = prompt[%r{--- FILE: docs/(\w+)\.md}, 1]
        relations = [ { to: "Gadget Project", type: "part_of", confidence: 0.9 } ]
        relations << { to: "Alpha Store", type: "depends_on", confidence: 0.8 } if name == "gamma"
        item = { entity: { name: "#{name.capitalize} Store", type: "Component" }, observations: [ "#{name.capitalize} Store is documented." ],
                 relations: relations }
        { ok: true, done_reason: "stop", prompt_tokens: 4000, text: { project: { name: "Gadget Project" }, architecture: [ item ] }.to_json }
      end

      run_scan

      expect(prompts.size).to eq(3)
      expect(prompts.map { |prompt, _| prompt[/This is part \d of \d/] }).to eq([ "This is part 1 of 3", "This is part 2 of 3", "This is part 3 of 3" ])
      expect(prompts.last.first).to include("Entities already found (reuse these exact names when you mean the same thing): Alpha Store; Beta Store")
      expect(prompts.map(&:last)).to all(include(num_ctx: 8192, num_predict: 2048, format: "json", truncate: false))
      gamma, alpha = MemoryEntity.find_by!(name: "Gamma Store"), MemoryEntity.find_by!(name: "Alpha Store")
      expect(MemoryRelation.where(from_entity_id: gamma.id, to_entity_id: alpha.id, relation_type: "depends_on")).to exist
      status = ScanProjectStatusTool.new.call(scan_id: scan_id)
      expect(status[:counters]).to include("parts_total" => 3, "parts_failed" => 0, "entities_created" => 4)
      expect(status[:details]["extraction"]).to include("parts_total" => 3, "parts_done" => 3, "files_read" => 3, "reconciled" => true,
                                                        "names" => [ "Alpha Store", "Beta Store", "Gamma Store" ])
    end

    it "continues a paused scan's validation without a second extraction when it was reconciled" do
      operation = paused_first_batch
      expect(operation).to have_attributes(status: "paused")
      processed = operation.details.dig("validation_state", "processed_entity_ids").size

      described_class.enqueue(scan_id: scan_id, project_root: @project_root, project_name: "Gadget Project", aliases: nil,
                              mode: "rescan", dry_run: false, file_globs: [])
      run_scan

      expect(SummaryGenerationClient).to have_received(:generate).once
      expect(operation.reload.details.dig("validation_state", "processed_entity_ids").size).to be > processed
      expect(MemoryObservation.where(content: "SynthWidget renders gadgets.").count).to eq(1)
    end

    it "runs the extraction again when the paused scan's extraction wasn't reconciled" do
      operation = paused_first_batch
      operation.update!(details: operation.details.except("extraction"))

      described_class.enqueue(scan_id: scan_id, project_root: @project_root, project_name: "Gadget Project", aliases: nil,
                              mode: "rescan", dry_run: false, file_globs: [])
      run_scan

      expect(SummaryGenerationClient).to have_received(:generate).twice
    end
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

    it "broadcasts the claim and keeps the first batch's started_at when the resumed job runs" do
      scan_id = SecureRandom.uuid
      paused = OperationProgress.start!(operation_type: "project_scan", operation_id: scan_id, total_count: 6)
      paused.update!(started_at: 2.hours.ago.change(usec: 0))
      paused.pause!
      first_started_at = paused.started_at
      allow(OperationProgressBroadcaster).to receive(:call).and_call_original

      described_class.enqueue(scan_id: scan_id, **args)
      expect(OperationProgressBroadcaster).to have_received(:call).with(having_attributes(operation_id: scan_id, status: "pending"))

      described_class.perform_now(scan_id, @project_root, nil, nil, "initial", true, [])
      expect(paused.reload.started_at).to eq(first_started_at)
    end

    it "still queues the resume when the claim broadcast fails" do
      scan_id = SecureRandom.uuid
      OperationProgress.start!(operation_type: "project_scan", operation_id: scan_id, total_count: 6).pause!
      allow(OperationProgressBroadcaster).to receive(:call).and_raise(StandardError, "cable down")
      allow(Rails.logger).to receive(:warn)

      expect { described_class.enqueue(scan_id: scan_id, **args) }.to have_enqueued_job(described_class)
      expect(OperationProgress.find_by(operation_id: scan_id).status).to eq("pending")
      expect(Rails.logger).to have_received(:warn).with(/claim broadcast failed: cable down/)
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
