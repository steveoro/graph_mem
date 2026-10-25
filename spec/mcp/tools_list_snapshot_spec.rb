# frozen_string_literal: true

require "rails_helper"

# What each profile advertises (tools/list, prompts/list, resources/templates/list), byte for byte as
# recorded on graph_mem 1.55.0 in spec/fixtures/mcp/snapshots/ (mg-streamlined-plan.md, PR B). A
# change to a tool's name, description, schema or annotations, a prompt, or a resource template
# fails here. If the change is intended, re-record the snapshots and say so in the PR.
#
# Each list is sorted by name on both sides first: the server lists classes in load order, which
# depends on which specs ran before (it did on 1.55.0 too).
RSpec.describe "MCP list snapshots" do
  list_methods = %w[tools/list prompts/list resources/templates/list]

  def sorted(snapshot)
    snapshot.transform_values do |result|
      result.transform_values { |items| items.is_a?(Array) ? items.sort_by { |item| item["name"].to_s } : items }
    end
  end

  %i[default readonly maintenance].each do |profile|
    it "matches the recorded #{profile} profile" do
      server = GraphMem::OfficialMcp::ServerFactory.for(profile)
      current = list_methods.to_h do |method|
        [ method, JSON.parse(JSON.generate(server.handle({ jsonrpc: "2.0", id: 1, method: method })))["result"] ]
      end

      recorded = JSON.parse(Rails.root.join("spec/fixtures/mcp/snapshots/#{profile}.json").read)
      expect(JSON.pretty_generate(sorted(current))).to eq(JSON.pretty_generate(sorted(recorded)))
    end
  end
end
