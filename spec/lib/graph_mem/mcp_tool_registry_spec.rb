# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpToolRegistry do
  describe ".register_with!" do
    let(:server) { instance_double(FastMcp::Server, register_tools: nil, register_resources: nil) }

    it "loads all *_tool.rb classes before registering" do
      expect(described_class).to receive(:load_all!).and_call_original
      expect(server).to receive(:register_tools) do |*tools|
        names = tools.map(&:tool_name)
        expect(names).to include("merge_entities", "dream_state_status")
      end

      described_class.register_with!(server)
    end
  end

  describe ".tool_classes" do
    it "includes all production MCP tools" do
      described_class.load_all!
      names = described_class.tool_classes.map(&:tool_name)

      expect(names).to include("merge_entities", "dream_state_status", "get_maintenance_reports")
      expect(names.size).to eq(35)
    end
  end

  describe "production tool description contract" do
    before { described_class.load_all! }

    it "names required inputs and routing alternatives for every tool" do
      described_class.tool_classes.each do |klass|
        desc = klass.description.to_s
        schema = json_schema_for(klass)
        required = Array(schema[:required])
        properties = schema[:properties] || {}

        expect(desc).to be_present, "#{klass.tool_name} is missing a description"
        expect(desc).to match(/Do not use/), "#{klass.tool_name} must say when not to use it"
        expect(desc).to match(/use `[a-z][a-z0-9_]*`/), "#{klass.tool_name} must name a sibling tool"

        required.each do |key|
          expect(desc).to include(key.to_s), "#{klass.tool_name} must name required input #{key}"
        end

        next unless properties.blank?

        expect(desc).to include("Takes no arguments"), "#{klass.tool_name} must say it takes no arguments"
      end
    end
  end

  def json_schema_for(klass)
    raw = klass.input_schema_to_json
    return { properties: {}, required: [] } if raw.blank?

    raw = raw.deep_symbolize_keys
    {
      properties: raw[:properties] || {},
      required: raw[:required] || []
    }
  end
end
