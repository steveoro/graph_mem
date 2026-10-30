# frozen_string_literal: true

require "rails_helper"

# Audit actor (1.65.0): the wrapper reads the MCP session's clientInfo for the claim, and keeps
# only a Hash.
RSpec.describe GraphMem::OfficialMcp::ToolWrapper do
  describe ".client_info" do
    it "reads a Hash from the server context and ignores everything else" do
      context = Struct.new(:client_info)

      expect(described_class.client_info(context.new({ name: "synth-agent", version: "0.0.1" }))).to eq(name: "synth-agent", version: "0.0.1")
      expect(described_class.client_info(context.new("synth-agent"))).to be_nil
      expect(described_class.client_info(context.new(nil))).to be_nil
      expect(described_class.client_info(nil)).to be_nil
      expect(described_class.client_info({ auth_info: nil })).to be_nil
    end
  end

  it "hands the clientInfo and the client id to the tool, which sets the claim for the call" do
    seen = nil
    allow_any_instance_of(SearchTool).to receive(:call) do
      seen = [ Current.actor, Current.actor_claim ]
      { results: [] }
    end
    request = GraphMem::OfficialMcp::RequestContext::Context.new(client_id: "synth-client-a", profile: :default, session_id: nil, client_info: nil)
    server_context = Struct.new(:client_info, :auth_info) do
      def [](key) = key == :auth_info ? auth_info : nil
    end.new({ name: "synth-agent", version: "0.0.1" },
            MCP::Server::OAuth::AccessToken.new(token: "graph_mem", claims: { GraphMem::OfficialMcp::RequestContext::CLAIM => request }))

    described_class.build(SearchTool).call(server_context: server_context, query: "SynthWidget")

    expect(seen).to eq([ "mcp:search", "client=synth-client-a · synth-agent/0.0.1" ])
    expect([ Current.actor, Current.actor_claim ]).to eq([ nil, nil ])
  end
end
