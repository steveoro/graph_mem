# frozen_string_literal: true

require "rails_helper"
require "json-schema"

RSpec.describe GraphMem::McpOutputSchemas do
  DEFAULT_TOOLS = %w[
    get_context set_context search get_entities traverse_graph find_shortest_path
    summarize rank_observations graph_write graph_edit graph_delete get_current_time
  ].freeze

  it "defines one post-envelope schema for every default tool" do
    expect(described_class::TOOL_BODIES.keys).to match_array(DEFAULT_TOOLS)

    DEFAULT_TOOLS.each do |tool_name|
      schema = described_class.for(tool_name)
      expect(schema).to include(type: "object", additionalProperties: true)
      expect(schema[:required]).to include("version")
      expect(schema.dig(:properties, :next_move, :type)).to include("string", "null")
    end
  end

  it "uses discriminated branches for polymorphic tools" do
    %w[get_context set_context search traverse_graph graph_write].each do |tool_name|
      expect(described_class.for(tool_name)[:oneOf]).to be_present
    end
  end

  it "does not assign schemas to maintenance-only or hidden tools yet" do
    expect(described_class.for("dream_state_status")).to be_nil
    expect(described_class.for("get_version")).to be_nil
  end

  it "accepts representative post-envelope payloads for all 12 tools" do
    logical_results = {
      "get_context" => { status: "no_context" },
      "set_context" => { status: "context_set" },
      "search" => { mode: "catalog", entities: [], pagination: {} },
      "get_entities" => {
        entities: [], relations: [], missing_entity_ids: [], relation_scope: "all"
      },
      "traverse_graph" => { entities: [], relations: [] },
      "find_shortest_path" => {
        found: false, hop_count: nil, direction: "outgoing", entities: [], relations: []
      },
      "summarize" => { query: "GraphMem", summary: "Summary" },
      "rank_observations" => { entity_id: 1, observations: [] },
      "graph_write" => { mode: "batch", status: "ok", results: [], summary: {} },
      "graph_edit" => { mode: "batch", status: "ok", results: [], summary: {} },
      "graph_delete" => { mode: "batch", status: "ok", results: [], summary: {} },
      "get_current_time" => { timestamp: Time.current.iso8601 }
    }
    context = double(active?: false)

    logical_results.each do |tool_name, logical_result|
      payload, = ToolSuccessResponse.call(
        tool_name: tool_name,
        result: logical_result,
        context: context
      )
      json_payload = JSON.parse(JSON.generate(payload))
      errors = JSON::Validator.fully_validate(described_class.for(tool_name), json_payload)

      expect(errors).to be_empty, "#{tool_name}: #{errors.join(', ')}"
    end
  end
end
