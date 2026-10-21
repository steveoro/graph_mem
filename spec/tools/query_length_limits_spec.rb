# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Query length limits across MCP tools" do
  tools_with_query = [
    SearchTool,
    SearchEntitiesTool,
    SearchSubgraphTool,
    GetEntitiesTool,
    GetEntityTool,
    RankObservationsTool
  ]

  tools_with_query.each do |tool_class|
    describe tool_class do
      it "advertises maxLength 2048 on the :query argument" do
        schema = tool_class.input_schema_to_json
        expect(schema.dig(:properties, :query, :maxLength)).to eq(2048)
      end
    end
  end
end
