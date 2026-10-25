# frozen_string_literal: true

require "rails_helper"

# What each profile advertises (tools/list, prompts/list, resources/templates/list), byte for byte as
# recorded on graph_mem 1.55.0 in spec/fixtures/mcp/snapshots/ (mg-streamlined-plan.md, PR B). A
# change to a tool's name, description, schema or annotations, a prompt, or a resource template
# fails here. If the change is intended, re-record the snapshots and say so in the PR.
RSpec.describe "MCP list snapshots" do
  list_methods = %w[tools/list prompts/list resources/templates/list]

  %i[default readonly maintenance].each do |profile|
    it "matches the recorded #{profile} profile" do
      server = GraphMem::OfficialMcp::ServerFactory.for(profile)
      current = list_methods.to_h do |method|
        [ method, JSON.parse(JSON.generate(server.handle({ jsonrpc: "2.0", id: 1, method: method })))["result"] ]
      end

      expect(JSON.pretty_generate(current) + "\n").to eq(Rails.root.join("spec/fixtures/mcp/snapshots/#{profile}.json").read)
    end
  end
end
