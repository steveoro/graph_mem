# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.75.0: the profiler's progress lines while a scan runs (steps, parts, a heartbeat).
RSpec.describe GraphMem::ScanProfile::Progress do
  include LlmSpecHelpers

  let(:out) { StringIO.new }
  let(:progress) { described_class.new("synth code initial", out: out) }

  def lines = out.string.lines.map(&:chomp)

  it "prints each step and each part's end with the label, a failure's reason and a split" do
    progress.phase("extracting_knowledge", "Extracting knowledge: part 2 of 3")
    progress.part_done(ProjectScanner::ChunkedExtraction::PartDone.new(part: 2, parts: 3, error: nil, seconds: 412.4, split: false))
    progress.part_done(ProjectScanner::ChunkedExtraction::PartDone.new(part: 3, parts: 4, error: "answer cut at num_predict 2048 (done_reason: length)",
                                                                        seconds: 61.6, split: true))

    expect(lines).to eq([ "[scan_profile] synth code initial: Extracting knowledge: part 2 of 3",
                          "[scan_profile] synth code initial: part 2 of 3 done in 412 s",
                          "[scan_profile] synth code initial: part 3 of 4 failed (answer cut at num_predict 2048 (done_reason: length)) " \
                          "in 62 s; split in two" ])
  end

  it "prints a step once when the scan reports it twice in a row" do
    2.times { progress.phase("completed", "Partial: 2 of 8 parts failed; nothing was marked missing") }

    expect(lines).to eq([ "[scan_profile] synth code initial: Partial: 2 of 8 parts failed; nothing was marked missing" ])
  end

  it "prints a heartbeat with the current step while the scan runs, and stops with it" do
    stub_const("#{described_class}::HEARTBEAT_SECONDS", 0.01)

    value = progress.watch do
      progress.phase("extracting_knowledge", "Extracting knowledge: part 1 of 1")
      sleep 0.08
      :result
    end
    printed = lines.size
    sleep 0.05

    expect(value).to eq(:result)
    expect(lines).to include("[scan_profile] synth code initial: still working (Extracting knowledge: part 1 of 1; 0 min so far)")
    expect(lines.size).to eq(printed)
  end

  it "prints nothing and starts no thread without an output" do
    silent = described_class.new("synth code initial", out: nil)
    allow(Thread).to receive(:new).and_call_original

    value = silent.watch do
      silent.phase("completed", "Project scan completed")
      :done
    end

    expect(value).to eq(:done)
    expect(Thread).not_to have_received(:new)
  end

  it "gets ProjectScanner's steps through on_progress, without an operation_progress" do
    steps = []
    provider = FakeProvider.new(result: { ok: true, done_reason: "stop", prompt_tokens: 10, error: nil, latency_ms: 1.0,
                                          text: { project: { name: "Gadget Project" }, architecture: [] }.to_json })

    Dir.mktmpdir("progress-scan") do |root|
      File.write(File.join(root, "README.md"), "# Gadget Project\n\nSynthWidget renders gadget frames.\n")
      with_llm_provider(provider) do
        ProjectScanner.new(project_root: root, project_name: "Gadget Project", on_progress: ->(_phase, message) { steps << message }).call
      end
    end

    expect(steps).to start_with("Discovering project files", "Reading 1 project files", "Extracting knowledge",
                                "Extracting knowledge: part 1 of 1", "Reconciling with graph memory")
    expect(steps.last).to eq("Project scan completed")
  end
end
