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
end
