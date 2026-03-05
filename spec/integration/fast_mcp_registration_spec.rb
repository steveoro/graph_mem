# frozen_string_literal: true

require "rails_helper"

RSpec.describe "FastMcp tool registration", type: :integration do
  EXPECTED_TOOL_NAMES = %w[
    bulk_update
    clear_context
    create_entity
    create_observation
    create_relation
    delete_entity
    delete_observation
    delete_relation
    find_relations
    get_context
    get_current_time
    get_entity
    get_graph_stats
    get_subgraph_by_ids
    get_version
    list_entities
    search_entities
    search_subgraph
    set_context
    suggest_merges
    update_entity
  ].freeze

  # Filter out test-only tool subclasses defined in other spec files
  let(:real_tool_classes) do
    ApplicationTool.descendants.reject { |k| k.name.nil? || k.name.match?(/TestTool$/) }
  end

  describe "tool discovery" do
    it "finds all #{EXPECTED_TOOL_NAMES.length} real tool classes as ApplicationTool descendants" do
      registered_names = real_tool_classes.map(&:tool_name).sort
      expect(registered_names).to match_array(EXPECTED_TOOL_NAMES)
    end
  end

  describe "tool metadata" do
    ApplicationTool.descendants
      .reject { |k| k.name.nil? || k.name.to_s.match?(/TestTool$/) }
      .each do |tool_class|
        context tool_class.tool_name do
          let(:tool) { tool_class.new }

          it "has a non-blank tool_name" do
            expect(tool_class.tool_name).to be_present
          end

          it "has a non-blank description" do
            expect(tool.description).to be_present
            expect(tool.description.length).to be > 5
          end

          it "returns a valid input_schema_to_json hash from the instance" do
            schema = tool.input_schema_to_json
            expect(schema).to be_a(Hash)
            expect(schema).to have_key(:type)
          end

          it "has a resolvable input_schema" do
            schema = tool_class.input_schema
            expect(schema).to respond_to(:call)
          end
        end
      end
  end

  describe "BulkUpdateTool schema override" do
    it "exposes entities, observations, and relations via class-level input_schema_to_json" do
      schema = BulkUpdateTool.input_schema_to_json
      expect(schema[:properties]).to have_key(:entities)
      expect(schema[:properties]).to have_key(:observations)
      expect(schema[:properties]).to have_key(:relations)
    end
  end
end
