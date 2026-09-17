# Operator tool telemetry

Use the telemetry dashboard to inspect MCP tool volume, reliability, latency,
client activity, and privacy-safe argument signatures.

## Open the dashboard

1. Sign in at `/operator/login`.
2. Open **Tool Telemetry** in the operator navigation.
3. Select a 24-hour, 7-day, 30-day, or 90-day window.
4. Optionally filter by exact tool name, client ID, outcome, or error category.

The summary chips, trend chart, breakdown tables, and invocation list all use
the same filters. Latency percentiles are bounded to the most recent 100,000
matching calls; call and error counts remain exact.

## Reading the metrics

- **Calls** counts tool execution attempts that reached schema validation.
- **Error rate** includes validation and execution errors recorded by the tool
  wrapper.
- **p50/p95** describe recorded execution duration in milliseconds.
- **Result size** is a coarse item/key count, not response bytes.
- **Argument signatures** contain sorted argument names only.

Requests rejected before tool dispatch, including unauthorized calls, are not
part of tool invocation telemetry. The dashboard states this explicitly so its
error rate is not mistaken for an access-control rejection rate.

## Privacy

GraphMem never stores argument values in `tool_invocations`. It stores the
client ID, tool name, outcome, duration, result size, optional scope, error
classification, and the list of top-level argument keys.

## Retention and pruning

The **Telemetry** System Settings tab controls
`tool_invocation_retention_days`. The default is 90 days; set it to `0` to
disable automatic deletion.

Production garbage collection prunes expired telemetry daily. The dashboard
also offers **Prune expired telemetry** when expired rows exist.

## CLI and console equivalents

Run reports through the project RVM gemset:

```bash
DAYS=30 bundle exec rake graph_mem:tool_usage
DAYS=7 bundle exec rake graph_mem:tool_usage
DAYS=all bundle exec rake graph_mem:tool_usage
```

From a Rails console:

```ruby
ToolUsageReport.call(since: 30.days.ago)
ToolTelemetryDashboardSnapshot.call(filters: { since_days: "7", outcome: "error" })
```
