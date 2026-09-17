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

## 4-Phase Session Workflow

## Phase 1 - Orient (start of session)

1. Say `Remembering...`.
2. Call `get_context`. Context is per-agent and persisted, so you may already have one from a prior session.
3. If no context:
   - Run `search` for the project name.
   - If found, call `set_context(<id or name>)`.
   - If not found, call `create_entity(name:, entity_type: "Project")`, then `set_context`.

## Phase 2 - Recall (before implementation)

1. Run `search` with task keywords.
2. Inspect one or more known matches with `get_entities`.
3. Use `traverse_graph` for bounded multi-hop exploration or
   `find_shortest_path` to explain how two entities connect.
4. Use `summarize` for a source-backed answer to a knowledge question; use
   direct search/traversal when exact graph structure is needed.
5. Prioritize `Issue` + `PossibleSolution`, `BestPractice`, and `Preference`
   entities.

## Phase 3 - Work

1. Execute the requested task using recalled knowledge.
2. If blocked or uncertain, query graph_mem again mid-task:
   - `search` for new clues.
   - `traverse_graph` for immediate edges or a bounded neighborhood.
   - `find_shortest_path` for connectivity between known entities.

## Phase 4 - Persist (before final response)

1. Write newly learned facts with a `graph_write` `create_observation`
   operation.
   - Use a `graph_edit` `update_observation` operation for corrections.
   - Set `supersede: true` when retaining the prior version matters.
   - Use a `graph_delete` `delete_observation` operation to mark a fact
     obsolete rather than hard-delete it.
   - Search or load the entity first and do not restate an existing fact.
2. For new concepts:
   - Add `create_entity` operations to `graph_write`.
   - Add `create_relation` operations with a specific relation type.
3. For batch updates, prefer `graph_write` (max 50 operations).
4. Routine duplicate compaction is handled by the background dream-state job. On a maintenance-profile connection, confirm spotted duplicates with `suggest_merges`, then execute a `graph_delete` `merge_entities` operation.
5. Call `clear_context` only when project scope is no longer relevant (safe: affects only your own client bucket).

## Multi-Agent & Dream-State Awareness

- Context is per-agent, keyed by the `X-MCP-Client` header and persisted in the DB. `set_context`/`clear_context` affect only your own bucket; agents without the header share `"default"`.
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

## Query Strategy

1. Start broad (`search`) then narrow by IDs.
2. Find the root `Project`, then traverse relations.
3. Use `traverse_graph` with direct filters for edge lookup or a start entity for bounded multi-hop exploration.
4. Use `find_shortest_path` for the shortest unweighted connection within `max_depth`.
5. Keep traversal bounds small and narrow with `direction` and canonical `relation_types`.
6. Prefer graph traversal over repeated fuzzy searches after locating the relevant entities.
7. Remember that context-aware search boosts in-context entities; it is not
   necessarily a hard filter.
8. Keep observations factual and timestamped when possible.

## Preferred Entity And Relation Types

Common entity types:
`Project`, `Task`, `Issue`, `PossibleSolution`, `BestPractice`, `Preference`, `Workflow`, `Configuration`, `Model`, `Service`, `APIEndpoint`, `TestCase`.

Common relation types:
`part_of`, `relates_to`, `depends_on`, `implements`, `solves`, `tested_by`, `configured_by`, `integrates_with`, `replaces`.

Use the most specific valid relation type available.

## Execution Templates

Each template names the tool and its `arguments` payload. Dispatch the call
through your host's own MCP mechanism (direct call, namespaced tool name, or
call-tool wrapper).

### Orient template

`get_context` — `{}`

If no context:

`search` — `{"query":"<project name>"}`

`set_context` — `{"entity_id":123}`

### Recall template

`search` — `{"query":"<task keywords>"}`

`get_entities` — `{"entity_ids":[456]}`

### Summarize template

`summarize` — `{"query":"<topic>","max_results":10,"max_observations":20,"max_depth":0,"include_sources":true,"style":"concise"}`

Use the returned deterministic evidence and `sources` as the authority. An
LLM summary is optional synthesis; do not accept source IDs or unsupported
claims supplied by the model.

### Persist template

`graph_write` — `{"operations":[{"type":"create_observation","entity_id":456,"text_content":"<fact>"}]}`

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
