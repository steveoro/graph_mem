---
description: GraphMem MCP usage rules (Knowledge Graph session workflow)
globs:
alwaysApply: true
---

# Graph Memory — 4-Phase Session Workflow

These rules apply whenever the `graph_mem` MCP toolset is configured for your
session — including sessions where you are developing graph_mem itself.
Use the `graph_mem` MCP tools every session. "Knowledge graph", "graph mem", and
"memory graph" all refer to the same toolset. Treat this workflow as session
state management, not as a substitute for inspecting the repository.

The default `/mcp` connection omits maintenance tools. Use a separate
`/mcp/maintenance` connection only when maintenance work is required; the
`/mcp/readonly` profile exposes context and read tools only.

## Workflow Prompts

Use the server's MCP prompts instead of carrying the full procedure in every
client context:

- `orient` at session start
- `recall(topic)` before work
- `persist` before ending

Successful tool responses also provide concise `next_move` guidance and a
no-context banner when orientation is required.

## MCP Tool Errors

Tool `isError` content is a JSON envelope with `category`, `retriable`, `next_move`,
and `message`. Follow `next_move`. Do not retry `system_error` blindly.
See `docs/mcp_tools.md` Error Handling for the category table.

## Multi-Agent Context Scoping

- Context is **per-agent**, keyed by the `X-MCP-Client` header, and persisted in the DB (survives restarts).
- `set_context` affects ONLY your own client bucket; pass `entity_id: null` to clear it.
- Agents without the header share the `"default"` bucket. Set a stable `X-MCP-Client` in your MCP config when multiple agents use one instance.
- Because context persists, on Orient you may already have an active context from a prior session — always `get_context` first before assuming none.

## Project Scan Validation

- `scan_project(project_root, project_name, aliases, mode, dry_run, file_globs)` starts an
  asynchronous source-scan of a project root. It treats the files as the source of truth,
  reconciles the graph, and then runs an automatic facts-checking pass over the existing
  project subtree.
- The final validation pass is implemented in the `ProjectScanValidator` service and
  is gated by `enable_project_scan_validation`.
- It is batched and resumable:
  - `project_scan_validation_batch_size` (default `5`) controls how many entities
    are validated per batch. `0` disables batching.
  - When the batch limit is reached, the `OperationProgress` is paused and
    `validation_state` is persisted. A subsequent `mode: "validate"` scan with the
    same `scan_id` resumes from the saved pending entity list.
  - This lets an agent or operator digest the generated `scan_review` queue in
    small, repeated rounds instead of one massive run.
- It distinguishes scan-sourced observations from manually-created ones:
  - Scan-sourced observations (`source` starts with `project_scan:` or
    `project_scan_skill:` from a prior run) can be moved or obsoleted automatically.
  - Manual/sourceless observations are never silently deleted. They are queued as
    `move_observation` or `delete_observation` `scan_review` items so the
    operator/agent can decide; the scan conclusion is preserved in the review payload.
- Skips entities, observations, and relations created during the same scan run
  (identified by the per-run source ref `project_scan:<scan_id>:<phase>` and
  `MemoryRelation#properties["scan_id"]`).
- Moves scan-sourced observations to a better-matching target entity when the target
  is unambiguous (the target name/alias appears as a whole word or phrase in the
  observation text and the text does not reference its current entity or project).
- Marks scan-sourced observations that do not reference their entity or project and
  have no clear target as `obsolete` with `confidence: 1.0`.
- Handles relation ownership semantics:
  - `part_of` is an ownership edge: a `MemoryEntity` may have only one `part_of`
    parent. A `part_of` relation to the wrong `Project` root is corrupt and is
    auto-deleted.
  - `used_by`, `depends_on`, `requires`, `configured_by`, `implements`, `extends`,
    and `integrates_with` are reference/usage edges. Stale ones are queued as
    `delete_relation` review items, not auto-deleted.
- Queues stale usage relations (`delete_relation`), entities that no longer appear
  in the source (`delete_entity`), observations that do not belong (`delete_observation`),
  and wrong-parent moves (`reparent_entity`, `move_observation`) as `scan_review`
  maintenance rows.
- Use `mode: "validate"` to run only the validation pass on an existing project
  without re-reading files.
- Agents can consume `scan_review` rows via `get_maintenance_reports(report_type:
  "scan_review")` and apply `move_observation`, `reparent_entity`, `delete_relation`,
  `delete_entity`, or `delete_observation` actions just like compaction reviews.

## Dream-State Compaction Awareness

- A background "dream-state" job periodically compacts the graph: it
  auto-parents orphans, auto-merges near-identical entities (cosine distance <
  0.10, same `entity_type` only), and deletes byte-identical duplicate
  observations. Lower-confidence cases are queued for review.
- Call `dream_state_status` to see whether compaction is `running`/`paused` plus its progress/stats.
- Call `list_maintenance_review` to read the queue of merge/orphan suggestions the job flagged for review, then action good ones with `apply_maintenance_review` (or a `graph_delete` `merge_entities` operation when both ids are known). Use `get_maintenance_reports` for stored report documents.
- Mutating tools cooperatively pause compaction automatically — no action needed, but search results may shift slightly while a run is in progress.
- Implication for writes: don't rely on the job to clean up sloppiness. Prefer
  `graph_write` on an existing entity or `graph_edit` over creating
  near-duplicates. Mutating tools may pause compaction, so do not assume that
  maintenance state is unchanged during a session.

## Standard Compatibility

graph_mem accepts both its native snake_case/ID-based parameters and the
`@modelcontextprotocol/server-memory` camelCase/name-based conventions:

- Entity references accept either `entity_id` (integer) or entity name (string).
- Traversal references (`start_entity_id`, `from_entity_id`, `to_entity_id`) also accept entity IDs or names.
- Field names accept camelCase (e.g. `entityType`) or snake_case (`entity_type`).
- `graph_write` accepts either three arrays (`entities`, `observations`, `relations`) or a single `operations` array with `type`-discriminated items.
- Observation text accepts `text_content`, `content`, or `contents` (array).
- Relation endpoints accept `from_entity_id`/`to_entity_id` (int), `from`/`to` (name), or `from_entity`/`to_entity` (name).
- Use native snake_case keys by default. Compatibility aliases are for
  interoperating clients, not a reason to mix naming styles in one request.

## Query and Type Guidance

Use the `recall` prompt for query strategy. Canonical type examples are
published as soft `graph_write` schema examples; novel types remain valid.

## Observations

- Keep observations **crisp and factual**; include timestamps and code paths where relevant.
- For longform content, write to `/docs` and store the file path as an observation.
- Keep generated summaries ephemeral unless persistence is explicitly requested.
  `summarize` always derives evidence from the current active graph and returns
  source entity/observation IDs; never treat IDs or claims emitted by an LLM as
  authoritative.
- The deterministic evidence path is authoritative and always available.
  LLM synthesis is optional; provider failure, missing configuration, or a
  disabled feature must degrade to deterministic output without exposing
  credentials or internal exception details.

## Conflict Handling

1. Note the conflict as an observation on the relevant entity.
2. Research (graph history / web / user) to resolve.
3. Update the graph: new observations, mark outdated ones, edit entity if needed.
4. Record the resolution; inform the user if open questions remain.
