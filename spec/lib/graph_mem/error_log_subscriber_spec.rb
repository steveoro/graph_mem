# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::ErrorLogSubscriber do
  let(:logger) { instance_double(Logger, error: nil) }
  let(:lines) { [] }

  before { allow(logger).to receive(:error) { |line| lines << line } }

  def report(error, handled: true, context: {})
    described_class.new(logger: logger).report(error, handled: handled, severity: :warning, context: context, source: "application")
  end

  it "logs a handled MCP error with the method and tool name, never the arguments" do
    context = { mcp: { request: { method: "tools/call", params: { name: "search", arguments: { query: "SynthWidget" } } } } }

    report(StandardError.new("synth failure"), context: context)

    expect(lines.size).to eq(1)
    expect(lines.first).to include("StandardError", "synth failure", "tools/call", "search", "source=application")
    expect(lines.first).not_to include("SynthWidget")
  end

  it "filters secret parameters and caps the context" do
    report(StandardError.new("synth failure"), context: { token: "synth-secret", note: "x" * 2_000 })

    expect(lines.first).to include("[FILTERED]")
    expect(lines.first).not_to include("synth-secret")
    expect(lines.first.split("context=").last.length).to eq(described_class::CONTEXT_LIMIT)
  end

  it "writes nothing for an unhandled report" do
    report(StandardError.new("synth failure"), handled: false)

    expect(lines).to be_empty
  end

  it "never raises when the logger fails" do
    allow(logger).to receive(:error).and_raise(IOError, "synthetic logger failure")
    allow(Rails.logger).to receive(:error)

    expect { report(StandardError.new("synth failure")) }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(described_class::FAILURE_LINE)
  end

  it "logs the official MCP layer's reports through Rails.error" do
    logged = []
    allow(Rails.logger).to receive(:error) { |line| logged << line }
    request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search", arguments: { query: "SynthWidget" } } }

    GraphMem::OfficialMcp::EXCEPTION_REPORTER.call(StandardError.new("synth failure"), { request: request })

    expect(logged.grep(/synth failure/).size).to eq(1)
    expect(logged.grep(/synth failure/).first).to include("tools/call", "search")
    expect(logged.join).not_to include("SynthWidget")
  end
end
