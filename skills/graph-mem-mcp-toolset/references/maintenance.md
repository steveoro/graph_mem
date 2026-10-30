Read `references/maintenance.md` when connected to `/mcp/maintenance` or acting on maintenance review rows.

# graph_mem maintenance reference

*For maintenance-profile sessions (`/mcp/maintenance`): `scan_project`, `dream_state_status` and the review-queue tools aren't on the default connection, and default-profile agents need none of this (mutating tools pause compaction automatically).*

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

## Source facts: what a fact outdates

- A source fact is an active observation tagged `source-fact` on an entity inside a project
  (or the Project root). When one is written or its text changes, graph_mem looks in **that
  project only** for observations it may outdate (similar text, the fact's `replaces:<term>`
  tags), asks the local LLM judge when it is available, and queues `fact_supersede` review rows
  ("Outdated by a fact"). Age is never evidence; statements about another project, a version,
  an environment or a work log are kept or marked `context`.
- To run it yourself on `/mcp/maintenance`: `detect_contradictions` with
  `mode: "outdated_by_fact"`, `entity_id` = the fact's entity, `fact_observation_id`, optional
  `terms` (up to 5) and `seed_review` (default true), `max_results` at most 50. It returns the
  proposals with their review row ids and never writes observations.
- Read the rows with `list_maintenance_review` (`kind: "fact_supersede"`) and apply one with
  `apply_maintenance_review`: `action_params.fact_action` is `supersede` (with an optional
  `replacement` text) or `retire`. The apply re-checks the fact, the project and the guard, and
  is undoable. Dismiss a row when the fact doesn't outdate it: the pair stays suppressed.

## Dream-State Compaction Awareness

- A background "dream-state" job periodically compacts the graph: it
  auto-parents orphans, auto-merges near-identical entities (cosine distance <
  0.10, same `entity_type` only), and deletes byte-identical duplicate
  observations. Lower-confidence cases are queued for review.
- On `/mcp/maintenance`, call `dream_state_status` to see whether compaction is `running`/`paused` plus its progress/stats.
- Call `list_maintenance_review` to read the queue of merge/orphan suggestions the job flagged for review, then action good ones with `apply_maintenance_review` (or a `graph_delete` `merge_entities` operation when both ids are known). Use `get_maintenance_reports` for stored report documents.
- Mutating tools cooperatively pause compaction automatically — no action needed, but search results may shift slightly while a run is in progress.
- Implication for writes: don't rely on the job to clean up sloppiness. Prefer
  `graph_write` on an existing entity or `graph_edit` over creating
  near-duplicates. Mutating tools may pause compaction, so do not assume that
  maintenance state is unchanged during a session.

## From the skill: dream-state and the review queue

- A background dream-state job auto-parents orphans, auto-merges near-identical
  entities (cosine < 0.10), and dedupes identical observations. Lower-confidence
  cases are queued for review.
- Maintenance tools are available on `/mcp/maintenance`, not the default connection.
- `dream_state_status` reports whether compaction is running/paused plus stats.
- `list_maintenance_review` returns queued merge/orphan rows; action good ones with `apply_maintenance_review` (or a `graph_delete` `merge_entities` operation when both entity ids are known). Use `get_maintenance_reports` for stored report documents, not row pagination.
- Mutating tools auto-pause compaction, so no coordination is needed — but
  search results may shift slightly mid-run.
