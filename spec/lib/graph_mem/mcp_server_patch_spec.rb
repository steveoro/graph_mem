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

  it "applies in-place request filters before hiding compatibility aliases" do
    request = instance_double(Rack::Request)
    server.filter_tools do |_request, tools|
      tools.reject { |tool| tool == DeniedProbeTestTool }
    end

    server.with_request_context(transport: transport, request: request) do
      server.handle_request({ jsonrpc: "2.0", method: "tools/list", id: 5 }.to_json)
    end

    names = last_result.fetch(:tools).map { |tool| tool.fetch(:name) }
    expect(names).to include("envelope_probe")
    expect(names).not_to include("denied_probe", "hidden_alias")
  end

  describe "fork drift guard" do
    it "is pinned to the current FastMcp version" do
      expect(FastMcp::VERSION).to eq(GraphMem::McpServerPatch::EXPECTED_FORK_VERSION),
        "FastMcp version changed to #{FastMcp::VERSION} — " \
        "re-diff McpServerPatch#handle_tools_list against the fork"
    end

    it "produces the same tool entries as the fork minus hidden aliases" do
      fork_method = FastMcp::Server.instance_method(:handle_tools_list).super_method
      expect(fork_method.owner).to eq(FastMcp::Server),
        "super_method owner is not FastMcp::Server — ancestry changed"

      request = instance_double(Rack::Request)

      fork_transport = RecordingTransport.new
      server.transport = fork_transport
      server.with_request_context(transport: fork_transport, request: request) do
        fork_method.bind_call(server, 200)
      end
      fork_tools = fork_transport.messages.last.fetch(:result).fetch(:tools)

      expect(fork_tools.map { |t| t[:name] }).to include("hidden_alias"),
        "fork output must include hidden_alias to prove it ran unpatched"

      server.transport = transport
      server.with_request_context(transport: transport, request: request) do
        server.handle_request({ jsonrpc: "2.0", method: "tools/list", id: 201 }.to_json)
      end
      patched_tools = last_result.fetch(:tools)

      expect(patched_tools).to eq(fork_tools.reject { |t| t[:name] == "hidden_alias" })
    end
  end

  it "does not raise or double-prepend when the patch file is re-evaluated" do
    count_before = FastMcp::Server.ancestors.count { |m| m.name == "GraphMem::McpServerPatch" }
    expect(count_before).to eq(1)

    load Rails.root.join("lib/graph_mem/mcp_server_patch.rb")

    count_after = FastMcp::Server.ancestors.count { |m| m.name == "GraphMem::McpServerPatch" }
    expect(count_after).to eq(1)
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
