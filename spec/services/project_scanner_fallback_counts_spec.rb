# frozen_string_literal: true

require "rails_helper"

# A scan whose every part failed falls back to the deterministic extraction and still reports the
# parts it tried (1.73.1): before, the fallback reset parts_total and parts_failed to 0, so the scan
# page, scan_project_status and the profiler showed "0 parts".
RSpec.describe ProjectScanner, "fallback counts" do
  include LlmSpecHelpers

  let(:root) { Dir.mktmpdir("fallback-scan") }

  before { File.write(File.join(root, "README.md"), "# Gadget Project\n\nSynthWidget renders gadget frames.\n") }
  after { FileUtils.rm_rf(root) }

  def scan(provider, operation_progress: nil)
    with_llm_provider(provider) do
      described_class.new(project_root: root, project_name: "Gadget Project", operation_progress: operation_progress).call
    end
  end

  it "keeps the failed parts' counts when every part failed, and the fallback stays complete" do
    down = FakeProvider.new(result: { ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0 })

    result = scan(down)

    expect(result).to have_attributes(fallback: true, fallback_reason: "provider_unavailable", partial: false, parts_total: 1, parts_failed: 1)
    expect(down.calls.size).to eq(1)
  end

  it "counts the split halves of an answer that isn't usable JSON" do
    empty = FakeProvider.new(result: { ok: true, text: "{}", error: nil, latency_ms: 1.0, done_reason: "stop", prompt_tokens: 10 })
    File.write(File.join(root, "Gemfile"), %(source "https://rubygems.org"\ngem "rack"\n))
    operation = OperationProgress.start!(operation_type: "project_scan", operation_id: SecureRandom.uuid, total_count: 6, message: "Synthetic scan")

    result = scan(empty, operation_progress: operation)

    expect(result).to have_attributes(fallback: true, fallback_reason: "LLM response was not valid JSON", parts_total: 2, parts_failed: 2)
    expect(operation.reload.details["extraction"]).to include("parts_total" => 2, "parts_failed" => 2)
    expect(operation.details["extraction"]).not_to have_key("partial")
  end

  it "still reports no parts when the model wasn't asked at all" do
    result = scan(FakeProvider.new(available: false))

    expect(result).to have_attributes(fallback: true, parts_total: 0, parts_failed: 0)
  end
end
