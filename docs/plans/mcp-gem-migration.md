# graph_mem on the official `mcp` gem: MG-0 decisions

MG-0 of `docs/plans/mcp-update-plan.md` §MG (D-20). The "how" is in the reusable guide,
[`docs/guides/migrating-fast-mcp-to-mcp-gem.md`](../guides/migrating-fast-mcp-to-mcp-gem.md); this
document records graph_mem's choices, the wire differences that need Steve's OK, and the step lists
for the Devin items. **Status: awaiting Steve's approval** (MG-1 starts after it).

Inputs, read at `main` 64e16bb (1.54.3):
- the old `ruby_mcp` branch (`a0ff088`, 2025-06-05);
- the `mcp` gem 1.8.1 source;
- PR-3's interop suite and its Ruby SDK 1.8.1 column (`docs/protocol_compat.md`);
- a throwaway spike, `claude/mg-0-spike` (local only, never merged): the adapter, the 3 pilot tools on
  both engines, and the gem's HTTP transport.

**No blocker found.** Everything graph_mem needs works without forking the gem; D-20 stands. The two
surprises (both gems loaded at once; per-request context) have small, spike-tested workarounds.

## What the old `ruby_mcp` branch tells us

`a0ff088` ran graph_mem on `mcp` **0.1.0**: stdio only (no HTTP transport existed), every tool rewritten
by hand as `self.call` with a hand-written JSON Schema, fast-mcp commented out. Nothing in it is reusable
as code: it took the "rewrite the tools" route the plan now rejects. What 1.8.x has that 0.1.0 lacked:
Streamable HTTP (sessions, caps, Origin/Host checks, JSON or SSE answers), `server_context` with
`auth_info`, `instructions`, annotations, output schemas, both protocol eras, and argument validation
we can switch off.

## Spike results

| Check | Result |
|---|---|
| Load both gems | Fails as is: both ship `lib/mcp/{tool,server,prompt,resource,version}.rb` and the gem autoloads `"mcp/tool"` by load path, so `MCP::Tool` stays undefined. Fixed by requiring those 5 files from the gem's directory (guide §4) |
| Wrap every tool class | 40/40 wrap with no per-tool code; all 3 profile servers build (all schemas, incl. the 4 hand-written ones, pass the gem's 2020-12 validation) |
| Pilots `get_current_time`, `search`, `graph_write` on both engines | `tools/list` identical apart from the gem's `"$schema"` key; `tools/call` results identical (content, `structuredContent`, `_meta`); invalid-argument error envelope identical; telemetry records the `X-MCP-Client` |
| Unknown tool | both `-32602`; the gem's message is "Invalid params" with "Tool not found: x" in `data` |
| Gem's Streamable HTTP transport + context | works in JSON and SSE answer modes once the context travels as an `AccessToken` (below) |

Adapter size in the spike: 4 files, ~160 lines, plus a 3-line change to `ApplicationTool#current_mcp_profile`;
pilot parity spec ~90 lines.

## Decisions

### 1. Adapter shape — **generate gem tools from the existing classes**
`GraphMem::OfficialMcp::ToolWrapper.build(tool_class)` returns an `MCP::Tool` subclass with the same name,
description, schemas and annotations; its `call(server_context:, **args)` runs
`tool_class.new(headers:).call_with_schema_validation!` (normaliser, dry-schema, telemetry, `next_move`)
and formats the result exactly like fast-mcp's `send_formatted_result`. Tool code stays untouched through
MG-5. *Reason:* proven on all 40 classes; rewriting tools buys nothing until fast-mcp is gone.

### 2. Schemas — **fast-mcp's JSON Schema now; an in-repo converter after MG-6**
- During MG-1…MG-5: `input_schema_to_json` / `output_schema_to_json`, wrapped in a lenient
  `InputSchema` subclass (no gem-side required-key check) with `validate_tool_call_arguments: false`.
  *Reason:* graph_mem accepts aliases (`entityType`, names for ids) and normalises before validating; the
  gem's checks would reject valid calls with a different error shape.
- After MG-6: keep the `arguments do` DSL and dry-schema (already a dependency, made direct), with fast-mcp's
  schema converter vendored into `lib/graph_mem/mcp_schema/` (MIT, with attribution). *Reason:* plain
  hashes would drop the runtime validation the normaliser relies on, and re-typing 34 schemas by hand
  invites drift.
- Cleanup, not migration: 6 tools (`delete_entity`, `delete_observation`, `delete_relation`,
  `update_entity`, `find_relations`, `suggest_merges`) define an **instance** `input_schema_to_json` that
  `tools/list` never calls. Remove them in MG-2 so nobody mistakes them for the advertised schema.

### 3. Profiles — **one `MCP::Server` per profile**
Built from `McpProfile.select_tools` / `select_prompts`, with per-profile `instructions:` and the §2.18
capabilities hash passed explicitly (the gem's default advertises `listChanged: true` and `logging`).
*Reason:* the gem has no request-time filtering; per-profile prompts (`persist` not on readonly) fall out
of it.

### 3b. Hidden aliases — **decision needed (recommend: remove them before MG-2)**
The gem lists every registered tool, so the 18 hidden aliases would appear in `tools/list`.
Production telemetry since 2026-09-17: 25 tool calls in all, **1** to an alias (`search_entities`).
- **Recommended:** deprecate them in MG-1's CHANGELOG and remove them in MG-2a (a minor, announced). MG-2b
  then covers 10 tools instead of 28, and nothing graph_mem-specific overrides the gem's listing.
- Alternative: keep them through MG-6 with an in-repo `MCP::Server` subclass whose `tools` reader holds all
  tools while `@tools` (what `tools/list` reads) holds the advertised ones. Works, but relies on gem
  internals; a spec would pin it on every gem upgrade.

The 18: `bulk_update`, `clear_context`, `create_entity`, `create_observation`, `create_relation`,
`delete_entity`, `delete_observation`, `delete_relation`, `find_relations`, `get_entity`,
`get_subgraph_by_ids`, `get_version`, `list_entities`, `merge_entities`, `search_entities`,
`search_subgraph`, `update_entity`, `update_observation`.

### 4. HTTP — **mount the gem's `StreamableHTTPTransport`, one per profile**
Behind graph_mem's Rack layer (`McpAccessPolicy`, then the request context). Options:
`enable_json_response: true` (graph_mem answers POSTs with JSON today, unless the client accepts only
SSE), `max_sessions: 256` (today's cap; MG-4 checks whether the gem's behaviour at the cap matches
graph_mem's evict-the-least-recently-active rule), `allowed_hosts:` from a new `GRAPH_MEM_MCP_ALLOWED_HOSTS` (the
gem accepts only loopback `Host` headers by default, and graph_mem is reached on LAN addresses).
*Reason:* MG-5's 2026-07-28 lifecycle lives in this transport; keeping our own would mean re-implementing it.
The gem already has the body cap (4 MiB, plus a 64 KiB `initialize` cap), the session cap and
Origin/Host checks.

What changes on the wire (from PR-3's Ruby SDK 1.8.1 column; the fixtures' graph_mem expectations move
to these answers in MG-4). **Each row needs Steve's OK**; the recommendation is to accept all of them:

| Case | graph_mem today | gem 1.8.1 | Reference (TS SDK) | Recommendation |
|---|---|---|---|---|
| `server/discover`, 2026-07-28 envelope (stdio, HTTP) | -32601 / 400 -32600 | result | result | accept (this is MG-5's goal) |
| discover, then `initialize`, on one stdio process | -32601, then served | discover served, then `initialize` refused (-32601) | all served | accept: clients that probe use a sibling process (TS) or speak modern after discover |
| 2026-07-28 header without envelope | 400 -32600 | 400 -32602 | 400 -32602 | accept |
| header disagrees with envelope | 400 -32600 | 400 -32020 | 400 -32020 | accept (MG-5 wanted -32020) |
| future revision 2027-01-01 | 400 -32600 | 400 -32022 | 400 -32022 | accept |
| in session, `MCP-Protocol-Version` 1999-01-01 | 400 -32000 | 400 -32022 | 400 -32000, no id | accept |
| in session, `MCP-Protocol-Version` 2026-07-28 | 400 -32000 | **200**, served | 400 -32000 | accept (lenient, harmless) |
| `"id": null` | **400** -32600, not run | **200** -32600, not run | 400 -32700 | accept: still refused and not run |
| no `jsonrpc` member | **400** -32600 | **200** -32600 | 400 -32700 | accept |
| stdio batch line | -32600 | served | dropped | accept |
| second GET stream | 409 -32000 | 409 -32600 | 409 -32000 | accept |
| unknown session | 404 -32001 **with id** | 404 -32600, no id | 404 -32001 with id | accept: clients re-initialise on 404 whatever the body (loses PR-2 §2.19's id echo) |
| non-`initialize` request, no session | 400 -32600 with id | 400 -32600, no id | 400 -32000, no id | accept |
| session started on `/mcp`, used on `/mcp/maintenance` | served (shared sessions) | 404 | n/a | accept: a session belongs to one endpoint |
| stdio line over the cap | -32600, keeps serving | ends the session | n/a | accept |
| `tools/list` `inputSchema` | no `$schema` | adds `"$schema": …2020-12` | n/a | accept |
| unknown tool | -32602 "Tool not found: x" | -32602 "Invalid params", data "Tool not found: x" | n/a | accept |

If any row is refused, the fallback is a small Rack pre-filter in front of the gem's transport that
answers that case graph_mem's way (the checks already exist in `McpStreamableHttpTransport`).

### 5. Auth and request context — **`McpAccessPolicy` in front; context in an `AccessToken`'s claims**
No OAuth (D-9), no `token_verifier:`. A Rack step builds
`GraphMem::OfficialMcp::RequestContext(client_id: X-MCP-Client, profile:, session_id:)` and stores it as
`env["mcp.auth_info"] = MCP::Server::OAuth::AccessToken.new(token: "graph_mem", claims: { … => context })`.
The wrapper reads it from `server_context[:auth_info]` (also on the SSE body's thread) and sets the
thread-locals `ApplicationTool` already uses. The token's `client_id`/`subject` stay nil, so the gem does
**not** bind sessions to a client (today's behaviour). *Reason:* `auth_info` is the only per-request value
the gem forwards to handlers; the transport reads `issuer`/`subject`/`client_id` from it, so it must be a
real `AccessToken`. Binding sessions to `X-MCP-Client` is possible later by setting `client_id`.

### 6. The rest
- **stdio:** a `StdioTransport` subclass overriding the public `send_response` to write to the saved pipe,
  so `$stdout` stays pointed at stderr (§2.13). Error envelope via the wrapper (same JSON as HTTP).
- **Errors:** the wrapper rescues everything and returns the `ToolError` envelope as an `isError` result
  (`InvalidArgumentsError` stays an `isError` result, not `-32602`). The gem's `-32603` path is unused.
- **Telemetry:** unchanged (inside `call_with_schema_validation!`), so one row per call on either engine.
- **`next_move`:** unchanged (`ToolSuccessResponse`).
- **Load shim:** `lib/graph_mem/official_mcp.rb` requires the gem's 5 clashing files by absolute path;
  removed in MG-6. Re-check the clash list on every gem bump.

### 7. Legacy `/mcp/sse` — **keep on fast-mcp until MG-6, remove it there**
*Reason:* while fast-mcp is still loaded it costs nothing to keep; it's deprecated (D-3) and the gem has
no equivalent. MG-4's CHANGELOG announces the removal; MG-6 removes it with fast-mcp.

### 8. Port lists (assuming 3b is accepted)
- **MG-1** (1.55.0): adapter, engine switch, load shim, context bridge; the 3 pilots with parity specs;
  `official` refused in production. CHANGELOG › Deprecated: the 18 aliases.
- **MG-2a** (Claude, 1.55.1): the 12 `/mcp` tools: `find_shortest_path`, `get_context`, `get_current_time`,
  `get_entities`, `graph_delete`, `graph_edit`, `graph_write`, `rank_observations`, `search`,
  `set_context`, `summarize`, `traverse_graph`; the parity-spec template
  `spec/mcp/official_engine/tool_parity_spec.rb`; alias removal; the 6 dead instance schemas removed.
- **MG-2b** (Devin, 1.55.2): the 10 maintenance tools: `apply_maintenance_review`, `detect_contradictions`,
  `dismiss_maintenance_review`, `dream_state_status`, `get_graph_stats`, `get_maintenance_reports`,
  `list_maintenance_review`, `scan_project`, `scan_project_status`, `suggest_merges`.
- **MG-3, MG-4, MG-5, MG-6** as in the plan, with decisions 4–7 above.

#### MG-2b step list (Devin-simple)
Branch `devin/mg-d2b-maintenance-parity` off `main` after MG-2a merges. For **each** of the 10 tools, in the
order above:
1. Add one example to `spec/mcp/official_engine/tool_parity_spec.rb`, copying MG-2a's template: same
   `tools/list` entry on both engines (ignoring `"$schema"`), and the same `tools/call` result on one
   synthetic fixture (use the `/mcp/maintenance` profile; build fixtures with `MemoryEntity.create!` and
   synthetic names, `Dir.mktmpdir` for `scan_project`).
2. Run `GRAPH_MEM_MCP_ENGINE=official bundle exec rspec spec/mcp/official_engine/tool_parity_spec.rb` and
   the default-engine run of the same file (with `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`).
3. **Stop and ask** if a tool needs anything but a new example (a wrapper change, a skipped key, a
   different result).

Then: full suite on its own (test DB truncated before and after), rubocop, CHANGELOG
`## [Unreleased]` › Added "Parity specs for the maintenance tools on the official engine", PR against
`main`. No version bump (Claude's release commit bumps 1.55.2).

#### MG-D1 step list (Devin-simple, after MG-6 merges)
Branch `devin/mg-d1-official-sdk-docs`. Replace fast-mcp with "the official MCP Ruby SDK (`mcp` gem)" and
remove fast-mcp-only details in: `README.md` (stack line, MCP section), `docs/mcp_tools.md` (opening
paragraph, the exception-mapping list), `docs/architecture.md` (feature map), `AGENTS.md` (Architecture ›
MCP layer), `docs/protocol_compat.md` (summary). List each change in the PR; don't touch the guide or
CHANGELOG history. **Stop and ask** if a sentence needs more than a name swap.

### 9. Measured port cost
The tools side is cheap: one generic adapter (~160 lines) covered all 40 classes, and a pilot parity spec
was ~90 lines. Per-tool cost is therefore one parity example, not a port. The effort sits in MG-4 (the
transport decisions above, stdio, host allowlist, wiring per profile) and MG-5. The research brief's
"2–4 weeks" stays **[UNVERIFIED]**: the spike measured code size, not calendar time. The guide's §8
collects the per-phase figures as the phases land.

### 10. Gem pin — **exact version, `gem "mcp", "1.8.1"`**
*Reason:* the gem's edge-case answers change between releases (PR-3 found 1.8.1 differing from
graph_mem in 16 cases), and the load shim depends on its file layout. Upgrades are one PR each: read the gem's CHANGELOG, re-check the load-shim
file list, run the parity specs, PR-3's suite and `compare.rb` on both engines.

## Safety net from MG-1 on
- `spec/requests/mcp_protocol_compat_spec.rb` and `spec/mcp/official_engine/` read
  `GRAPH_MEM_MCP_ENGINE`. CircleCI gets a second, small job running those files with
  `GRAPH_MEM_MCP_ENGINE=official`; the full suite keeps running on the default engine.
- `compare.rb` gets `--http-graph-mem` pointed at a server booted with the official engine; rows the
  engine doesn't serve yet are listed in the PR as "not ported yet".

## For Steve to decide
1. Approve decisions 1–10 (or change them).
2. 3b: remove the 18 hidden aliases (recommended) or keep them with the server subclass.
3. Decision 4's table: accept each wire difference, or name the rows to keep graph_mem's way.
4. `GRAPH_MEM_MCP_ALLOWED_HOSTS` as the new setting for the gem's Host check (or turn the check off and
   rely on `McpAccessPolicy`'s IP allowlist).
