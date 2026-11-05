# frozen_string_literal: true

require "rails_helper"

# F-3b step N: the scan applies the noise filter to the LLM extraction before reconcile, reports
# the counts in its Ruby result and one `[scan]` log line, and leaves the deterministic fallback as it is.
RSpec.describe ProjectScanner, "noise filter" do
  include LlmSpecHelpers

  let(:root) { Dir.mktmpdir("noise-scan") }
  let(:answer) do
    { "project" => { "name" => "Gadget Project" },
      "architecture" => [
        { "entity" => { "name" => "SynthWidget", "type" => "Class" },
          "observations" => [ "SynthWidget renders gadget frames.", "synthwidget renders gadget frames" ],
          "relations" => [ { "to" => "SynthWidget", "type" => "uses" }, { "to" => "Gadget Project", "type" => "part_of" } ] },
        { "entity" => { "name" => "Utils", "type" => "Module" }, "observations" => [ "Utils holds shared helpers." ], "relations" => [] },
        { "entity" => { "name" => "Gadget Notes", "type" => "Concept" }, "observations" => [], "relations" => [] }
      ] }
  end
  let(:provider) { FakeProvider.new(result: { ok: true, text: answer.to_json, error: nil, latency_ms: 1.0, done_reason: "stop", prompt_tokens: 10 }) }

  before { File.write(File.join(root, "README.md"), "# Gadget Project\n\nSynthWidget renders gadget frames.\n") }
  after { FileUtils.rm_rf(root) }

  it "reconciles the filtered extraction and reports what was dropped, in the result and one numbers-only log line" do
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first if args.first.to_s.start_with?("[scan] ")
      original.call(*args, &block)
    end

    result = with_llm_provider(provider) { described_class.new(project_root: root, project_name: "Gadget Project").call }

    expect(result.noise_dropped).to eq("duplicate_observations" => 1, "self_relations" => 1, "generic_items" => 1, "empty_items" => 1)
    expect(result.to_h[:noise_dropped]).to eq(result.noise_dropped)
    widget = MemoryEntity.find_by!(name: "SynthWidget")
    expect(widget.memory_observations.pluck(:content)).to eq([ "SynthWidget renders gadget frames." ])
    expect(MemoryEntity.where(name: [ "Utils", "Gadget Notes" ])).to be_empty
    expect(lines.sole).to eq("[scan] #{JSON.generate(scan_id: lines.sole[/"scan_id":"([^"]+)"/, 1], noise_dropped: result.noise_dropped)}")
    expect(lines.sole).not_to include("SynthWidget", "Gadget", root)
  end

  it "doesn't filter the deterministic fallback" do
    result = with_llm_provider(FakeProvider.new(available: false)) { described_class.new(project_root: root, project_name: "Gadget Project").call }

    expect(result.fallback).to be(true)
    expect(result.noise_dropped).to eq({})
  end
end
