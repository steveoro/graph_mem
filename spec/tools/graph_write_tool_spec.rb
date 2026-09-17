# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphWriteTool, type: :model do
  let(:tool) { described_class.new }
  let(:vector_strategy) { instance_double(VectorSearchStrategy, search: []) }

  before { allow(VectorSearchStrategy).to receive(:new).and_return(vector_strategy) }

  it "advertises the canonical tool metadata and operation inputs" do
    expect(described_class.tool_name).to eq("graph_write")
    expect(described_class.annotations).to include(destructive_hint: false)
    expect(described_class.input_schema_to_json[:properties]).to include(
      :operations,
      :entities,
      :observations,
      :relations
    )
  end

  it "accepts one operation and returns a batch envelope" do
    result = tool.call(
      operations: [ { type: "create_entity", name: "Canonical write", entity_type: "Task" } ]
    )

    expect(result).to include(mode: "batch", status: "ok")
    expect(result[:summary]).to include(operations: 1, entities_created: 1)
  end

  it "accepts the legacy three-array input form" do
    result = tool.call(entities: [ { name: "Bucket entity", entity_type: "Task" } ])

    expect(result[:summary][:entities_created]).to eq(1)
  end

  it "normalizes and validates type-discriminated MCP input" do
    result, = tool.call_with_schema_validation!(
      operations: [ { type: "entity", name: "Normalized write", entityType: "Task" } ]
    )

    expect(result[:summary][:entities_created]).to eq(1)
  end
end
