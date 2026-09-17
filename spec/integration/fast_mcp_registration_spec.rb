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
    detect_contradictions
    dream_state_status
    find_relations
    find_shortest_path
    get_context
    get_current_time
    get_entity
    get_entities
    get_graph_stats
    get_maintenance_reports
    get_subgraph_by_ids
    get_version
    graph_delete
    graph_edit
    graph_write
    list_entities
    list_maintenance_review
    merge_entities
    rank_observations
    search_entities
    search_subgraph
    summarize
    set_context
    suggest_merges
    traverse_graph
    update_entity
    update_observation
    apply_maintenance_review
    dismiss_maintenance_review
    scan_project
    scan_project_status
    search
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

          it "returns a valid input_schema_to_json hash from the class" do
            schema = tool_class.input_schema_to_json
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

  describe "profile and annotation metadata" do
    it "declares complete metadata on every production tool" do
      real_tool_classes.each do |tool_class|
        expect(tool_class.mcp_profiles).not_to be_empty, "#{tool_class.name} has no MCP profiles"
        expect(tool_class.mcp_profiles).to all(be_in(ApplicationTool::MCP_PROFILE_NAMES))
        expect(tool_class.mcp_advertised?).to be_in([ true, false ])
        expect(tool_class.annotations.keys).to match_array(ApplicationTool::MCP_ANNOTATION_KEYS)
        expect(tool_class.annotations.values).to all(be_in([ true, false ]))
      end
    end

    it "marks compatibility aliases as hidden" do
      hidden_names = real_tool_classes.reject(&:mcp_advertised?).map(&:tool_name)

      expect(hidden_names).to match_array(
        %w[
          bulk_update clear_context create_entity create_observation create_relation delete_entity
          delete_observation delete_relation find_relations get_entity get_subgraph_by_ids get_version list_entities merge_entities
          search_entities search_subgraph update_entity update_observation
        ]
      )
    end

    it "assigns the expected number of tools to each profile" do
      profile_counts = ApplicationTool::MCP_PROFILE_NAMES.index_with do |profile|
        real_tool_classes.count { |tool_class| profile.in?(tool_class.mcp_profiles) }
      end

      expect(profile_counts).to eq(default: 30, readonly: 17, maintenance: 40)
    end

    it "advertises only canonical tools in each profile" do
      advertised_counts = ApplicationTool::MCP_PROFILE_NAMES.index_with do |profile|
        real_tool_classes.count do |tool_class|
          tool_class.mcp_advertised? && profile.in?(tool_class.mcp_profiles)
        end
      end

      expect(advertised_counts).to eq(default: 12, readonly: 9, maintenance: 22)
    end

    it "describes the non-obvious side effects accurately" do
      expect(GetContextTool.annotations).to include(read_only_hint: false, destructive_hint: false)
      expect(SummarizeTool.annotations).to include(read_only_hint: true, open_world_hint: true)
      expect(DetectContradictionsTool.annotations).to include(read_only_hint: false, destructive_hint: false)
      expect(ScanProjectTool.annotations).to include(destructive_hint: true, open_world_hint: true)
      expect(ApplyMaintenanceReviewTool.annotations).to include(destructive_hint: true)
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
