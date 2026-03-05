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

  tool_input_schema({
    type: "object",
    properties: { name: { type: "string" }, count: { type: "integer" } },
    required: [ "name" ]
  })

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
  after { Current.reset }

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

  describe "#input_schema_to_json" do
    it "delegates to the class-level tool_input_schema when defined" do
      tool = DslTestTool.new
      json = tool.input_schema_to_json
      expect(json).to be_a(Hash)
      expect(json[:properties]).to have_key(:name)
      expect(json[:required]).to include("name")
    end

    it "returns the empty default schema when no tool_input_schema is explicitly set" do
      tool = NoDslTestTool.new
      json = tool.input_schema_to_json
      expect(json).to eq({ type: "object", properties: {}, required: [] })
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

  describe "#call" do
    it "sets Current.actor before calling super" do
      tool = DslTestTool.new
      # Invoke ApplicationTool's call method directly; rescue any error from
      # super since FastMcp::Tool may not define call
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

  describe ".tool_description" do
    it "returns fallback when only FastMcp description DSL is used (not tool_description)" do
      expect(DslTestTool.tool_description).to eq("dsl_test - A general purpose tool.")
    end

    it "falls back to default when unset" do
      expect(NoDslTestTool.tool_description).to include("no_dsl_test")
    end
  end

  describe ".tool_input_schema" do
    it "stores and retrieves a custom schema" do
      schema = DslTestTool.tool_input_schema
      expect(schema[:properties]).to have_key(:name)
    end

    it "returns empty default when unset" do
      schema = NoDslTestTool.tool_input_schema
      expect(schema).to eq({ type: "object", properties: {}, required: [] })
    end
  end
end
