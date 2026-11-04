# frozen_string_literal: true

require "rails_helper"
require "rake"

# Agent-CLI PR4, step T: bin/rails llm:bridge_probe.
RSpec.describe "llm:bridge_probe", type: :task do
  before do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "llm:bridge_probe" }
    Rake::Task["llm:bridge_probe"].reenable
  end

  def probe_output = capture_stdout { Rake::Task["llm:bridge_probe"].invoke }

  def capture_stdout
    output = StringIO.new
    saved = $stdout
    $stdout = output
    yield
    output.string
  ensure
    $stdout = saved
  end

  it "prints one line per profile, no path or token" do
    start_bridge_stub do
      [ 200, { bridge_version: "1.0.0", profiles: { claude: { cli_ok: true, cli_realpath: "/path/to/zq7/claude", gate: { result: "PASS", passed_on: "2026-11-04" }, gate_ok: true, tripped: false },
                                                     devin: { cli_ok: true, gate: nil, gate_ok: false, tripped: true } } } ]
    end

    text = probe_output

    expect(text.lines.map(&:chomp)).to eq([ "bridge: reachable (version 1.0.0)", "  claude: cli found, gate PASS (passed on 2026-11-04), usable",
                                            "  devin: cli found, gate none, not usable, TRIPPED" ])
    expect(text).not_to include("/path/to", bridge_token)
  end

  it "says when it isn't configured" do
    saved = ENV.delete("LLM_BRIDGE_URL")

    expect(probe_output).to eq("bridge: not configured (url_unset)\n")
  ensure
    ENV["LLM_BRIDGE_URL"] = saved if saved
  end
end
