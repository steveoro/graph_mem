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

  it "advertises a typed operation item that still accepts extra keys" do
    items = described_class.input_schema_to_json.dig(:properties, :operations, :items)

    expect(items).to include(required: [ "type" ], additionalProperties: true)
    expect(items[:properties]).to include(
      supersede: include(type: "boolean"),
      reason: include(type: "string"),
      valid_until: include(type: "string", format: "date-time"),
      perspective: include(enum: MemoryObservation::PERSPECTIVES),
      aliases: include(type: "array", items: { type: "string" }),
      entity_id: include(type: "integer"),
      observation_id: include(type: "integer")
    )
    expect(items.dig(:properties, :type, :examples)).to eq(GraphEditService::TYPES)
  end

  it "round-trips update_entity aliases as a deduplicated pipe-separated list" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", aliases: "old")
    aliases = [ " A.C.M.E., Inc. ", "ACME", "acme", "" ]

    tool.call_with_schema_validation!(operations: [ { type: "update_entity", entity_id: entity.id, aliases: aliases } ])

    expect(entity.reload.aliases).to eq("A.C.M.E., Inc.|ACME")
    expect(entity.aliases.split("|")).to eq([ "A.C.M.E., Inc.", "ACME" ])
  end

  it "still accepts a legacy pipe-separated aliases string" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")

    tool.call_with_schema_validation!(
      operations: [ { type: "update_entity", entity_id: entity.id, aliases: "Synth Widget| SW |sw" } ]
    )

    expect(entity.reload.aliases).to eq("Synth Widget|SW")
  end

  it "clears aliases with an empty array" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", aliases: "old")

    tool.call_with_schema_validation!(operations: [ { type: "update_entity", entity_id: entity.id, aliases: [] } ])

    expect(entity.reload.aliases).to eq("")
  end

  it "rejects an alias that contains the pipe separator" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", aliases: "old")

    expect do
      tool.call_with_schema_validation!(
        operations: [ { type: "update_entity", entity_id: entity.id, aliases: [ "A|B" ] } ]
      )
    end.to raise_error(FastMcp::Tool::InvalidArgumentsError, /contains "\|"/)
    expect(entity.reload.aliases).to eq("old")
  end

  it "supersedes an observation with a new valid_until" do
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    observation = entity.memory_observations.create!(content: "Use should syntax")
    valid_until = 3.days.from_now.change(usec: 0)

    result, = tool.call_with_schema_validation!(
      operations: [ {
        type: "update_observation", observation_id: observation.id, text_content: "Use expect syntax",
        valid_until: valid_until.iso8601, supersede: true, reason: "style changed"
      } ]
    )

    expect(result[:status]).to eq("ok")
    current = entity.memory_observations.find_by(content: "Use expect syntax")
    expect(current.valid_until).to eq(valid_until)
    expect(entity.memory_observations.where(content: "Use should syntax")).to exist
  end
end
