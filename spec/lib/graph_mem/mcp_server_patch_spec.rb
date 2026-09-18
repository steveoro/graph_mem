# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpServerPatch do
  class EnvelopeProbeTestTool < ApplicationTool
    def self.tool_name
      "envelope_probe"
    end

    arguments do
      optional(:mode).filled(:string)
    end

    def call(mode: "not_found")
      case mode
      when "not_found"
        raise McpGraphMemErrors::ResourceNotFound, "Entity with ID=1 not found."
      when "validation"
        raise FastMcp::Tool::InvalidArgumentsError, "Page number must be 1 or greater."
      else
        raise "secret boom"
      end
    end
  end

  class HiddenAliasTestTool < ApplicationTool
    def self.tool_name
      "hidden_alias"
    end

    mcp_metadata(
      profiles: %i[default readonly maintenance],
      advertised: false,
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    description "Hidden compatibility alias"

    def call
      { hidden_alias_called: true }
    end
  end

  class DeniedProbeTestTool < ApplicationTool
    def self.tool_name
      "denied_probe"
    end

    authorize { false }

    def call
      raise "must not run"
    end
  end

  class RecordingTransport
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(message)
      @messages << message
    end
  end

  let(:logger) { Logger.new(File::NULL) }
  let(:server) { FastMcp::Server.new(name: "graph-mem-test", version: "0", logger: logger) }
  let(:transport) { RecordingTransport.new }

  before do
    server.transport = transport
    GraphMem::McpErrorFormatter.install(server)
    server.register_tool(EnvelopeProbeTestTool)
    server.register_tool(HiddenAliasTestTool)
    server.register_tool(DeniedProbeTestTool)
  end

  def last_result
    transport.messages.last.fetch(:result)
  end

  def last_error_payload
    text = last_result.fetch(:content).first.fetch(:text)
    JSON.parse(text)
  end

  def call_tool(name, id:, arguments: {})
    server.handle_request(
      {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: name, arguments: arguments },
        id: id
      }.to_json
    )
  end

  it "emits structured JSON for ResourceNotFound without a backtrace" do
    call_tool("envelope_probe", id: 1, arguments: { mode: "not_found" })

    expect(last_result[:isError]).to be(true)
    payload = last_error_payload
    expect(payload["category"]).to eq("not_found")
    expect(payload["retriable"]).to be(false)
    expect(payload["tool"]).to eq("envelope_probe")
    expect(payload["message"]).to include("not found")
    expect(payload["next_move"]).to be_present
    expect(last_result[:content].first[:text]).not_to include("mcp_server_patch_spec")
  end

  it "emits structured JSON for InvalidArgumentsError" do
    call_tool("envelope_probe", id: 2, arguments: { mode: "validation" })

    payload = last_error_payload
    expect(payload["category"]).to eq("validation")
    expect(payload["retriable"]).to be(false)
  end

  it "does not leak unexpected exception messages or backtraces" do
    call_tool("envelope_probe", id: 3, arguments: { mode: "boom" })

    payload = last_error_payload
    expect(payload["category"]).to eq("system_error")
    expect(payload["message"]).to eq("An unexpected error occurred.")
    expect(payload["message"]).not_to include("secret")
    expect(last_result[:content].first[:text]).not_to include("secret boom")
  end

  it "formats authorization failures through FastMCP's hook" do
    call_tool("denied_probe", id: 4)

    payload = last_error_payload
    expect(payload).to include(
      "category" => "permission",
      "retriable" => false,
      "message" => "Unauthorized",
      "tool" => "denied_probe"
    )
  end

  it "preserves structured errors on request-filtered server copies" do
    server.filter_tools { |_request, tools| tools }
    filtered_server = server.create_filtered_copy(instance_double(Rack::Request))
    filtered_server.transport = transport

    filtered_server.handle_request(
      {
        jsonrpc: "2.0",
        method: "tools/call",
        params: { name: "envelope_probe", arguments: { mode: "validation" } },
        id: 5
      }.to_json
    )

    expect(last_error_payload).to include(
      "category" => "validation",
      "tool" => "envelope_probe"
    )
  end

  it "omits hidden aliases from tools/list while keeping them callable" do
    server.handle_request({ jsonrpc: "2.0", method: "tools/list", id: 6 }.to_json)

    names = last_result.fetch(:tools).map { |tool| tool.fetch(:name) }
    expect(names).to include("envelope_probe")
    expect(names).not_to include("hidden_alias")

    call_tool("hidden_alias", id: 7)

    expect(last_result[:isError]).to be(false)
    expect(last_result.dig(:content, 0, :text)).to include("hidden_alias_called")
  end
end
