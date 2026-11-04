# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step N: an agent CLI's answer made to look like Ollama's. Inputs come from the
# synthetic envelope fixtures in spec/fixtures/llm_bridge/envelopes/ (the bridge sends `text`
# already unwrapped from the envelope).
RSpec.describe Llm::ResponseNormalizer do
  let(:fixtures) { Rails.root.join("spec/fixtures/llm_bridge/envelopes") }
  let(:claude_text) { JSON.parse(fixtures.join("claude.json").read).fetch("result") }
  let(:devin_text) { fixtures.join("devin.txt").read }

  def json(text, **options) = described_class.call(text, { format: "json", max_output_length: nil }.merge(options))

  it "unwraps the fenced JSON object from the prose around it (claude fixture)" do
    body = json(claude_text)

    expect(JSON.parse(body).dig("architecture", 0, "entity", "name")).to eq("SynthWidget")
    expect(body).to start_with("{").and end_with("}")
  end

  it "unwraps a fenced JSON array after prose, with escaped quotes and braces inside strings (devin fixture)" do
    body = json(devin_text)

    expect(JSON.parse(body).sole).to include("id" => 7, "reason" => 'Alpha Service moved SynthWidget off zq7.example "build" {old}')
  end

  it "skips stray brackets in the prose before the value, and keeps nested ones inside strings" do
    text = "Notes [draft] and {aside}: here it is {\"a\": {\"b\": \"x } ] {\"}, \"c\": [1, [2]]} thanks"

    expect(JSON.parse(json(text))).to eq("a" => { "b" => "x } ] {" }, "c" => [ 1, [ 2 ] ])
  end

  it "passes text without a parseable JSON value through unchanged" do
    [ "No JSON here.", "{ unbalanced", "{\"a\": }", "```json\n{\"a\": \n```" ].each do |text|
      expect(json(text)).to eq(text)
    end
  end

  it "leaves an answer over the 256 KiB cap as it is" do
    text = "Prose #{'x' * Llm::ResponseNormalizer::SCAN_CAP} {\"a\": 1}"

    expect(json(text)).to equal(text)
  end

  it "scans a large masked answer in linear time" do
    text = "Intro ⟦ENT_1a2b⟧ " + JSON.generate(items: Array.new(4_000) { |i| { name: "⟦ENT_#{i.to_s(16)}⟧ é", n: i } })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(JSON.parse(json(text))["items"].size).to eq(4_000)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2.0
  end

  it "applies max_output_length after unwrapping, without splitting a token" do
    expect(json("Sure: {\"a\": \"#{'z' * 50}\"}", max_output_length: 10)).to eq("{\"a\": \"zzz")
    expect(described_class.call("A ⟦ENT_1a2b⟧ b", { max_output_length: 6 })).to eq("A ")
    expect(described_class.call("A ⟦ENT_1a2b⟧ b", { max_output_length: 12 })).to eq("A ⟦ENT_1a2b⟧")
  end

  it "only trims a summary (no format), and cuts it at SummaryGenerationClient's default" do
    expect(described_class.call("  ```json\n{\"a\": 1}\n```\n", nil)).to eq("```json\n{\"a\": 1}\n```")
    expect(described_class::DEFAULT_MAX_OUTPUT_LENGTH).to eq(SummaryGenerationClient::MAX_OUTPUT_LENGTH)
    long = "w" * (SummaryGenerationClient::MAX_OUTPUT_LENGTH + 5)
    expect(described_class.call(long, {}).length).to eq(SummaryGenerationClient::MAX_OUTPUT_LENGTH)
    expect(described_class.call(long, { max_output_length: nil })).to eq(long)
  end
end
