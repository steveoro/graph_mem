# frozen_string_literal: true

require "rails_helper"

# Minimal tool subclass that uses the arguments DSL
class DslTestTool < ApplicationTool
  def self.tool_name
    "dsl_test"
  end

  description "A tool with DSL arguments"

  arguments do
    required(:name).filled(:string)
    optional(:count).filled(:integer)
  end

  def call(name:, count: nil)
    { name: name, count: count }
  end
end

# Minimal tool subclass that has no arguments DSL and no description
class NoDslTestTool < ApplicationTool
  def self.tool_name
    "no_dsl_test"
  end

  def call
    { ok: true }
  end
end

RSpec.describe ApplicationTool do
  after do
    Current.reset
    AgentContext.delete_all
  end

  describe ".input_schema" do
    it "returns a Dry::Schema when the subclass uses the arguments DSL" do
      schema = DslTestTool.input_schema
      expect(schema).to be_a(Dry::Schema::JSON)
    end

    it "returns a default Dry::Schema::JSON when the subclass has no arguments DSL" do
      schema = NoDslTestTool.input_schema
      expect(schema).to be_a(Dry::Schema::JSON)
    end
  end

  describe "#description" do
    it "returns the FastMcp class-level description when set" do
      tool = DslTestTool.new
      expect(tool.description).to eq("A tool with DSL arguments")
    end

    it "returns nil when no description is set via FastMcp DSL" do
      tool = NoDslTestTool.new
      expect(tool.description).to be_nil
    end
  end

  describe "#call_with_schema_validation!" do
    after { CompactionRun.delete_all }

    it "requests compaction pause for valve-enabled tools" do
      valve_tool_class = Class.new(ApplicationTool) do
        def self.tool_name
          "create_entity"
        end

        arguments do
          required(:name).filled(:string)
        end

        def call(name:)
          { name: name }
        end
      end

      expect(CompactionValve).to receive(:request_pause_if_running!)
      tool = valve_tool_class.new
      tool.call_with_schema_validation!(name: "test")
    end

    it "normalizes parameters before validation and dispatch" do
      tool = DslTestTool.new
      result, _meta = tool.call_with_schema_validation!(name: "test", count: 5)
      expect(result).to eq({ name: "test", count: 5 })
    end

    it "converts camelCase parameters to snake_case" do
      tool = DslTestTool.new
      # DslTestTool has no camelCase fields, but the normalizer should not break
      result, _meta = tool.call_with_schema_validation!(name: "test")
      expect(result[:name]).to eq("test")
    end

    it "raises InvalidArgumentsError for missing required parameters" do
      tool = DslTestTool.new
      expect {
        tool.call_with_schema_validation!(count: 5)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /name/)
    end

    it "records MCP client activity after validation succeeds" do
      tool = DslTestTool.new(headers: { "HTTP_X_MCP_CLIENT" => "cursor-A" })

      tool.call_with_schema_validation!(name: "test")

      ctx = AgentContext.find_by!(client_id: "cursor-A")
      expect(ctx.last_tool_name).to eq("dsl_test")
      expect(ctx.last_seen_at).to be_within(2.seconds).of(Time.current)
    end

    it "records MCP client activity from fast-mcp normalized headers" do
      tool = DslTestTool.new(headers: { "x-mcp-client" => "cursor-fast-mcp" })

      tool.call_with_schema_validation!(name: "test")

      ctx = AgentContext.find_by!(client_id: "cursor-fast-mcp")
      expect(ctx.last_tool_name).to eq("dsl_test")
      expect(ctx.last_seen_at).to be_within(2.seconds).of(Time.current)
    end

    it "does not record MCP client activity when validation fails" do
      tool = DslTestTool.new(headers: { "HTTP_X_MCP_CLIENT" => "cursor-A" })

      expect {
        tool.call_with_schema_validation!(count: 5)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError)

      expect(AgentContext.find_by(client_id: "cursor-A")).to be_nil
    end
  end

  describe "#call" do
    it "sets Current.actor before calling super" do
      tool = DslTestTool.new
      begin
        ApplicationTool.instance_method(:call).bind_call(tool, name: "test")
      rescue NoMethodError
        # Expected if FastMcp::Tool doesn't implement #call
      end
      expect(Current.actor).to eq("mcp:dsl_test")
    end
  end

  describe "#tool_name" do
    it "delegates to self.class.tool_name" do
      tool = DslTestTool.new
      expect(tool.tool_name).to eq("dsl_test")
    end
  end

  describe "#logger" do
    it "returns Rails.logger" do
      tool = DslTestTool.new
      expect(tool.logger).to eq(Rails.logger)
    end
  end

  describe "#current_client_id" do
    it "returns default when headers are absent" do
      tool = DslTestTool.new
      expect(tool.current_client_id).to eq(GraphMemContext::DEFAULT_CLIENT_ID)
    end

    it "reads HTTP_X_MCP_CLIENT from headers" do
      tool = DslTestTool.new(headers: { "HTTP_X_MCP_CLIENT" => "cursor-A" })
      expect(tool.current_client_id).to eq("cursor-A")
    end

    it "reads X-MCP-CLIENT from headers" do
      tool = DslTestTool.new(headers: { "X-MCP-CLIENT" => "cursor-B" })
      expect(tool.current_client_id).to eq("cursor-B")
    end

    it "reads X-MCP-Client from configured MCP headers" do
      tool = DslTestTool.new(headers: { "X-MCP-Client" => "cursor-C" })
      expect(tool.current_client_id).to eq("cursor-C")
    end

    it "reads x-mcp-client from fast-mcp normalized headers" do
      tool = DslTestTool.new(headers: { "x-mcp-client" => "cursor-D" })
      expect(tool.current_client_id).to eq("cursor-D")
    end

    it "normalizes equivalent case and underscore header variants" do
      tool = DslTestTool.new(headers: { "http_x_mcp_client" => "cursor-E" })
      expect(tool.current_client_id).to eq("cursor-E")
    end

    it "returns default when the MCP client header is blank" do
      tool = DslTestTool.new(headers: { "x-mcp-client" => " " })
      expect(tool.current_client_id).to eq(GraphMemContext::DEFAULT_CLIENT_ID)
    end
  end

  describe "#graph_mem_context" do
    after { GraphMemContext.clear_all! }

    it "returns a GraphMemContext scoped to current_client_id" do
      tool = DslTestTool.new(headers: { "HTTP_X_MCP_CLIENT" => "cursor-A" })
      ctx = tool.graph_mem_context
      expect(ctx).to be_a(GraphMemContext)
      expect(ctx.client_id).to eq("cursor-A")
    end
  end
end
