# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolError do
  describe ".envelope" do
    it "maps ResourceNotFound to not_found" do
      error = McpGraphMemErrors::ResourceNotFound.new("Entity with ID=9 not found.")
      payload = described_class.envelope(error, tool_name: "get_entity")

      expect(payload).to include(
        "error" => true,
        "category" => "not_found",
        "retriable" => false,
        "message" => "Entity with ID=9 not found.",
        "tool" => "get_entity"
      )
      expect(payload["next_move"]).to include("`search_entities`")
    end

    it "maps InvalidArgumentsError to validation" do
      error = FastMcp::Tool::InvalidArgumentsError.new("Invalid arguments: {\"name\":[\"is missing\"]}")
      payload = described_class.envelope(error, tool_name: "create_entity")

      expect(payload["category"]).to eq("validation")
      expect(payload["retriable"]).to be(false)
      expect(payload["next_move"]).to match(/argument format/i)
    end

    it "maps entity-name misses raised as InvalidArgumentsError to not_found" do
      error = FastMcp::Tool::InvalidArgumentsError.new("Entity not found by name: 'Missing'.")
      payload = described_class.envelope(error, tool_name: "get_entity")

      expect(payload["category"]).to eq("not_found")
      expect(payload["retriable"]).to be(false)
    end

    it "maps Net::ReadTimeout to timeout" do
      error = Net::ReadTimeout.new("execution expired")
      payload = described_class.envelope(error, tool_name: "search_entities")

      expect(payload["category"]).to eq("timeout")
      expect(payload["retriable"]).to be(true)
    end

    it "maps Timeout::Error to timeout and marks it retriable" do
      error = Timeout::Error.new("execution expired")
      payload = described_class.envelope(error, tool_name: "summarize")

      expect(payload["category"]).to eq("timeout")
      expect(payload["retriable"]).to be(true)
      expect(payload["next_move"]).to match(/retry the tool once/i)
      expect(payload["message"]).to eq("execution expired")
    end

    it "maps unknown exceptions to system_error without leaking the original message" do
      error = RuntimeError.new("PG::ConnectionBad: super secret")
      payload = described_class.envelope(error, tool_name: "search_entities")

      expect(payload["category"]).to eq("system_error")
      expect(payload["retriable"]).to be(false)
      expect(payload["message"]).to eq("An unexpected error occurred.")
      expect(payload["message"]).not_to include("secret")
    end

    it "uses a custom next_move from McpGraphMemErrors" do
      error = McpGraphMemErrors::ResourceNotFound.new(
        "Observation 4 not found.",
        next_move: "Call get_entity to list observation ids, then retry delete_observation."
      )
      payload = described_class.envelope(error, tool_name: "delete_observation")

      expect(payload["next_move"]).to include("get_entity")
    end
  end

  describe ".dump" do
    it "returns parseable JSON with the required keys and no backtrace" do
      error = McpGraphMemErrors::InternalServerError.new("Failed internally")
      json = described_class.dump(error, tool_name: "get_graph_stats")
      payload = JSON.parse(json)

      expect(payload.keys).to include(*described_class::ENVELOPE_KEYS)
      expect(json).not_to include("app/tools")
      expect(json).not_to include("backtrace")
    end
  end

  describe ".dump_unauthorized" do
    it "returns a permission envelope" do
      payload = JSON.parse(described_class.dump_unauthorized(tool_name: "delete_entity"))

      expect(payload["category"]).to eq("permission")
      expect(payload["retriable"]).to be(false)
      expect(payload["message"]).to eq("Unauthorized")
    end
  end
end
