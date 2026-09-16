# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolUsageReport do
  after { ToolInvocation.delete_all }

  def create_invocation(tool_name:, duration_ms:, outcome: "ok", error_category: nil, created_at: Time.current)
    ToolInvocation.create!(
      tool_name: tool_name,
      client_id: "report-spec-#{SecureRandom.hex(4)}",
      outcome: outcome,
      error_class: ("SpecError" if outcome == "error"),
      error_category: error_category,
      duration_ms: duration_ms,
      argument_keys: [],
      created_at: created_at
    )
  end

  describe ".call" do
    it "reports counts, shares, errors, percentiles, and never-called tools" do
      create_invocation(tool_name: "search_entities", duration_ms: 10)
      create_invocation(tool_name: "search_entities", duration_ms: 20)
      create_invocation(tool_name: "search_entities", duration_ms: 30)
      create_invocation(
        tool_name: "search_entities",
        duration_ms: 100,
        outcome: "error",
        error_category: "validation"
      )
      create_invocation(tool_name: "get_context", duration_ms: 5)
      create_invocation(tool_name: "search_entities", duration_ms: 999, created_at: 31.days.ago)

      report = described_class.call(
        since: 30.days.ago,
        tool_names: %w[get_context never_called search_entities]
      )

      search = report[:tools].find { |row| row[:tool_name] == "search_entities" }
      expect(report[:total_calls]).to eq(5)
      expect(search).to include(
        call_count: 4,
        share_percent: 80.0,
        error_count: 1,
        error_rate_percent: 25.0,
        errors_by_category: { "validation" => 1 },
        p50_ms: 20,
        p95_ms: 100
      )

      never_called = report[:tools].find { |row| row[:tool_name] == "never_called" }
      expect(never_called).to include(
        call_count: 0,
        share_percent: 0.0,
        error_count: 0,
        error_rate_percent: 0.0,
        p50_ms: nil,
        p95_ms: nil
      )
    end

    it "includes observed legacy names outside the current registry" do
      create_invocation(tool_name: "legacy_alias", duration_ms: 7)

      report = described_class.call(since: 1.day.ago, tool_names: [ "get_context" ])

      expect(report[:tools].map { |row| row[:tool_name] }).to contain_exactly("get_context", "legacy_alias")
    end

    it "supports reporting over all recorded history" do
      create_invocation(tool_name: "search_entities", duration_ms: 11, created_at: 1.year.ago)

      report = described_class.call(since: nil, tool_names: [ "search_entities" ])

      expect(report[:total_calls]).to eq(1)
    end

    it "uses the registered tool catalog by default" do
      allow(GraphMem::McpToolRegistry).to receive(:load_all!)
      allow(GraphMem::McpToolRegistry).to receive(:tool_classes).and_return([ SearchEntitiesTool ])

      report = described_class.call(since: 1.day.ago)

      expect(report[:tools].map { |row| row[:tool_name] }).to eq([ "search_entities" ])
    end
  end
end
