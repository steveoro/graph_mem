# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolTelemetryDashboardSnapshot do
  def create_invocation(**attributes)
    ToolInvocation.create!(
      {
        tool_name: "search",
        client_id: "cursor",
        outcome: "ok",
        duration_ms: 20,
        result_size: 3,
        argument_keys: %w[limit query],
        created_at: Time.current
      }.merge(attributes)
    )
  end

  it "builds filtered summary, trend, and analytics breakdowns" do
    create_invocation
    create_invocation(
      client_id: "claude",
      outcome: "error",
      error_category: "validation",
      error_class: "InvalidArguments",
      duration_ms: 100,
      argument_keys: [ "query" ],
      created_at: 1.hour.ago
    )
    create_invocation(client_id: "old", created_at: 31.days.ago)

    snapshot = described_class.call(filters: { since_days: "30", tool_name: "search" })

    expect(snapshot[:summary]).to include(
      total_calls: 2,
      error_count: 1,
      error_rate_percent: 50.0,
      active_clients: 2,
      p95_ms: 100
    )
    expect(snapshot[:tools].sole).to include(tool_name: "search", call_count: 2)
    expect(snapshot[:clients].map { |row| row[:client_id] }).to contain_exactly("cursor", "claude")
    expect(snapshot[:errors].sole).to include(
      category: "validation",
      error_class: "InvalidArguments",
      count: 1
    )
    expect(snapshot[:argument_signatures]).to include(
      include(argument_keys: %w[limit query], count: 1),
      include(argument_keys: [ "query" ], count: 1)
    )
    expect(snapshot[:series].sum { |point| point[:calls] }).to eq(2)
  end

  it "uses hourly buckets for the 24-hour period" do
    create_invocation(created_at: 1.hour.ago)

    snapshot = described_class.call(filters: { since_days: "1" })

    expect(snapshot[:series].size).to eq(25)
    expect(snapshot[:series]).to all(include(:key, :label, :calls, :errors))
  end
end
