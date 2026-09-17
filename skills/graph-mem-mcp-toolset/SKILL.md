---
name: graph-mem-mcp-toolset
description: Use the graph_mem MCP toolset with a repeatable 4-phase workflow (orient, recall, work, persist), schema-first tool invocation, and dedup-safe entity management. Use when the user mentions graph_mem, memory graph, knowledge graph, MCP memory tools, or asks to store/retrieve project context.
---

# Graph Mem MCP Toolset

Use this skill to operate `graph_mem` reliably and consistently. The repository
documentation under `docs/` is the detailed reference; this skill is the
short operational checklist for an agent.

Tool names below (`get_context`, `search`, ...) are graph_mem's
server-side tool names. Invoke them through whatever mechanism your host uses
for MCP tools — direct tool calls, `mcp__graph_mem__<tool>`-style names, or a
generic wrapper such as `CallMcpTool` or `mcp_call_tool`. The server name in
your MCP config may differ (`graph_mem`, `user-graph_mem`, ...); that is a
client-side label, not part of the tool contract.

## Quick Start

1. **Schema first**
   - Before invoking a `graph_mem` tool, fetch its exact schema via your
     host's MCP tool listing.
   - Validate required parameters and constraints from the returned schema.
   - Do not infer a schema from an old example or from a different MCP server.

2. **Follow the 4-phase workflow**
   - Orient -> Recall -> Work -> Persist.

3. **Search before create**
   - Always run `search` before `graph_write` to avoid duplicates.

4. **Choose the smallest connection profile**
   - `/mcp` exposes ordinary context, read, and graph-write tools.
   - `/mcp/readonly` exposes context and read tools.
   - `/mcp/maintenance` exposes the full catalog. Use it only for explicit
     maintenance work.

## Tool Discovery And Schema Rule

Before calling any `graph_mem` tool for the first time in a session:

1. Confirm the server is reachable by listing your host's MCP tools.
2. Fetch the exact tool schema and check its required arguments.
3. If your host reports the server needs authentication, complete the host's
   MCP auth flow once, then list the tools again.
4. Only then invoke the tool.

## Workflow Prompts

Use the server-provided prompts for procedural guidance:

- `orient` at session start
- `recall(topic)` before implementation
- `persist` before the final response

Successful tool results provide a concise `next_move`; follow it when relevant.

## Multi-Agent & Dream-State Awareness

- Context is per-agent, keyed by the `X-MCP-Client` header and persisted in the DB. `set_context` affects only your own bucket; pass `entity_id: null` to clear it. Agents without the header share `"default"`.
- A background dream-state job auto-parents orphans, auto-merges near-identical
  entities (cosine < 0.10), and dedupes identical observations. Lower-confidence
  cases are queued for review.
- Maintenance tools are available on `/mcp/maintenance`, not the default connection.
- `dream_state_status` reports whether compaction is running/paused plus stats.
- `list_maintenance_review` returns queued merge/orphan rows; action good ones with `apply_maintenance_review` (or a `graph_delete` `merge_entities` operation when both entity ids are known). Use `get_maintenance_reports` for stored report documents, not row pagination.
- Mutating tools auto-pause compaction, so no coordination is needed — but
  search results may shift slightly mid-run.

## Parameter Compatibility

graph_mem accepts both native and MCP-memory-style forms:

- `entity_type` and `entityType`
- ID or name references for entities
- `text_content`, `content`, or `contents` for observations
- `graph_write` via:
  - native arrays (`entities`, `observations`, `relations`), or
  - `operations` array (type-discriminated items)
- `graph_edit` and `graph_delete` accept type-discriminated `operations`
  arrays.

Default recommendation: use native snake_case keys unless compatibility with external payloads is needed.

## Query and Type Guidance

Use the `recall` prompt for query strategy. `graph_write` publishes canonical
entity and relation type examples in its schema while accepting novel types.

## Quality Guardrails

- Never skip schema checks before tool calls.
- On MCP `isError`, parse the JSON envelope (`category`, `retriable`, `next_move`)
  and follow `next_move`. Do not retry `system_error` blindly.
- Never create duplicate project entities without searching first.
- Keep entries concise, factual, and reusable.
- Prefer updating existing entities over creating near-duplicates.
- Record blockers as `Issue` and link confirmed fixes as `PossibleSolution`.
- Treat only active observations as current by default; preserve uncertainty
  and conflicting facts rather than silently choosing one.
- Treat `summarize` output as on-demand and source-backed. Source IDs are
  assigned by GraphMem, not trusted from generated text.
- Expect deterministic fallback when synthesis is disabled, unconfigured, or
  unavailable; do not retry a failed provider indefinitely.
