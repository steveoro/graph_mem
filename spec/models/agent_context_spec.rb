# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentContext, type: :model do
  after { described_class.delete_all }

  describe "validations" do
    it "requires client_id" do
      ctx = described_class.new(client_id: nil)
      expect(ctx).not_to be_valid
      expect(ctx.errors[:client_id]).to be_present
    end

    it "requires unique client_id" do
      described_class.create!(client_id: "cursor-A")
      duplicate = described_class.new(client_id: "cursor-A")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:client_id]).to be_present
    end
  end

  describe "associations" do
    it "optionally belongs to a current_project MemoryEntity" do
      project = MemoryEntity.create!(name: "CtxProject", entity_type: "Project")
      ctx = described_class.create!(client_id: "cursor-A", current_project: project)

      expect(ctx.current_project).to eq(project)
    end
  end

  describe "#touch_last_seen!" do
    it "updates last_seen_at without touching updated_at validations" do
      ctx = described_class.create!(client_id: "cursor-A", last_seen_at: 1.day.ago)
      ctx.touch_last_seen!

      expect(ctx.reload.last_seen_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe ".record_activity!" do
    it "creates a context row and stores last tool activity" do
      described_class.record_activity!(client_id: "cursor-A", tool_name: "search_entities")

      ctx = described_class.find_by!(client_id: "cursor-A")
      expect(ctx.last_tool_name).to eq("search_entities")
      expect(ctx.last_seen_at).to be_within(2.seconds).of(Time.current)
    end

    it "normalizes blank client ids to default" do
      described_class.record_activity!(client_id: "  ", tool_name: "get_context")

      expect(described_class.find_by!(client_id: GraphMemContext::DEFAULT_CLIENT_ID).last_tool_name).to eq("get_context")
    end

    it "updates an existing context row" do
      ctx = described_class.create!(client_id: "cursor-A", last_tool_name: "get_context", last_seen_at: 1.day.ago)

      described_class.record_activity!(client_id: "cursor-A", tool_name: "create_entity")

      ctx.reload
      expect(ctx.last_tool_name).to eq("create_entity")
      expect(ctx.last_seen_at).to be_within(2.seconds).of(Time.current)
    end
  end
end
