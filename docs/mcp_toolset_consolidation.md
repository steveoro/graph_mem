# MCP Toolset Consolidation Plan

## Overview

GraphMem exposes 35 flat MCP tools. This document plans a reduction to **12 tools in the default
profile** (22 registered in total, split across connection profiles), plus a shift of the session
workflow out of the always-on rule file and into the server's own responses.

Decisions framing the plan:

| Decision | Choice |
|---|---|
| Consolidation appetite | Moderate — merge genuine special-cases only; keep distinct intents distinct |
| First deliverable | Queryable tool telemetry, so cuts are measured rather than argued |
| Workflow enforcement | Move fully server-side: `next_move` on success, context banner, MCP Prompts |

Nothing here changes the graph schema or the storage model. This is entirely about the shape of
the agent-facing surface.


## The measured problem

Three numbers, taken from the current tree.

**`tools/list` costs about 4,700 tokens before argument schemas.** The 35 tool descriptions total
18,956 characters. Every session pays this before any work happens, on top of the 192-line
`docs/rules/graph_mem_mcp_rules.md` and the 186-line skill file.

**Roughly half of that is tools describing other tools.** The eight-tool read cluster carries 34
`"Do not use ... use X instead"` lines:

| Tool | Cross-reference lines |
|---|---|
| `get_entity` | 6 |
| `search_subgraph` | 5 |
| `search_entities`, `list_entities`, `find_relations`, `traverse_graph`, `summarize` | 4 each |
| `get_subgraph_by_ids` | 3 |

**That prose grows O(n²).** Adding a ninth read tool means editing eight existing descriptions.
The negative routing is what currently holds accuracy together, so it cannot simply be deleted —
but it is a symptom, not a fix.

### Why the read tools need so much disambiguation

They are not eight distinct operations. They are eight cells of a 3 × 5 matrix:

- **Selection** — by text query, by known IDs, or by nothing (catalog paging).
- **Projection** — entity summaries, plus observations, plus relations among matches, plus
  relations expanded N hops, or synthesized prose.

`get_subgraph_by_ids` is `get_entity` with an array. `find_relations` with only `from_entity_id`
set is `traverse_graph(max_depth: 1)`. When tools are points in a parameter space rather than
separate intents, the only way to tell them apart in prose is to enumerate the neighbours — which
is exactly what the descriptions do.

The fix is to expose the parameters and delete the cells.


## Phase 0 — Make telemetry queryable

`ToolTelemetry` currently writes a single log line and nothing else:

```ruby
# app/services/tool_telemetry.rb
Rails.logger.info(
  "[ToolTelemetry] tool=#{tool_name} client=#{client_id} duration_ms=#{duration_ms} " \
  "result_size=#{result_size} scope=#{scope} error_class=#{error_class}"
)
```

So there is no way to answer the questions that should drive every later phase: which tools are
actually called, which are never called, and which fail most often.

Add a `tool_invocations` table written from the same call site in
`ApplicationTool#call_with_schema_validation!`:

| Column | Notes |
|---|---|
| `tool_name`, `client_id` | Indexed together with `created_at` |
| `outcome` | `ok` / `error` |
| `error_class`, `error_category` | `error_category` from `ToolError.category_for` |
| `duration_ms`, `result_size`, `scope` | Already computed today |
| `argument_keys` | JSON array of **keys only** |

Recording argument *keys* rather than values preserves the existing "without logging sensitive
payloads" contract while still revealing parameterization patterns — which is precisely the signal
needed to judge whether a merged tool is being called correctly.

Add a `graph_mem:tool_usage` rake report: per-tool call count, share of total, error rate by
category, p50/p95 duration.

**Exit criteria:** two to four weeks of real sessions. The report should immediately identify
tools that are never called at all — those need no design work, just removal from the default
profile.


## Phase 1 — Annotations and profiles (non-breaking)

Both mechanisms already exist in `fast-mcp` 1.6.0 and are unused. Neither renames a tool, so this
phase is safe to ship independently.

### Annotations

`FastMcp::Tool.annotations` accepts `read_only_hint`, `destructive_hint`, `idempotent_hint` and
`open_world_hint`, and `FastMcp::Server` forwards them camelCased in `tools/list`. GraphMem sets
none of them.

```ruby
class SearchEntitiesTool < ApplicationTool
  annotations(read_only_hint: true, open_world_hint: false)
end
```

This is the machine-readable form of clustering: clients use it to group tools, to auto-approve
reads, and to prompt for confirmation on destructive calls. Set it on all 35 tools as they stand.

### Connection profiles via `filter_tools`

`FastMcp::ServerFiltering#filter_tools` takes a block receiving `(request, tools)` and returns the
subset to register, building a filtered server copy per request:

```ruby
# config/initializers/fast_mcp.rb
server.filter_tools do |request, tools|
  McpProfile.for(request).select_from(tools)
end
```

Select the profile from the request path so each client config is explicit and independent:

| Profile | Path | Contents |
|---|---|---|
| `default` | `/mcp` | Context, read, write — the 12-tool catalog |
| `readonly` | `/mcp/readonly` | Context and read only |
| `maintenance` | `/mcp/maintenance` | Everything, including the 10 maintenance tools |

Each tool declares its profile membership as class metadata, so `McpProfile` stays a lookup rather
than a hardcoded name list.

### Why not a runtime `enable_toolset` meta-tool

`FastMcp::Server` advertises `tools: { listChanged: true }` in its capabilities, but the only
notifier implemented in the gem is `notify_resource_list_changed`. **There is no
`notifications/tools/listChanged` emitter.** A runtime toggle would therefore mutate server state
with no way to inform the client, which would keep serving its stale list.

Profiles chosen at connect time work today. Runtime toggling needs a gem change first.


## Phase 2 — Read consolidation (10 tools to 6)

### `search` — absorbs `search_entities`, `search_subgraph`, `list_entities`

One selection-by-query tool with an explicit projection.

| Was | Becomes |
|---|---|
| `search_entities(query, limit)` | `search(query:)` — default projection, summaries only |
| `search_subgraph(query, search_in_*, page, per_page)` | `search(query:, include: [:observations, :relations], search_in_*:)` |
| `list_entities(page, per_page)` | `search(page:, per_page:)` — no query means catalog paging |

**Paging conventions must be unified.** `search_entities` uses `limit` (default 50, max 100) while
`search_subgraph` and `list_entities` use `page`/`per_page` (default 20, max 100). Standardize on
`page`/`per_page` and add `limit` as a `ParameterNormalizer` alias so existing callers keep working.

### `get_entities` — absorbs `get_entity`, `get_subgraph_by_ids`

Same operation at different arity, with one real semantic difference to preserve: `get_entity`
returns **all** incident relations, whereas `get_subgraph_by_ids` returns only relations with
**both** ends inside the requested set.

Expose that as `relations: "all" | "internal"`, defaulting by arity — a single ID defaults to
`all`, multiple IDs default to `internal`. Both current behaviours remain reachable and the common
case needs no extra parameter.

| Was | Becomes |
|---|---|
| `get_entity(entity_id, include_obsolete, include_ranked, query, observation_limit)` | `get_entities(entity_ids: [id], relations: "all", ...)` |
| `get_subgraph_by_ids(entity_ids, query, observation_limit)` | `get_entities(entity_ids: [...], relations: "internal", ...)` |

### `traverse_graph` — absorbs `find_relations`

This is the one merge with a genuine wrinkle. `find_relations(from_entity_id, to_entity_id,
relation_type)` covers two different queries:

- **Only one endpoint given** — that is a depth-1 traversal:
  `traverse_graph(start_entity_id:, max_depth: 1, include: [:relations])`.
- **Both endpoints given** — that is an edge-existence lookup, not a traversal at all.

Handle the second case by adding an optional `to_entity_id` to `traverse_graph`, restricting
returned edges to those reaching that entity. With `max_depth: 1` it reproduces `find_relations`
exactly. Add an `include:` projection so the relations-only response shape survives.

### Unchanged

`summarize`, `find_shortest_path` and `rank_observations` stay separate. These are genuinely
distinct intents — synthesis, connectivity between two named nodes, and trust-ordered observation
retrieval — not projections of a shared query.


## Phase 3 — Write consolidation (10 tools to 3)

`bulk_update` **already has the right shape**: a type-discriminated `operations` array accepting
`create_entity`, `create_observation` and `create_relation` items. It is create-only, and its
description currently steers single writes away from it ("Do not use for a single create; use
`create_entity` instead"). That is backwards — nine tools are being preserved to avoid one
slightly wider schema.

Extend the `operations` array to updates and deletes, then split by blast radius:

| New tool | Absorbs | Annotations |
|---|---|---|
| `graph_write` | `create_entity`, `create_observation`, `create_relation`, `bulk_update` | `destructive_hint: false` |
| `graph_edit` | `update_entity`, `update_observation` | `destructive_hint: true` |
| `graph_delete` | `delete_entity`, `delete_observation`, `delete_relation`, `merge_entities` | `destructive_hint: true` |

Keep `bulk_update`'s existing three-array form (`entities`, `observations`, `relations`) as an
accepted alias on `graph_write`, since it is already documented and in use.

### Why three and not one

Two separate arguments, which land in different places:

**Annotations are per-tool, so a single mega-tool cannot describe itself honestly.** One
`graph_write` covering deletes would have to carry `destructive_hint: true` wholesale, and clients
that confirm destructive operations would then prompt on every benign observation append. The
`graph_write` / `{graph_edit, graph_delete}` boundary is what makes the hint truthful.

**Intent separation is what keeps routing accurate.** `graph_edit` and `graph_delete` share
annotations, so the hint argument alone would allow merging them — but an update with
`supersede: true` is recoverable and a delete or merge is not. Keeping them distinct is a routing
and safety decision, not an annotation one.


## Phase 4 — Move the workflow into the server

The current rule file carries the four-phase workflow, a tool quick-reference, 23 entity types, 12
relation types and a query strategy section — rent paid in every session, whether or not the
session touches the graph. Most of it can move server-side, where it costs nothing until needed and
cannot be skipped.

### Extend `next_move` to success responses

`ToolError` already defines the field and `DEFAULT_NEXT_MOVES` supplies per-category values. It is
only wired into the *error* envelope. Adding it to successful responses turns the workflow from
advice into mechanism:

```ruby
{ entity_id: 712, name: "...", next_move: "Link it: graph_write with a create_relation op to 283 (part_of)." }
```

That single field replaces the Persist-phase instruction in the rule file.

### Emit a context banner

Any tool called with no active context returns a compact banner alongside its result:

```ruby
{ ..., context: { status: "none", next_move: "Call set_context(<project>) to scope this session." } }
```

This replaces the Orient-phase instruction. Fold `get_version` output into the same metadata and
drop it as a standalone tool.

### Standardize the dedup response that already exists

`CreateEntityTool` already performs the check the rule asks agents to perform manually — a vector
similarity lookup with `DEDUP_DISTANCE_THRESHOLD`, returning `warning` plus `existing_entity`
instead of creating. It does **not** use the envelope shape, so the guidance is prose in a
`warning` string rather than a machine-readable `next_move`.

Normalize it to `{ status: "possible_duplicate", candidates: [...], next_move: "..." }` and apply
the same pattern to relation creation. "Search before create" then stops being a rule the model
can skip.

### MCP Prompts for the phases

GraphMem registers tools and resources (`ApplicationResource < ActionResource::Base`) but **no MCP
prompts**. Expose `/orient`, `/recall <topic>` and `/persist` as prompts: invoked on demand rather
than loaded into every context. This is the natural home for what is currently rule prose.

### Move the vocabularies into the schema — as soft enums

The rule lists 23 entity types and 12 relation types. **The graph already contains types outside
that list** — `Feature`, `Implementation`, `File`, `DatabaseConstraint` and `RailsHelper` are all
live. The rule is being violated in practice, so a hard schema `enum` would reject existing
patterns and break `EntityTypeMapping` canonicalization.

Use a soft enum instead: schema `examples` listing the canonical set, plus a suggest-on-mismatch
response when a submitted type is close to a canonical one. The vocabulary then arrives through
`tools/list`, where the model already looks, and roughly 200 tokens leave the rule file.

### What the rule file keeps

Context scoping semantics (per-`X-MCP-Client`, persisted, boosts rather than filters) and the
dream-state compaction awareness section. Both describe behaviour an agent cannot discover from a
tool schema.


## Target catalog

### Default profile — 12 tools

| Tool | Role |
|---|---|
| `get_context`, `set_context` | Orient. `set_context(null)` replaces `clear_context` |
| `search` | Selection by query or catalog paging, with projection |
| `get_entities` | Load known IDs, one or many |
| `traverse_graph` | Bounded BFS, depth-1 edge lookup, edge filters |
| `find_shortest_path` | Connectivity between two named entities |
| `summarize` | Synthesized, source-backed answer |
| `rank_observations` | Trust-ordered observations |
| `graph_write` | Creates and appends, single or batched |
| `graph_edit` | In-place updates and supersedes |
| `graph_delete` | Deletes and merges |
| `get_current_time` | Timestamping |

### Maintenance profile — the above plus 10

`suggest_merges`, `list_maintenance_review`, `apply_maintenance_review`,
`dismiss_maintenance_review`, `get_maintenance_reports`, `dream_state_status`,
`detect_contradictions`, `get_graph_stats`, `scan_project`, `scan_project_status`

An agent running Orient → Recall → Work → Persist should never need these, and Phase 0 telemetry
will confirm how often they are actually reached.

**Net effect:** 35 registered tools become 22, of which 12 are visible in a normal session. The
cross-reference prose largely disappears because there is little left to disambiguate against.


## Migration

**Keep old names as hidden aliases.** Register the current 35 tool classes as thin delegating
shims, then exclude them from `tools/list` with a `filter_tools` rule. In-flight sessions and
unmigrated client configs keep working; new sessions only see the new catalog. Use the
`tool_invocations` table to know when alias traffic has stopped and the shims can be deleted.

**Update the hardcoded tool-name list.** `ToolMutationPolicy::COMPACTION_VALVE_TOOLS` names 17
tools as strings. Every rename must be reflected there or the compaction valve silently stops
pausing for those operations — a correctness bug, not just a stale constant.

Also requiring updates:

- `EXPECTED_TOOL_NAMES` in `spec/integration/fast_mcp_registration_spec.rb`
- `docs/mcp_tools.md` — currently subtitled "the 35 Model Context Protocol tools"
- `docs/rules/graph_mem_mcp_rules.md` and `skills/graph-mem-mcp-toolset/SKILL.md`
- `ToolError::DEFAULT_NEXT_MOVES`, which references `search_entities` and `list_entities` by name
- `bin/mcp_stdio_runner.rb`, which registers `ApplicationTool.descendants` directly and so bypasses
  `McpToolRegistry` — it needs the profile filter applied too, or stdio clients will see all 22


## Risks

**Selection errors become parameterization errors.** Models route better on distinct tool names
than on enum parameters. A wrong tool call is obvious and cheap to retry; a wrong `include:` or
`relations:` value returns a plausible but incomplete answer the model then reasons from. This is
the main argument for the moderate scope chosen here: merge only where operations are the same
thing at different arity or projection, and default the new parameters so the common case needs
none of them. Phase 0's `argument_keys` column is what will detect this happening.

**Shorter descriptions may cost accuracy.** The negative routing works. Remove it only where the
sibling it points at no longer exists, and keep it between the tools that remain genuinely
confusable — `search` versus `summarize` most of all.

**Profiles can hide a needed tool.** Unlike the AdminHub case, filtering here is ergonomic rather
than a security boundary, so the failure mode is an agent that cannot do maintenance work rather
than one that exceeds its permissions. Keep `/mcp/maintenance` documented in
`docs/development.md`.


## Open questions

1. **Does `summarize` belong in the default profile?** It is the most expensive tool and overlaps
   `search` in the model's eyes. Phase 0 telemetry should decide.
2. **Should `graph_write` accept a `dry_run`?** Less critical than in a system with real-world side
   effects, but it would make dedup preview explicit rather than implicit in the response.
3. **Per-client profile defaults.** `X-MCP-Client` is already parsed; a client could be pinned to a
   profile server-side instead of relying on each config using the right path.
4. **`outputSchema` / `structuredContent`.** Not supported in `fast-mcp` 1.6.0. Worth a gem bump
   to return typed results instead of JSON inside a text block?
