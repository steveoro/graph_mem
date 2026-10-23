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
    operation_properties = described_class.input_schema_to_json.dig(
      :properties,
      :operations,
      :items,
      :properties
    )
    expect(operation_properties.dig(:entity_type, :examples)).to include("Project", "Task")
    expect(operation_properties.dig(:relation_type, :examples)).to include("part_of", "depends_on")
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

  describe "provenance and staleness fields" do
    let(:entity) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
    let(:schema) { described_class.input_schema_to_json }
    let(:operation_properties) { schema.dig(:properties, :operations, :items, :properties) }

    it "advertises the observation and relation fields the service accepts" do
      expect(operation_properties).to include(
        source: include(type: "string"),
        confidence: include(type: "number", minimum: 0, maximum: 1),
        valid_from: include(type: "string", format: "date-time"),
        valid_until: include(type: "string", format: "date-time"),
        tags: include(type: "array", items: { type: "string" }),
        perspective: include(type: "string", enum: MemoryObservation::PERSPECTIVES),
        weight: include(type: "number", minimum: 0),
        properties: include(type: "object")
      )
      expect(schema.dig(:properties, :observations, :items, :properties).keys).to contain_exactly(
        :entity_id, :text_content, :source, :confidence, :valid_from, :valid_until, :tags, :perspective
      )
    end

    it "persists every advertised observation field" do
      valid_until = 2.days.from_now.change(usec: 0)
      tool.call_with_schema_validation!(
        operations: [ {
          type: "create_observation", entity_id: entity.id, text_content: "Alpha Service runs nightly",
          source: "claude-code/opus: release task", confidence: 0.8, valid_until: valid_until.iso8601,
          tags: [ "x" ], perspective: "experience"
        } ]
      )

      observation = entity.memory_observations.sole
      expect(observation).to have_attributes(
        source: "claude-code/opus: release task", confidence: 0.8, tags: [ "x" ], perspective: "experience"
      )
      expect(observation.valid_until).to eq(valid_until)
    end

    it "stores create_entity aliases from an array as a deduplicated pipe-separated list" do
      expect(operation_properties).to include(aliases: include(type: "array", items: { type: "string" }))

      tool.call_with_schema_validation!(
        operations: [ { type: "create_entity", name: "Alpha Service", entity_type: "Service", aliases: [ "Alpha", " alpha ", "α-svc" ] } ]
      )

      expect(MemoryEntity.find_by!(name: "Alpha Service").aliases).to eq("Alpha|α-svc")
    end

    it "rejects non-string create_entity aliases, with the operation index, and creates nothing" do
      [ [ { "a" => 1 } ], { "a" => 1 }, [ [ "x" ] ], [ "ok", { "a" => 1 } ] ].each do |aliases|
        expect do
          tool.call_with_schema_validation!(
            operations: [ { type: "create_entity", name: "Alpha Service", entity_type: "Service", aliases: aliases } ]
          )
        end.to raise_error(
          FastMcp::Tool::InvalidArgumentsError, /create_entity\[0\]: aliases must be an array of strings\./
        )
      end
      expect(MemoryEntity.where(name: "Alpha Service")).not_to exist
    end

    it "rejects a create_entity alias that contains the pipe separator" do
      expect do
        tool.call_with_schema_validation!(
          operations: [ { type: "create_entity", name: "Alpha Service", entity_type: "Service", aliases: [ "A|B" ] } ]
        )
      end.to raise_error(FastMcp::Tool::InvalidArgumentsError, /contains "\|"/)
      expect(MemoryEntity.where(name: "Alpha Service")).not_to exist
    end

    it "rejects a confidence outside 0..1" do
      expect do
        tool.call_with_schema_validation!(
          operations: [ { type: "create_observation", entity_id: entity.id, text_content: "Too sure", confidence: 1.5 } ]
        )
      end.to raise_error(/Confidence/i)
      expect(entity.memory_observations).to be_empty
    end
  end
end
