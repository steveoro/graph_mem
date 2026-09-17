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
    server.register_tool(EnvelopeProbeTestTool)
    server.register_tool(HiddenAliasTestTool)
  end

  def last_result
    transport.messages.last.fetch(:result)
  end

  def last_error_payload
    text = last_result.fetch(:content).first.fetch(:text)
    JSON.parse(text)
  end

  it "emits structured JSON for ResourceNotFound without a backtrace" do
    server.handle_tools_call({ "name" => "envelope_probe", "arguments" => { "mode" => "not_found" } }, {}, 1)

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
    server.handle_tools_call({ "name" => "envelope_probe", "arguments" => { "mode" => "validation" } }, {}, 2)

    payload = last_error_payload
    expect(payload["category"]).to eq("validation")
    expect(payload["retriable"]).to be(false)
  end

  it "does not leak unexpected exception messages or backtraces" do
    server.handle_tools_call({ "name" => "envelope_probe", "arguments" => { "mode" => "boom" } }, {}, 3)

    payload = last_error_payload
    expect(payload["category"]).to eq("system_error")
    expect(payload["message"]).to eq("An unexpected error occurred.")
    expect(payload["message"]).not_to include("secret")
    expect(last_result[:content].first[:text]).not_to include("secret boom")
  end

  it "omits hidden aliases from tools/list while keeping them callable" do
    server.handle_tools_list(4)

    names = last_result.fetch(:tools).map { |tool| tool.fetch(:name) }
    expect(names).to include("envelope_probe")
    expect(names).not_to include("hidden_alias")

    server.handle_tools_call({ "name" => "hidden_alias", "arguments" => {} }, {}, 5)

    expect(last_result[:isError]).to be(false)
    expect(last_result.dig(:content, 0, :text)).to include("hidden_alias_called")
  end
end
