# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentContextsSnapshot do
  after { AgentContext.delete_all; GraphMemContext.clear_all! }

  describe ".call" do
    it "returns summary and client rows ordered by recent activity" do
      project = MemoryEntity.create!(name: "Goggles DB", entity_type: "Project")
      AgentContext.create!(
        client_id: "cursor-goggles",
        current_project: project,
        last_seen_at: 2.minutes.ago,
        last_tool_name: "set_context"
      )
      AgentContext.create!(
        client_id: "cursor-admin",
        last_seen_at: 30.minutes.ago,
        last_tool_name: "get_context"
      )

      result = described_class.call

      expect(result[:summary]).to include(
        total: 2,
        recent_count: 1,
        with_context_count: 1,
        default_bucket: false
      )
      expect(result[:clients].map { |row| row[:client_id] }).to eq(%w[cursor-goggles cursor-admin])
      expect(result[:clients].first[:project]).to eq(
        id: project.id,
        name: "Goggles DB",
        entity_type: "Project"
      )
      expect(result[:clients].first[:activity_status]).to eq("active")
      expect(result[:clients].second[:activity_status]).to eq("idle")
    end

    it "flags the default bucket when present" do
      AgentContext.create!(client_id: GraphMemContext::DEFAULT_CLIENT_ID, last_seen_at: 1.day.ago)

      result = described_class.call

      expect(result[:summary][:default_bucket]).to be true
      expect(result[:clients].first[:shared_default_bucket]).to be true
    end

    it "returns an empty client list when no contexts exist" do
      result = described_class.call

      expect(result[:summary][:total]).to eq(0)
      expect(result[:clients]).to eq([])
    end
  end
end
