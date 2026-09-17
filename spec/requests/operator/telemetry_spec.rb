# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator telemetry", type: :request do
  def create_invocation(**attributes)
    ToolInvocation.create!(
      {
        tool_name: "search",
        client_id: "cursor",
        outcome: "ok",
        duration_ms: 25,
        result_size: 2,
        argument_keys: %w[limit query],
        created_at: Time.current
      }.merge(attributes)
    )
  end

  around do |example|
    previous = AppSettings.tool_invocation_retention_days
    example.run
  ensure
    AppSettings.tool_invocation_retention_days = previous
  end

  it "requires operator authentication" do
    get operator_telemetry_path

    expect(response).to redirect_to(operator_login_path)
  end

  it "renders analytics, charts, breakdowns, and privacy-safe details" do
    sign_in_operator
    create_invocation
    create_invocation(
      client_id: "claude",
      outcome: "error",
      error_category: "validation",
      error_class: "InvalidArguments",
      duration_ms: 100,
      argument_keys: [ "query" ]
    )

    get operator_telemetry_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      'data-testid="operator-telemetry-dashboard"',
      'id="telemetry-trend-title"',
      'id="telemetry-tools-table"',
      'id="telemetry-clients-table"',
      'id="telemetry-errors-table"',
      'id="telemetry-argument-signatures-table"',
      'id="telemetry-invocations-table"',
      "Only argument names are recorded; values are never stored.",
      "Requests rejected before tool dispatch"
    )
  end

  it "filters invocation details and aggregates consistently" do
    sign_in_operator
    matching = create_invocation(tool_name: "get_context", client_id: "cursor")
    excluded = create_invocation(tool_name: "search", client_id: "claude")

    get operator_telemetry_path,
        params: { since_days: "7", tool_name: "get_context", client_id: "cursor" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("tool-invocation-#{matching.id}", "get_context")
    expect(response.body).not_to include("tool-invocation-#{excluded.id}")
  end

  it "paginates raw invocation details" do
    sign_in_operator
    51.times { |index| create_invocation(client_id: "client-#{index}") }

    get operator_telemetry_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("page=2")
  end

  it "prunes only telemetry outside the configured retention" do
    sign_in_operator
    AppSettings.tool_invocation_retention_days = 90
    old = create_invocation(created_at: 91.days.ago)
    recent = create_invocation(created_at: 1.day.ago)

    post operator_prune_telemetry_path, params: { since_days: "30" }

    expect(response).to redirect_to(operator_telemetry_path(since_days: "30"))
    expect(ToolInvocation.exists?(old.id)).to be(false)
    expect(ToolInvocation.exists?(recent.id)).to be(true)
  end
end
