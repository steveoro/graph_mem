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

    it "records the session id when one is supplied" do
      described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-1")

      expect(described_class.find_by!(client_id: "cursor-A").last_session_id).to eq("sess-1")
    end

    it "keeps the previous session id when none is supplied" do
      described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-1")
      described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context")

      expect(described_class.find_by!(client_id: "cursor-A").last_session_id).to eq("sess-1")
    end

    it "flags a concurrent session on the returned record" do
      described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-1")

      record = described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-2")

      expect(record.concurrent_session).to be(true)
    end

    it "does not flag the same session calling twice" do
      described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-1")

      record = described_class.record_activity!(client_id: "cursor-A", tool_name: "get_context", session_id: "sess-1")

      expect(record.concurrent_session).to be(false)
    end

    it "does not flag a first-ever call" do
      record = described_class.record_activity!(client_id: "fresh", tool_name: "get_context", session_id: "sess-1")

      expect(record.concurrent_session).to be(false)
    end
  end

  describe "#concurrent_session?" do
    let(:ctx) do
      described_class.create!(client_id: "cursor-A", last_session_id: "sess-1", last_seen_at: 1.minute.ago)
    end

    it "is true for a different session inside the conflict window" do
      expect(ctx.concurrent_session?("sess-2")).to be(true)
    end

    it "is false for the same session" do
      expect(ctx.concurrent_session?("sess-1")).to be(false)
    end

    it "is false once the window has passed" do
      ctx.update!(last_seen_at: (described_class::CONFLICT_WINDOW + 1.minute).ago)

      expect(ctx.concurrent_session?("sess-2")).to be(false)
    end

    it "is false when no session id is available, as on the legacy endpoint" do
      expect(ctx.concurrent_session?(nil)).to be(false)
      expect(ctx.concurrent_session?("")).to be(false)
    end

    it "is false when nothing was recorded before" do
      fresh = described_class.create!(client_id: "fresh", last_seen_at: 1.minute.ago)

      expect(fresh.concurrent_session?("sess-2")).to be(false)
    end
  end

  describe "#context_conflict_with?" do
    let(:project_a) { MemoryEntity.create!(name: "Project A", entity_type: "Project") }
    let(:project_b) { MemoryEntity.create!(name: "Project B", entity_type: "Project") }

    def context_for(project, set_at:)
      described_class.create!(client_id: "cursor-A", current_project: project, context_set_at: set_at)
    end

    it "is true when switching away from a project set moments ago" do
      ctx = context_for(project_a, set_at: 1.minute.ago)

      expect(ctx.context_conflict_with?(project_b.id)).to be(true)
    end

    it "is false when re-setting the same project" do
      ctx = context_for(project_a, set_at: 1.minute.ago)

      expect(ctx.context_conflict_with?(project_a.id)).to be(false)
    end

    it "is false once the window has passed" do
      ctx = context_for(project_a, set_at: (described_class::CONFLICT_WINDOW + 1.minute).ago)

      expect(ctx.context_conflict_with?(project_b.id)).to be(false)
    end

    it "is false when no project was active" do
      ctx = described_class.create!(client_id: "cursor-A", context_set_at: 1.minute.ago)

      expect(ctx.context_conflict_with?(project_b.id)).to be(false)
    end

    it "is false when the context was never explicitly set" do
      ctx = described_class.create!(client_id: "cursor-A", current_project: project_a)

      expect(ctx.context_conflict_with?(project_b.id)).to be(false)
    end
  end
end
