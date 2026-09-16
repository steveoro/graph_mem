# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolInvocation, type: :model do
  def build_invocation(**attributes)
    described_class.new(
      {
        tool_name: "search_entities",
        client_id: "cursor-test",
        outcome: "ok",
        duration_ms: 12,
        argument_keys: [ "limit", "query" ],
        created_at: Time.current
      }.merge(attributes)
    )
  end

  describe "validations" do
    it "accepts a valid invocation" do
      expect(build_invocation).to be_valid
    end

    it "only accepts known outcomes" do
      expect(build_invocation(outcome: "unknown")).not_to be_valid
    end

    it "rejects negative sizes and durations" do
      invocation = build_invocation(duration_ms: -1, result_size: -1)

      expect(invocation).not_to be_valid
      expect(invocation.errors).to include(:duration_ms, :result_size)
    end

    it "requires argument keys to be an array of strings" do
      expect(build_invocation(argument_keys: { query: true })).not_to be_valid
      expect(build_invocation(argument_keys: [ 1 ])).not_to be_valid
      expect(build_invocation(argument_keys: [])).to be_valid
    end
  end

  describe ".since" do
    it "returns invocations at or after the supplied time" do
      recent = build_invocation(created_at: 1.hour.ago).tap(&:save!)
      old = build_invocation(created_at: 2.days.ago).tap(&:save!)

      expect(described_class.since(1.day.ago)).to contain_exactly(recent)
      expect(described_class.since(1.day.ago)).not_to include(old)
    end
  end

  describe ".errors" do
    it "returns only failed invocations" do
      successful = build_invocation.tap(&:save!)
      failed = build_invocation(outcome: "error", error_category: "validation").tap(&:save!)

      expect(described_class.errors).to contain_exactly(failed)
      expect(described_class.errors).not_to include(successful)
    end
  end
end
