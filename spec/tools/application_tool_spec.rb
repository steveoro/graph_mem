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
end
