# MCP Tools Documentation

Detailed reference for GraphMem's 22 Model Context Protocol (MCP) tools.

## Overview

MCP tools in GraphMem are Ruby classes that implement operations on the knowledge graph. Each tool is accessed via JSON-RPC calls from an MCP client. The protocol is served by the official MCP Ruby SDK (`mcp` gem); tools auto-register via `ApplicationTool` inheritance, and each profile's server wraps them (see [architecture.md](architecture.md#1-mcp-interface-layer-22-advertised-tools)).

## Connection Profiles

GraphMem registers 22 tool classes and filters the catalog by connection URL:

- `/mcp` — 12 canonical context, read, and mutation tools
- `/mcp/readonly` — 9 canonical context and read tools
- `/mcp/maintenance` — all 22 canonical tools

Profiles govern call eligibility; calling a tool outside the selected profile returns the JSON-RPC
error `-32602` (`data`: `Tool not found: <name>`). The 18 hidden compatibility aliases were removed in 1.55.0 (use the canonical tools).
Profiles are selected when connecting and are not authorization boundaries.
Every tool also publishes the standard MCP `readOnlyHint`, `destructiveHint`,
`idempotentHint`, and `openWorldHint` annotations.

## Standard Compatibility

All tools accept both graph_mem's native snake_case/ID-based parameters and the `@modelcontextprotocol/server-memory` camelCase/name-based conventions. A `ParameterNormalizer` layer automatically converts incoming parameters before validation:

- **camelCase keys** are converted to snake_case (e.g. `entityType` becomes `entity_type`)
- **Entity names** (strings) are resolved to integer entity IDs where an ID is expected
- **Field aliases** are normalized (`content` to `text_content`, `from`/`to` to `from_entity_id`/`to_entity_id`)
- **`operations` arrays** drive `graph_write`, `graph_edit`, and `graph_delete`

### Name resolution order

When a tool takes an entity **name** instead of an ID, resolution runs in this order:

1. The **context project** scope (`set_context` project)
2. The **global** namespace (`project_id IS NULL`)
3. A **single foreign-scope candidate** — if exactly one entity anywhere carries the name, it resolves (documented convenience; ambiguity is never guessed)
4. Several candidates → `AmbiguousReference` error listing them; retry with an `entity_id`

**Destructive-name note:** name-based arguments can reach outside your context project — `graph_delete` with `delete_entity "Foo"` under context project A can delete project B's `Foo` when B's is the only `Foo` in the graph. Prefer `entity_id` for deletes/moves/edits when precision matters.

## Recommended Session Workflow

Tools are designed to be used in four phases per session:

1. **Orient** -- `get_context` / `search` / `set_context`
2. **Recall** -- `search` / `get_entities` / `traverse_graph`
3. **Work** -- Execute the task, consulting the graph as needed
4. **Persist** -- `graph_write` / `graph_edit` / `graph_delete`

The same workflow is available through MCP prompts: `orient`, `recall` (with a
required `topic`), and `persist`. `persist` is not served on the readonly
profile (`/mcp/readonly`, or stdio with `GRAPH_MEM_MCP_PROFILE=readonly`); it
is omitted from `prompts/list` and `prompts/get` answers "Prompt not found".

## Successful Tool Metadata

Every successful tool result includes `version` and, where useful,
`next_move`. Calls made without an active project also include a compact
`context: { status: "none", next_move: ... }` banner. FastMCP `_meta` mirrors
`graphMemVersion` and `contextStatus`.

All 12 default-profile tools advertise a post-envelope `outputSchema` and
return the same JSON object in both `structuredContent` and
`content[0].text`. Maintenance-only and hidden compatibility tools remain
text-only during the staged rollout. Tool errors remain `isError: true` JSON
text and do not claim conformance to success output schemas.

## Context Scoping (2 advertised tools)

Context scoping allows search tools to **boost** entities related to the active project. Since project-scoped names landed, the scope is an indexed `project_id` lookup (the project member set) — it is **not** capped, and `scope_truncated` is always `false` (`scope_max_entities` is always `null`; both fields remain for response compatibility). When a context is set via `set_context`, `search` prioritizes in-context query matches (cross-project results still appear, but ranked lower).

Context is stored per MCP client in the `agent_contexts` table, keyed by the `X-MCP-Client` request header. Agents without the header share the `"default"` bucket.

#### `set_context`
- **Description:** Set this MCP client's active project so `search` boosts in-context matches without hard-filtering results. Pass required `entity_id` as an integer/name, or null to clear context.
- **Parameters:**
  - `entity_id` (integer, string, or null; required): Project ID/name, or null for global scope.
- **Response:** `{ status, entity_id, entity_name, entity_type }`, plus `warning` and `next_move` when this client id appears to be shared by more than one agent (see [Shared client ids](#shared-client-ids))

#### `get_context`
- **Description:** Read this MCP client's active project context (entity and scope fields, or status no_context); auto-clears if the project entity is gone. Use `set_context` with null to clear it.
- **Parameters:** None
- **Response:** `{ status, entity_id, entity_name, entity_type, description, context_set_at, scope_entity_count, scope_truncated, scope_max_entities }` or `{ status: "no_context" }`, plus `warning` and `next_move` when this client id appears to be shared (see [Shared client ids](#shared-client-ids))

#### Shared client ids

Context is stored per `X-MCP-Client` value, so two agents sending the same value share one
`agent_contexts` row and silently rescope each other whenever either calls `set_context`.

GraphMem detects this two ways and adds `warning` plus `next_move` to the `set_context` and
`get_context` responses:

- **Context change conflict** — `set_context` overwrites a *different* project that was set under
  the same client id within the last 5 minutes. Works on every transport.
- **Concurrent session** — a different `Mcp-Session-Id` called a tool under the same client id
  within the same window. Only available over Streamable HTTP (stdio has no session id).

The fix is always the same: give each agent its own `X-MCP-Client` header value.

## Graph Mutation (3 tools)

#### `graph_write`
- **Description:** Atomically create up to 50 entities, observations, and relations through type-discriminated `operations`; the former three-array bulk format is also accepted.
- **Operation types:** `create_entity`, `create_observation`, `create_relation`.
- **Source convention:** `source` in the form `"<client>/<model>: <task>"` (e.g. `"claude-code/opus: release task"`). The audit log shows the prefix as part of the "claimed" identity and the task as the row's Reason (1.65.0); the actor is always `mcp:graph_write`.
- **Duplicate policy:** Any possible entity or relation duplicate prevents the
  entire batch and returns `{ status: "possible_duplicate", kind,
  operation_index, submitted, candidates, next_move }`.
- **Soft vocabularies:** `entity_type` and `relation_type` schemas publish
  canonical `examples`. Novel values remain valid; likely misspellings add a
  non-blocking `type_hint` to the created result.

#### `graph_edit`
- **Description:** Atomically update entities and observations, including observation supersession.
- **Operation types:** `update_entity`, `update_observation`.
- **Concurrent writers:** if a merge, an undo or another edit changes a row this edit is waiting on, the edit is retried (up to 3 times) and lands after that writer. If it still can't, it fails with a retriable `concurrency` error (`code: "concurrent_write"`) and nothing is edited: retry shortly.

#### `graph_delete`
- **Description:** Atomically delete entities/relations, obsolete observations, or merge entities. Per-operation audit reasons remain enforced.
- **Project roots:** `delete_entity` on a `Project` is refused on `/mcp` (`code: "project_delete_needs_maintenance"`) and allowed on `/mcp/maintenance` (or stdio with `GRAPH_MEM_MCP_PROFILE=maintenance`) once no entity is scoped to it; with members it is refused everywhere (`code: "project_has_members"`, re-parent or delete them first). If an observation or relation is added to the Project while it is being deleted, the delete fails with the retriable `code: "project_changed_during_delete"` (category `concurrency`): retry once. The delete clears every `X-MCP-Client` context that pointed at the project. Merging a Project away stays refused.
- **Operation types:** `delete_entity`, `delete_observation`, `delete_relation`, `merge_entities`.

All three tools accept at most 50 logical operations and return `{ mode: "batch", status,
results, summary }`. Any failed operation rolls back the full batch.

Every batch (and every merge) is recorded as a change set, so the operator can undo it from the web
UI or the console for 30 days (merges: 7). Batches that hard-delete an entity or observation, or mix a
merge with other writes, are recorded but can't be undone. Agents can't undo: there is no MCP tool for it.

## Observation Management (2 tools)

#### `rank_observations`
- **Description:** Return one known entity's observations sorted by trust_score (most reliable first). Pass required `entity_id` (integer; also accepts entity name); optional `include_obsolete` (bool, default false), `limit` (integer, default all), `query` (string; relevance then trust). Do not use when you also need relations or entity metadata; use `get_entities` instead. Do not use for opposing observation pairs; use `detect_contradictions` instead. Do not use to find observations across entities by keyword; use `search` instead. Do not use for a topic answer; use `summarize` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations in the ranking.
  - `limit` (integer, optional): Maximum number of observations to return.
  - `query` (string, optional): Rank by query relevance before trust.

#### `detect_contradictions`
- **Description:** Scan an entity's active observations and 1-hop related observations for semantically similar pairs with opposite polarity; returns candidates and stores a contradictions MaintenanceReport. Pass required `entity_id` (integer; also accepts entity name); optional `max_distance` (float, default 0.35), `max_results` (integer, default 20). Does not merge or delete. Do not use for trust ranking; use `rank_observations` instead. Do not use for duplicate entities; use `suggest_merges` instead. Do not use to read stored reports; use `get_maintenance_reports` instead. Do not use to resolve a conflicting fact; use `update_observation` or `delete_observation` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `max_distance` (number, optional, default: 0.35): Maximum cosine distance threshold (smaller = stricter).
  - `max_results` (integer, optional, default: 20): Maximum candidate pairs to return.
  - `mode` (string, optional, 1.64.0): `contradictions` (default; the answer is unchanged) or `outdated_by_fact`.
  - `fact_observation_id` (integer, `outdated_by_fact` only, required there): an active source fact (tag `source-fact`) of `entity_id`.
  - `terms` (array of strings, `outdated_by_fact` only): up to 5 search terms, 2-100 characters each, besides the fact's `replaces:` tags.
  - `seed_review` (boolean, `outdated_by_fact` only, default: true): seed the proposals as `fact_supersede` review rows. With `false` nothing is written, and pairs that already have a row aren't sent to the judge.
  - In `outdated_by_fact` mode `max_results` is at most 50 and `max_distance` is ignored. Pairs that already have a pending row or a dismissal are skipped (`already_known` counts them). With the LLM judge on, one call waits for at most 2 judge batches (16 candidates); the rest come back `unjudged` (`unjudged_over_cap` counts them, so they can be told from LLM-off ones), and a background `FactSupersedeJob` judges them later: it re-judges pending `unjudged` rows whenever the LLM is usable (a `superseded` verdict refreshes the row; `still_valid` or `unrelated` dismisses it without suppression). Any of the three fact arguments without the mode, or a fact that isn't an active source fact of the entity, is an argument error with a `next_move`.
- **Review rows:** the default mode only reports. Contradiction review rows come from the scheduled stale scan alone; apply one with `apply_maintenance_review` and `action_params.keep_observation_id`.
- **`outdated_by_fact` response:** `mode`, `entity_id`, `name`, `fact_observation_id`, `searched` (false: no vectors and no terms), `judged`, `unjudged_over_cap`, `candidate_count`, `kept_by_guard`, `already_known`, `proposal_count`, `seeded_count` and `proposals` (`observation_id`, `entity_id`, `entity_name`, `project_id` (null when the entity has no project), `content`, `verdict` (`superseded` or `unjudged`), `confidence`, `reason`, `replacement`, `guard`, `guard_reason`, `signals`, `review_row_id`). It searches the fact's project only and never writes observations; apply a row with `apply_maintenance_review`.

## Search & Query Tools (3 tools)

#### `search`
- **Description:** Select summary, projected subgraph, or catalog mode from the presence of `query` and `include`, always returning a hash with `mode`.
- **Parameters:**
  - `query` (string, optional): Omit for catalog mode; provide for summary or subgraph mode.
  - `include` (array, optional): `observations` and/or `relations`; either selects subgraph mode.
  - `page` (integer, optional, default: 1): Page number.
  - `per_page` (integer, optional, default: 20, max: 100): Results per page.
  - `limit` (integer, optional): Legacy alias for `per_page`; ignored when `per_page` is present.
  - `search_in_name`, `search_in_type`, `search_in_aliases`, `search_in_observations` (boolean, optional, default: true): Which fields the query is matched against, in both summary and subgraph modes (summary mode used to ignore them). At least one must stay on. In summary mode, turning off name, type and aliases also skips the entity-vector channel (the entity embedding is built from those fields); turning off observations skips the observation-vector channel.
  - `project_id` (integer, optional): Only entities in this Project: the Project entity itself and its members. Must be the id of a Project root.
  - `entity_types` (array of strings, optional): Only entities of these types: 1-20, exact and case-insensitive; an unknown type matches nothing; `[]` is the same as omitting it.
  - `occurred_after` / `occurred_before` (string, optional): ISO 8601 bounds enabling the temporal recall channel (see [Temporal recall](#temporal-recall)).
  - `as_of` (string, optional): ISO 8601 point-in-time window; cannot be combined with `occurred_after`/`occurred_before`.
  - `perspective` (string, optional): Observation perspective hard filter — `world` surfaces only factual observations, `experience` only work-log entries; omitted returns both.
  - `max_tokens` (integer, optional): Pack ranked results under an estimated token budget (~4 chars/token); adds `retrieval.token_budget` diagnostics.
- **Responses:**
  - Summary: `{ mode: "summary", results, pagination, retrieval }`
  - Subgraph: `{ mode: "subgraph", entities, pagination, retrieval, relations? }`; observations are included on entities only when requested.
  - Catalog: `{ mode: "catalog", entities, pagination }`
- **Filters:** `project_id`, `entity_types` and `search_in_*` apply inside every channel before ranking (text, entity vectors, observation vectors, the temporal channel and its fallback, and subgraph candidates), so `page`/`per_page` page through the filtered ranking, `perspective` stays an independent observation filter, a temporal window ranks within the filtered entities and `max_tokens` packs the filtered page. They are hard filters, unlike the active context, which only boosts. When any of them narrows something, `retrieval.filters` echoes `{ project_id, entity_types, search_in }`; with all of them omitted the response is exactly as before. Errors (`category: "validation"`): `project_id must be the id of a Project entity.`, `entity_types must be a list of 1 to 20 non-blank entity types.`, `At least one search field (name, type, aliases, observations) must be enabled.`, and, in catalog mode (no `query`), `project_id and entity_types require a query.`
- **Temporal diagnostics:** when a temporal window applies (explicit params or parsed from `query`), `retrieval.temporal` reports the resolved `occurred_after`/`occurred_before`/`as_of`; `retrieval.token_budget` reports `{ max_tokens, estimated_tokens, truncated }` when `max_tokens` is passed.

#### `get_entities`
- **Description:** Retrieve one or more known entities with observations and an explicit relation projection. One unique ID defaults `relations` to `all`; multiple IDs default to `internal`.
- **Parameters:**
  - `entity_ids` (array, required): Entity IDs or resolvable names, returned in input order.
  - `relations` (string, optional): `all` incident edges or only `internal` edges.
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations.
  - `include_ranked` (boolean, optional, default: false): Sort observations by trust score descending.
  - `query` (string, optional): Rank observations by query relevance before trust.
  - `observation_limit` (integer, optional): Return at most this many observations per entity.
  - `occurred_after` / `occurred_before` (string, optional): ISO 8601 bounds restricting returned observations to a temporal window (see [Temporal recall](#temporal-recall)).
  - `as_of` (string, optional): ISO 8601 instant observations must cover; cannot be combined with `occurred_after`/`occurred_before`.
  - `perspective` (string, optional): Observation perspective hard filter — `world` surfaces only factual observations, `experience` only work-log entries; omitted returns both.
  - `max_tokens` (integer, optional): Pack entities then relations under an estimated token budget (~4 chars/token); adds `token_budget` diagnostics to the response.
- **Response:** `{ entities, relations, missing_entity_ids, relation_scope, token_budget? }`.

#### `summarize`
- **Description:** Summarize what the knowledge graph knows about a topic with deterministic source-backed evidence (optional LLM synthesis). Pass required `query` (string); optional `entity_id` (integer), `max_results` (integer, default 10), `max_observations` (integer, default 20), `observations_per_entity` (integer; 0 disables cap), `max_depth` (integer, default 0), `include_sources` (bool, default true), `scope` (string: context or global), `style` (string: concise or detailed). Do not use for match listings; use `search` instead. Do not use to inspect one known entity; use `get_entities` instead. Do not use for a structural neighborhood; use `traverse_graph` instead. Do not use for numeric health metrics; use `get_graph_stats` instead.
- **Parameters:**
  - `query` (string, required): The topic or question to summarize.
  - `entity_id` (integer, optional): Scope summarization to a single entity.
  - `max_results` (integer, optional, default: 10): Maximum entities to retrieve before ranking observations.
  - `max_observations` (integer, optional, default: 20): Maximum observations to include.
  - `max_depth` (integer, optional, default: 0): Optional graph traversal depth from matched entities.
  - `include_sources` (boolean, optional, default: true): Include source entity and observation IDs.
  - `scope` (string, optional, default: `context` when a project context is active, otherwise `global`): `context` hard-filters retrieval to the active project's recursive `part_of` subtree; `global` searches the full graph.
  - `style` (string, optional, default: `concise`): `concise` or `detailed`.
  - `occurred_after` / `occurred_before` (string, optional): ISO 8601 bounds restricting evidence to a temporal window (see [Temporal recall](#temporal-recall)).
  - `as_of` (string, optional): ISO 8601 instant evidence must cover; cannot be combined with `occurred_after`/`occurred_before`.
  - `max_tokens` (integer, optional): Cap the serialized evidence payload under an estimated token budget (~4 chars/token); adds `retrieval.token_budget` diagnostics.
- **Response fields:** `query`, `summary`, `generation_mode`, `generated_by`, `fallback_reason`, `scope`, `entity_count`, `observation_count`, `observations`, `sources`, `retrieval`
- **Retrieval diagnostics:** `scope_truncated`/`scope_max_entities` are vestigial (always `false`/`null` — project scope is an uncapped `project_id` lookup); `temporal` echoes the resolved window; `token_budget` reports packing when `max_tokens` is passed.

## Temporal recall

Read tools accept an optional temporal window that operates on *occurred time*,
using the existing observation columns — no new fields required:

- **Dated observations** (with `valid_from` and/or `valid_until`) match when
  their validity span intersects the window; open bounds count as infinite.
- **Undated observations** fall back to their retention time (`created_at`) —
  when the fact was learned. This mirrors the occurred-vs-mentioned split used
  by memory systems like Hindsight: `valid_*` = occurred, `created_at` =
  mentioned.
- `as_of` is a point window: dated observations must contain the instant;
  undated ones must have been retained by it. Note `as_of` only sees
  **currently active** observations — it is not a historical snapshot of the
  graph (obsoleted/superseded observations stay excluded).
- All temporal bounds are strict ISO 8601: `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or
  `YYYY-MM-DDTHH:MM[:SS][Z|±HH:MM]` — anything else is a validation error
  (`"invalid temporal bound (expected ISO 8601)"`). Bare year/month fragments
  widen to their covered period (`occurred_before: "2026-02"` means the end of
  February; `as_of: "2026"` means the end of 2026).
- A date-only bound (`"2026-01-31"`) is read as the start of that day for
  `occurred_after` and the end of that day for `occurred_before`/`as_of`, so a
  month boundary pair covers the whole month like the equivalent phrase.
  Date-only bounds are interpreted in the server's time zone (UTC) — pass a
  full ISO datetime with an offset for zone-exact bounds.

Two ways to apply a window:

1. **Explicit params** — `occurred_after`, `occurred_before`, `as_of` (ISO 8601)
   on `search`, `get_entities`, `summarize`, and the REST
   `GET /api/v1/memory_entities/search` and `POST /api/v1/summarize` endpoints.
2. **Query phrases** — `TemporalQueryParser` understands temporal expressions
   inside `query` itself: `"in October 2026"`, `"during 2024"`, `"2026-08"`,
   `"Q3 2026"`, `"last week"`, `"past 6 months"`, `"last spring"`,
   `"since 2025"`, `"since yesterday"`, `"between 2024 and 2025"`,
   `"as of 2026-06-01"`, etc. A bare year alone (e.g. just `"2024"`) is
   ignored — too likely an entity name. Month names come from a closed list,
   cue words need word boundaries, and seasons require a qualifier or a year —
   `"market"`, `"login 2024"`, `"2048-bit"` and `"spring boot config"` do not
   parse. Seasons map to northern-hemisphere astronomical spans
   (spring ≈ Mar 20–Jun 20, summer ≈ Jun 21–Sep 22, autumn/fall ≈ Sep 23–Dec 21,
   winter ≈ Dec 22–Mar 19; `this <season>` and `last <season>` without a year
   use the current or most recent span).
   Explicit params win over parsed phrases.

   Question filler words ("what", "changed", "tell me about", "show", …) are
   ignored when judging whether a date-windowed query is time-only, so
   `"what changed in august 2026"` searches by time alone. A few content-bearing
   words are filler too — `new`, `update`, `list`, `all`, `recent` — so
   `"update in august 2026"` is treated as a time-only query; search for the
   term itself without a date phrase to match on it.

When a window applies it does two things: adds a **temporal channel** to hybrid
search and **filters the observation payloads** in subgraph/fetch responses.
The channel re-weights entities that already matched the text/vector channels —
a window never injects unrelated entities next to a text hit; a query that is
*nothing but* a temporal phrase (`"what changed in October 2026"`) searches by
time alone, with the temporal channel as the base result set. The matched
phrase is stripped from the text used for lexical/vector matching, so
`"alpha in August 2026"` searches for "alpha" plus the window — and a
closed set of question filler words (`what`, `changed`, `happened`, `tell`,
`me`, `the`, `any`, `recent`, `stuff`, `learned`, …) is also ignored when
what remains would otherwise be meaningless: `"what changed in October 2026"`
leaves only filler, so it counts as time-only too. When a window is present
and residual terms match nothing at all, retrieval falls back to the time-only
listing instead of returning an empty page — reported as
`retrieval.temporal.fallback: "temporal_only"`. The resolved
window (and any matched phrase) is echoed back as `retrieval.temporal`.
Entities whose observations all fall outside the window still appear in
subgraph/fetch responses — with an empty `observations` list when nothing
matches the window.

### Token budget

All the same read tools accept `max_tokens` (integer 1–100_000, validated
strictly — digit strings like `"100"` coerce, anything else such as `"0x10"`,
`5.7`, `"1e3"` or `"+5"` is rejected): ranked payload items are packed in
order until the next item would exceed the estimate (~4 chars/token over the
serialized items, deterministic — no tokenizer dependency). Whole items only:
an item that cannot fit is dropped, never cut mid-item.

The budget applies to the page you asked for, not the whole ranked list —
the page slice is taken first, then packed. Items that don't fit on this
page do not move to the next one: next page, next pack. The surrounding
response envelope (mode, pagination, retrieval diagnostics) is estimated
once and counted against the budget as `envelope_tokens`, so a response
can't overrun because its own skeleton was free. When items were dropped
from the requested page, `retrieval.token_budget` reports
`{ max_tokens, estimated_tokens, truncated, dropped_on_page, ... }` and
`retrieval.next_move` suggests how to see the dropped ranks
("lower per_page or raise max_tokens"). Relations are only
dropped when an endpoint entity was removed by the budget itself — edges to
entities outside the fetched set stay (the far endpoint still exists). On
`summarize` the budget is applied to the evidence *before* the summary text,
sources and LLM prompt are built.

The budget estimate also reserves room for the MCP response wrapper
(`version`, `next_move`, and a `context` block when no project context is
active). Budgets below roughly 200 tokens can be smaller than the envelope
alone — the response is then flagged `truncated` with zero items even though
it exceeds the estimate; treat ~200 as the minimum useful `max_tokens`.

## Graph Traversal (2 tools)

These tools perform structural graph queries. `direction` is one of `outgoing`
(source -> target), `incoming` (target <- source), or `both` (default).

#### `traverse_graph`
- **Description:** Perform bounded BFS when `start_entity_id` is supplied, or query edges directly using endpoint/type filters. With no start or filters, returns all relations.
- **Parameters:**
  - `start_entity_id` (integer, optional): The entity to start BFS from. Also accepts entity name.
  - `from_entity_id`, `to_entity_id` (integer, optional): Direct edge filters.
  - `relation_type` (string, optional): Singular relation-type filter.
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to expand.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
  - `max_entities` (integer, optional, default: 100, max: 1000): Maximum number of entities to return.
  - `include` (array, optional): Any of `entities`, `relations`, and `traversal`.
- **Response:** BFS defaults to `{ entities, relations, traversal }`; relation-query mode defaults to `{ relations }`.
- **Caller lookup:** to list an entity's callers, use `direction: "incoming"` with `relation_types: ["calls"]`. There is no `get_callers` tool — the dedicated tool is permanently dropped in favor of this recipe.

#### `find_shortest_path`
- **Description:** Find the shortest hop-count path between two entities. Pass required `from_entity_id` and `to_entity_id` (integer; also accepts entity name); optional `max_depth` (integer, default 2, max 5), `direction` (both|outgoing|incoming, default both), `relation_types` (array of strings). Returns ordered path entities and relations, or found false when none exists within max_depth. Do not use for a full neighborhood from one start; use `traverse_graph` instead. Do not use for 1-hop filters; use `traverse_graph` instead. Do not use for keyword lookup; use `search` instead.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity. Also accepts entity name (string).
  - `to_entity_id` (integer, required): Target entity. Also accepts entity name (string).
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to search.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
- **Response:** `{ found, hop_count, direction, entities: [...], relations: [...] }`. When no path exists within `max_depth`, `found` is `false`, `hop_count` is `null`, and `entities`/`relations` are empty.

## Batch & Maintenance Tools (7 tools)

#### `suggest_merges`
- **Description:** Live vector scan of duplicate entities; returns pairs and does not merge. Pass optional `threshold` (float, default 0.3 cosine distance), `limit` (integer, default 20), `entity_type` (string). Do not use to execute a merge; use `merge_entities` instead. Do not use for queued dream-state review rows; use `list_maintenance_review` instead. Do not use for observation polarity conflicts; use `detect_contradictions` instead. Do not use for compaction job status; use `dream_state_status` instead.
- **Parameters:**
  - `threshold` (float, optional, default: 0.3): Maximum cosine distance (0 = identical, 1 = unrelated).
  - `limit` (integer, optional, default: 20): Maximum suggestions.
  - `entity_type` (string, optional): Filter to a specific entity type.
- **Response:** Array of `{ entity_a, entity_b, cosine_distance, recommendation }`

#### `dream_state_status`
- **Description:** Report the live dream-state compaction job (status, phase, cursor, stats, timestamps). Takes no arguments. Do not use for stored report documents; use `get_maintenance_reports` instead. Do not use for individual review-queue rows; use `list_maintenance_review` instead. Do not use for graph health totals; use `get_graph_stats` instead. Do not use for an on-demand duplicate scan; use `suggest_merges` instead.
- **Parameters:** None

#### `get_maintenance_reports`
- **Description:** Read stored maintenance report documents, not paginated review rows. Pass optional `report_type` (orphans, duplicates, compaction_review, embedding_maintenance, contradictions, or scan_review; omit for the latest of each type) and `limit` (integer, default 5, max 30). Do not use for paginated item_id rows; use `list_maintenance_review` instead. Do not use to apply or dismiss a row; use `apply_maintenance_review` or `dismiss_maintenance_review` instead. Do not use for live compaction job status; use `dream_state_status` instead. Do not use for a live duplicate scan; use `suggest_merges` instead.
- **Parameters:**
  - `report_type` (string, optional): One of `orphans`, `duplicates`, `compaction_review`, `embedding_maintenance`, `contradictions`, `scan_review`. Omit to get the latest report of each type.
  - `limit` (integer, optional, default: 5, max: 30): Maximum number of reports to return (applies when `report_type` is given).
- **Response:** `{ reports: [{ id, report_type, created_at, data }], total }`

#### `apply_maintenance_review`
- **Description:** Apply a queued maintenance-review row (merge, relationship proposal, orphan parent, or relation integrity). Pass required `item_id` (string UUID); optional `report_type` (string, default compaction_review), `dry_run` (bool, default false), `action_params` (hash). Do not use without a queue item_id; use `list_maintenance_review` first. Do not use to skip, ignore, or restore without applying; use `dismiss_maintenance_review` instead. Do not use to merge two known entity ids outside the queue; use `merge_entities` instead.
- **Parameters:**
  - `item_id` (string, required): Maintenance report row UUID.
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the row.
  - `dry_run` (boolean, optional, default: false): When true, validate and preview without applying. Since 1.58 the answer carries `preview`: `{ ok, effects, warnings, undo }`, what applying would do (the same lookups, no writes).
  - `action_params` (object, optional): Optional overrides for merge/relation/orphan endpoints; for a `contradiction` row, `keep_observation_id` (one of its two observations) is required: that one is kept and the other is marked obsolete. For a `fact_supersede` row (1.64.0): `fact_action` (`supersede` or `retire`) and `replacement` (text); without them it supersedes with the judge's replacement, or retires when there is none. The apply re-checks the fact, the project and the legacy guard, and records `outdated_by`.
- **Response:** Apply result hash (`success`, `message`, kind-specific fields such as `deleted_relation_ids`, and since 1.58 `change_set_uuid`, `undoable`, `not_undoable_reason`), or a dry-run preview with `kind` and `payload`.

#### `list_maintenance_review`
- **Description:** List paginated maintenance-review queue rows (including item_id) for later apply or dismiss. Pass optional `report_type` (string, default compaction_review), `status` (active, dismissed, approved, ignored, or expired; default active), `kind` (string, e.g. entity_merge or orphan_parent), `page` (integer, default 1). per_page is not an input. Do not use for whole report documents; use `get_maintenance_reports` instead. Do not use to apply a row; use `apply_maintenance_review` instead. Do not use to dismiss, ignore, or restore a row; use `dismiss_maintenance_review` instead. Do not use to merge two known entity ids; use `merge_entities` instead.
- **Parameters:**
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the rows.
  - `status` (string, optional, default: `active`): Row status filter: `active`, `dismissed`, `approved`, `ignored`, `expired`.
  - `kind` (string, optional): Row kind filter, e.g. `entity_merge` or `orphan_parent`.
  - `page` (integer, optional, default: 1): 1-based page. Response `per_page` is fixed at 50.
- **Response:** `{ report_type, status, kind, page, per_page, total_count, total_pages, items: [{ item_id, kind, status, payload, ... }] }`

#### `dismiss_maintenance_review`
- **Description:** Dismiss, ignore, or restore a maintenance-review queue row without applying the suggestion. Pass required `item_id` (string UUID) and `action` (dismiss, ignore, or restore); optional `report_type` (string, default compaction_review), `reason` (string). Do not use to execute the suggestion; use `apply_maintenance_review` instead. Do not use to look up a row; use `list_maintenance_review` instead. Do not use to merge entities; use `merge_entities` instead.
- **Parameters:**
  - `item_id` (string, required): Maintenance report row UUID.
  - `action` (string, required): One of `dismiss`, `ignore`, `restore`. `ignore` snoozes an active row for 30 days: it comes back afterwards, and its suggestion isn't proposed again until then. A dismissed, approved or expired row can't be ignored (restore it first).
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the row.
  - `reason` (string, optional): Optional dismissal reason.
- **Response:** Updated review-row status payload.

#### `get_graph_stats`
- **Description:** Return live knowledge-graph health metrics (totals, entity_type_distribution, orphan_count, most_connected, god_nodes, recent updates). `god_nodes` lists entities whose total incident-edge count exceeds 100 (capped at 10) plus `god_node_count`. Takes no arguments. Do not use for stored report documents; use `get_maintenance_reports` instead. Do not use to page actual entities; use `search` instead. Do not use for a topic summary; use `summarize` instead. Do not use for compaction job status; use `dream_state_status` instead. Software version is included in every successful response.
- **Parameters:** None

## Utility Tools (1 tool)

#### `get_current_time`
- **Description:** Return the current server time as an ISO 8601 string. Takes no arguments; software version is included in every successful response. Do not use for graph health metrics; use `get_graph_stats` instead. Do not use to set observation validity windows; use `graph_write` or `graph_edit` instead.
- **Parameters:** None

## Project Source Scan (2 tools)

#### `scan_project`
- **Description:** Enqueue an asynchronous filesystem scan that reconciles the knowledge graph with a project root; returns a scan_id and does not wait. Pass required `project_root` (string); optional `project_name` (string), `aliases` (comma- or pipe-separated string), `mode` (initial, rescan, or validate; default initial), `dry_run` (bool), `file_globs` (array of strings), `scan_id` (string, resume a paused validation batch). Do not use to poll completion; use `scan_project_status` instead. Do not use to create a single node by hand; use `graph_write` instead. Do not use to scope searches to a project already in the graph; use `set_context` instead.
- **Parameters:**
  - `project_root` (string, required): Absolute path of the project folder, under the operator's scan folders (hidden folders are never scannable).
  - `project_name` (string, optional): Preferred project name. Defaults to the directory name or the LLM-extracted name.
  - `aliases` (string, optional): Comma- or pipe-separated aliases for the project root entity.
  - `mode` (string, optional): `initial`, `rescan`, or `validate`. Default: `initial`.
  - `dry_run` (boolean, optional): When `true`, preview changes without writing to the graph.
  - `file_globs` (array of strings, optional): Optional file globs to scan, relative to `project_root`.
  - `scan_id` (string, optional): Existing scan operation_id to resume a paused validation batch. If omitted, a new scan is started.
- **Response:** `{ scan_id, status: "queued", project_root, mode, dry_run }`. The scan is recorded as `pending` before the reply, so `scan_project_status` finds the `scan_id` at once, even before a job worker starts it.
- **Refusals:** a `validation` error with `code` (`not_mounted`, `denied`, `outside_filter`, `not_found`, `invalid_file_globs`, …) and a `next_move` for that reason. A `scan_id` resumes only a paused scan; a queued, running or finished scan's id (or another operation's) is refused with `scan_id_not_resumable` and nothing is queued. Two concurrent resumes of one paused scan queue a single job.

#### `scan_project_status`
- **Description:** Poll one asynchronous project scan for status, phase, progress, counters, fallback flags, and scan_review items. Pass required `scan_id` (string from `scan_project`). Do not use to start or resume a scan; use `scan_project` instead. Do not use for compaction-job status; use `dream_state_status` instead. Do not use for stored scan_review documents; use `get_maintenance_reports` instead.
- **Parameters:**
  - `scan_id` (string, required): The scan ID returned by `scan_project`.
- **Response:** `{ scan_id, status, phase, message, progress, counters, details, fallback, fallback_reason, scan_review_items, started_at, finished_at, error }`
- **Scan parts (1.66.0):** `counters.parts_total`, `parts_failed`, `files_too_large` and `files_over_budget`, and `details.extraction` (parts done and failed, files read and left out, the input budget, `num_ctx`, `num_predict`, and `partial: true` on a partial scan only). `details.partial` is always set. A partial scan marks nothing missing; see [summarization](summarization.md#project-scans).

## Entity Type Canonicalization

GraphMem automatically normalizes entity types. When creating or updating entities, the `entity_type` field is looked up in the `entity_type_mappings` table. Known variants are rewritten to their canonical form.

Data-exchange import matching and execution share the same canonicalization via `ImportEntityResolver`: an existing entity is reused only on exact name **and** canonical type. A same-name node of another type is not a match (no name-only fallback), so observations and relations stay on the correctly typed entity.

| Canonical Type | Accepted Variants |
|---|---|
| Project | project, workspace, context, repo, repository, codebase |
| Task | task, todo |
| Issue | issue, bug, problem |
| Error | error, exception |
| PossibleSolution | solution, workaround, fix |
| Service | service |
| Component | component, widget |
| ... | (see `db/seeds/entity_type_mappings.rb` for full list) |

## Vector Search Architecture

GraphMem uses MariaDB 11.8's native VECTOR columns with the MHNSW algorithm for approximate nearest-neighbor search:

1. **Embedding generation**: On entity create/update, the `EmbeddingService` calls Ollama to generate a 768-dimensional vector from the entity's composite text (type + name + aliases + description).
2. **Storage**: Vectors are stored in `VECTOR(768)` columns with cosine distance indexes.
3. **Search**: `VectorSearchStrategy` embeds the query and finds nearest entities via `VEC_DISTANCE_COSINE`.
4. **Hybrid fusion**: `HybridSearchStrategy` merges text and vector results using Reciprocal Rank Fusion (RRF). When a project context is active, in-context entities receive a score boost.

The embedding service is configurable via **System › Settings › Embeddings** (AppSettings) or environment variables (`OLLAMA_URL`, `EMBEDDING_MODEL`, etc.). Resolution priority: AppSettings → ENV → defaults. It gracefully degrades when unavailable.

## Error Handling

MCP `tools/call` failures return `isError: true` with a **single JSON object** as the text content. There is no `Error:` prefix and no Ruby backtrace in the payload. Tools still raise typed exceptions from `call`; FastMCP serializes them at the protocol boundary.

```json
{
  "error": true,
  "category": "not_found",
  "retriable": false,
  "next_move": "Call `search` to verify the identifier, then retry with a known id.",
  "message": "Entity with ID=123 not found.",
  "tool": "get_entities"
}
```

Some errors add a `code` naming the exact reason, for agents that branch on it: `scan_project` refusals (`not_mounted`, `denied`, `outside_filter`, `not_found`, `invalid_file_globs`, … the codes `ScanRootPolicy` returns) and `graph_delete` on a Project (`project_delete_needs_maintenance`, `project_has_members`). The key is absent when there is no code. stdio returns the same envelope as HTTP.

`next_move` is an imperative instruction for the calling agent. It names a sibling tool in backticks when that tool can produce a valid retry input.

| Category | `retriable` | Typical next move |
|---|---|---|
| `not_found` | false | Call `search`, then retry with a known id |
| `validation` | false | Correct the argument format required by the tool schema and retry |
| `permission` | false | Escalate to a human; this client is not authorized |
| `timeout` | true | Retry the tool once, then inform the user of the delay |
| `rate_limit` | true | Wait and retry with backoff (reserved until a limiter exists) |
| `system_error` | false | Escalate to a human; do not retry blindly |

Exception mapping:

- `McpGraphMemErrors::ResourceNotFound` → `not_found`
- `GraphMem::InvalidArgumentsError` (argument validation failures) → `validation`, except entity-name misses (`Entity not found by name`) → `not_found`
- `McpGraphMemErrors::OperationFailed` → `system_error` unless the call site sets `category: "validation"` for a caller-correctable policy
- `McpGraphMemErrors::InternalServerError` and unknown `StandardError` → `system_error` (generic message; original exception is logged server-side)
- `Timeout::Error` / `Net::OpenTimeout` / `Net::ReadTimeout` → `timeout`
- Unauthorized tool calls → `permission`

Empty states that are **not** errors:

- `get_context` `{ status: "no_context" }` is a successful empty state
- A missing `scan_project_status` scan **is** an error (`ResourceNotFound`), not `{ status: "not_found" }`

## Tool Overlap Guide

Some tools overlap by design; pick by intent:

| Goal | Prefer | Alternative |
|---|---|---|
| Find entities by keyword/semantic match | `search` | `search` (when you also need observation text and relations in one payload) |
| Page every entity with no query | `search` | `search` (when you have a query) |
| Load known entities by ID | `get_entities` | `get_entities` (single entity with full detail) |
| Explore multi-hop neighborhoods | `traverse_graph` | `traverse_graph` (single-hop edges only) |
| Find how two entities connect | `find_shortest_path` | `traverse_graph` (full neighborhood) |
| Review duplicate entities (live scan) | `suggest_merges` | `list_maintenance_review` (dream-state queue rows) |
| Inspect stored maintenance reports | `get_maintenance_reports` | `list_maintenance_review` (paginated item_id rows) |
| Inspect background compaction state | `dream_state_status` | `get_graph_stats` (live graph totals, not job status) |
| Apply a queued review | `apply_maintenance_review` | `graph_delete` `merge_entities` operation (known source/target ids) |
| Skip a queued review | `dismiss_maintenance_review` | `apply_maintenance_review` (to execute it) |
| Execute a merge of known ids | `graph_delete` `merge_entities` operation | `apply_maintenance_review` (queued merge) |
| Summarize what the graph knows about a topic | `summarize` | `search` + manual reading |
| Poll a project filesystem scan | `scan_project_status` | `scan_project` (to start or resume) |

## Dream-State Background Compaction

Solid Queue runs `DreamStateCompactionJob` on a schedule (`config/recurring.yml`). The job:

1. **Orphans phase** -- matches orphan nodes to `Project` roots; auto-parents high-confidence token matches
2. **Tree-walk phase** -- walks each project subtree; deduplicates identical observations; auto-merges entities with cosine distance &lt; 0.10
3. **Review queue** -- writes lower-confidence items to `maintenance_reports` (`compaction_review`), readable via `get_maintenance_reports`

Mutating tools and the heavy maintenance tools (`summarize`, `suggest_merges`, `detect_contradictions`, the review apply/dismiss) cooperatively **pause** an active compaction run (`CompactionValve`) so live MCP traffic takes priority. Paused runs resume from `cursor_entity_id` on the next trigger.

To close the loop on the review queue: call `list_maintenance_review`, inspect the suggested merges/parents, and apply the good ones with `apply_maintenance_review` (or the `graph_delete` `merge_entities` operation when both entity ids are already known).

## Best Practices

1. **Set `X-MCP-Client`** in your MCP config when multiple agents share one GraphMem instance.
2. **Use `set_context`** at the start of each session to scope searches to the active project.
3. **Search before create** to avoid duplicates (auto-dedup catches some, not all).
4. **Use `graph_write`** (one batch of `operations`) for session-end "save what I learned" writes.
5. **Run `suggest_merges`** or check `dream_state_status` for compaction progress and review queues.
6. **Keep observations concise** and factual for better embedding quality.
7. **Clear context** (`set_context` with `entity_id: null`) when switching between projects.
