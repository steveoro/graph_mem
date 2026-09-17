# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphEditTool, type: :model do
  let(:tool) { described_class.new }

  it "advertises a destructive atomic operations schema" do
    expect(described_class.tool_name).to eq("graph_edit")
    expect(described_class.annotations).to include(destructive_hint: true, idempotent_hint: false)
    expect(described_class.input_schema_to_json[:required]).to eq([ "operations" ])
  end

  it "edits one entity through a batch envelope" do
    entity = MemoryEntity.create!(name: "Canonical edit", entity_type: "Task")

    result = tool.call(
      operations: [ { type: "update_entity", entity_id: entity.id, description: "Changed" } ]
    )

    expect(result).to include(mode: "batch", status: "ok")
    expect(result[:summary]).to include(operations: 1, entities_updated: 1)
    expect(entity.reload.description).to eq("Changed")
  end

  it "normalizes nested MCP fields before editing" do
    entity = MemoryEntity.create!(name: "Normalized edit", entity_type: "Task")

    result, = tool.call_with_schema_validation!(
      operations: [ { type: "update_entity", entityId: entity.id, description: "Normalized" } ]
    )

    expect(result[:summary][:entities_updated]).to eq(1)
    expect(entity.reload.description).to eq("Normalized")
  end
end
