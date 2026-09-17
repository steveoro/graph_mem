# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphDeleteTool, type: :model do
  let(:tool) { described_class.new }

  it "advertises a destructive atomic operations schema" do
    expect(described_class.tool_name).to eq("graph_delete")
    expect(described_class.annotations).to include(destructive_hint: true, idempotent_hint: false)
    expect(described_class.input_schema_to_json[:required]).to eq([ "operations" ])
  end

  it "obsoletes one observation through a batch envelope" do
    entity = MemoryEntity.create!(name: "Canonical delete", entity_type: "Task")
    observation = MemoryObservation.create!(memory_entity: entity, content: "Old fact")

    result = tool.call(
      operations: [ { type: "delete_observation", observation_id: observation.id, reason: "Old" } ]
    )

    expect(result).to include(mode: "batch", status: "ok")
    expect(result[:summary]).to include(operations: 1, observations_obsoleted: 1)
    expect(observation.reload.status).to eq(MemoryObservation::OBSOLETE_STATUS)
  end

  it "normalizes nested MCP fields before deleting" do
    entity = MemoryEntity.create!(name: "Normalized delete", entity_type: "Task")
    observation = MemoryObservation.create!(memory_entity: entity, content: "Old fact")

    result, = tool.call_with_schema_validation!(
      operations: [ { type: "delete_observation", observationId: observation.id } ]
    )

    expect(result[:summary][:observations_obsoleted]).to eq(1)
  end
end
