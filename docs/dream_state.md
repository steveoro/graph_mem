# Dream-State Compaction

GraphMem's **dream-state** mode is a background compaction pipeline that periodically optimizes the knowledge graph while MCP clients are idle or between batches. It auto-parents orphan nodes, deduplicates identical observations, and auto-merges near-duplicate entities—queuing lower-confidence cases for operator or agent review.

The name evokes offline consolidation: work happens in the background on a predictable schedule, similar to how biological systems consolidate memory during sleep.

## Purpose

Agent sessions routinely produce graph clutter:

- **Structural orphans** — entities not linked under any `Project` via `part_of` or `depends_on`
- **Observation noise** — the same fact stored multiple times on one entity
- **Near-duplicate entities** — separate nodes that embeddings show are semantically almost identical

Dream-state compaction reduces search noise, keeps project hierarchies coherent, and shrinks redundant storage—without blocking live MCP traffic.

## Architecture

```
Solid Queue (recurring.yml)
        │
        ▼
DreamStateCompactionJob ──(re-enqueue while :continued)──┐
        │                                                │
        ▼                                                │
DreamStateCompactor.process_batch!  ◄────────────────────┘
        │
        ├── CompactionTraversal     (phase entity lists)
        ├── OrphanMatchingStrategy  (token match to Projects)
        └── NodeOperationsStrategy  (move_to_parent, merge_into)

CompactionRun (DB)  ←── cursor, phase, stats, pause state
CompactionValve     ←── cooperative pause from MCP tools
```


| Component                 | Location                                  | Role                                                                      |
| ------------------------- | ----------------------------------------- | ------------------------------------------------------------------------- |
| `DreamStateCompactionJob` | `app/jobs/dream_state_compaction_job.rb`  | Processes one batch per invocation; re-enqueues itself while work remains |
| `DreamStateCompactor`     | `app/strategies/dream_state_compactor.rb` | Core compaction logic for each phase                                      |
| `CompactionRunner`        | `app/services/compaction_runner.rb`       | Starts/resumes runs; exposes `status_snapshot` for MCP and dashboard      |
| `CompactionRun`           | `app/models/compaction_run.rb`            | Persists run state, cursor, and cumulative stats                          |
| `CompactionTraversal`     | `app/strategies/compaction_traversal.rb`  | Deterministic entity ordering per phase                                   |
| `CompactionValve`         | `app/services/compaction_valve.rb`        | Requests cooperative pause when MCP tools need the graph                  |




## Compaction phases

Each run progresses through three phases in order:

### Phase 1: `orphans`

**Entity set:** All non-`Project` entities with no incoming `part_of` or `depends_on` relation (`OrphanMatchingStrategy#orphan_nodes`).

**Per entity:**

1. Tokenize the orphan name and score matches against every `Project` name and aliases.
2. If the best match scores **≥ 10** (`AUTO_ORPHAN_SCORE`), call `NodeOperationsStrategy#move_to_parent` to create a `part_of` link.
3. Otherwise, queue the orphan for review in a `compaction_review` report.

**Scoring highlights** (from `OrphanMatchingStrategy`):


| Match type                   | Score |
| ---------------------------- | ----- |
| Exact token in project name  | +10   |
| Substring in project name    | +5    |
| Exact token in project alias | +8    |
| Substring in project aliases | +3    |




### Phase 2: `tree_walk`

**Entity set:** Breadth-first walk of each `Project` subtree, following outgoing `part_of` and `depends_on` edges from children to parents (queue starts at all `Project` roots ordered by ID).

**Per entity:**

1. **Observation deduplication** — for each duplicate `content` on the entity, keep the lowest `id` and delete the rest.
2. **Entity merge scan** — if the entity has an embedding and is not a `Project`:
  - Find up to 3 candidates with cosine distance **< 0.30** (`REVIEW_MERGE_DISTANCE`), excluding Projects, requiring `id > entity.id` for deterministic ordering.
  - If distance **< 0.10** (`AUTO_MERGE_DISTANCE`), auto-merge via `NodeOperationsStrategy#merge_into`.
  - Otherwise, queue a merge review item.

`Project` entities are never auto-merged or queued for merge review.

### Phase 3: `relationship_discovery`

**Entity set:** All non-`Project` entities ordered by ID.

**Per entity:** `RelationshipDiscoveryStrategy` scans observation text and entity metadata for explainable link candidates. Proposals are **review-only** — dream-state never auto-creates inferred relations.

**Current rules:**

| Rule | Relation type | Evidence |
|------|---------------|----------|
| Shared observation phrase | `relates_to` | Byte-identical observation content on two entities (minimum length 15) |
| Issue/solution pairing | `solves` | `PossibleSolution` + `Issue` observations sharing topic tokens, with fix/solve vs block/problem language |
| Named dependency | `depends_on` | Observation contains dependency language and references another entity by name or alias |

Each proposal is queued as `relationship_proposal` with `from_entity_id`, `to_entity_id`, `relation_type`, `confidence_band`, `score`, `supporting_observation_ids`, `explanation`, and optional `evidence_terms`.

Safety filters: no self-links, no duplicate same-direction relations, no Project-root involvement, allowed relation types only, max 3 proposals per entity per run.

To accept a proposal: inspect `get_maintenance_reports(report_type: "compaction_review")`, then create the relation manually (web UI or `create_relation`).

## Batch processing and cursor

Compaction is **incremental**, not monolithic:

- `BATCH_SIZE = 5` entities per job invocation
- `CompactionRun#cursor_entity_id` records the last processed entity; the next batch resumes after it
- When a phase's entity list is exhausted, the run advances to the next phase (or marks `completed`)

`DreamStateCompactionJob` returns:


| Result       | Job behavior                                           |
| ------------ | ------------------------------------------------------ |
| `:continued` | Re-enqueue immediately with the same `run_id`          |
| `:paused`    | Stop; resume on next scheduled trigger or manual start |
| `:completed` | Stop; run marked finished                              |


Failed runs store the error message in `stats["error"]` and set status to `failed`. `CompactionRunner#acquire_run!` can resume a failed run when no other active run exists.

## Cooperative pause (CompactionValve)

Live MCP traffic takes priority over background compaction.

Before executing, these MCP tools call `CompactionValve.request_pause_if_running!`:

`bulk_update`, `create_entity`, `create_observation`, `create_relation`, `delete_entity`, `delete_observation`, `delete_relation`, `update_entity`, `merge_entities`, `search_entities`, `search_subgraph`, `suggest_merges`

When a compaction run is `running`:

1. The valve sets `pause_requested` on the active `CompactionRun`.
2. The compactor checks the flag after each entity in the current batch; if set, it flushes pending review items, pauses the run, and yields.
3. The valve polls up to **3 seconds** for the run to reach `paused` status.

Operators can also pause manually from the dashboard (`POST /operator/maintenance/pause_compaction`).

Paused runs resume from `cursor_entity_id` on the next scheduled job or when an operator clicks **Start / Resume**.

## Review queue (`compaction_review`)

Items that are not safe to apply automatically are batched into `MaintenanceReport` rows with `report_type: "compaction_review"`.


| `kind`          | Contents                                                                     |
| --------------- | ---------------------------------------------------------------------------- |
| `orphan_parent` | Orphan entity, top 3 suggested `Project` parents with scores, optional error |
| `entity_merge`  | Two entities, cosine distance, `recommendation: "review_manually"`           |
| `relationship_proposal` | Suggested link with relation type, confidence band, supporting observation IDs, explanation |


Reports are flushed at the end of each batch and when advancing phases. Read them via:

- **MCP:** `get_maintenance_reports(report_type: "compaction_review")`
- **Dashboard:** Dream State card → "Compaction review queue" details

To action a queued merge: inspect the report, then call `merge_entities(source_entity_id:, target_entity_id:)`.

To action a queued relationship proposal: inspect the evidence, then call `create_relation(from_entity_id:, to_entity_id:, relation_type:)`.

## Run stats

`CompactionRun#stats` accumulates counters during a run:


| Key                    | Meaning                            |
| ---------------------- | ---------------------------------- |
| `entities_processed`   | Entities visited across all phases |
| `orphans_parented`     | Orphans auto-linked to a Project   |
| `orphans_queued`       | Orphans sent to review             |
| `observations_deduped` | Duplicate observation rows removed |
| `merges_auto`          | Entities auto-merged               |
| `merges_queued`        | Merge pairs sent to review         |
| `relationships_queued` | Relationship proposals sent to review |
| `error`                | Present when status is `failed`    |




## Scheduling and configuration



### Recurring schedule


| Environment     | Schedule             |
| --------------- | -------------------- |
| **production**  | Daily at 3:00 AM GMT |
| **development** | Every hour           |


Times are GMT as noted in `config/recurring.yml`.

### Feature flag


| Setting                        | Default | Effect                                                           |
| ------------------------------ | ------- | ---------------------------------------------------------------- |
| `enable_dream_state_compactor` | `true`  | When `false`, scheduled and manual compaction starts are skipped |


Configure under **Operator → System Settings → Feature Flags**.

## Operator controls

The dashboard **Dream State / Compactor Run** card shows:

- Run status badge (`idle`, `running`, `paused`, `completed`, `failed`)
- Phase stepper (`orphans` → `tree_walk` → `relationship_discovery`)
- Cursor entity, pause flag, timestamps, duration
- Live stat chips
- **Pause** / **Start / Resume** buttons
- **Repair relation duplicates** when a failed run may be caused by relation integrity issues

Manual start enqueues `DreamStateCompactionJob` via `CompactionRunner.start_or_resume!`.

## MCP tools


| Tool                      | Purpose                                                                                              |
| ------------------------- | ---------------------------------------------------------------------------------------------------- |
| `dream_state_status`      | Returns `dream_state`, `run_id`, `phase`, `cursor_entity_id`, `pause_requested`, `stats`, timestamps |
| `get_maintenance_reports` | Read `compaction_review` queue and other maintenance reports                                         |
| `merge_entities`          | Apply a queued merge suggestion (also triggers cooperative pause if compaction is running)           |
| `suggest_merges`          | On-demand duplicate search (separate from dream-state auto-merge thresholds)                         |


Agents should call `dream_state_status` for a cheap health check and `get_maintenance_reports(report_type: "compaction_review")` to drain the review queue.

## Relation integrity recovery

Compaction merges and moves assume relations are well-formed. Duplicate or conflicting relation rows can cause `merge_into` to fail with uniqueness errors.

`RelationIntegrityRepairer` (`app/services/relation_integrity_repairer.rb`) scans for:

- Same-direction duplicates — multiple rows for the same `(from, to, type)`
- Reverse pairs — `A→B` and `B→A` with the same type
- Merge collisions — one child linked to multiple parents with the same relation type

The dashboard **Repair relation duplicates** button runs the repairer, then operators can **Start / Resume** compaction.

## Safety guarantees

- `Project` **roots are protected** — never auto-merged, never deleted by compaction logic (`NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR`).
- **Deterministic traversal** — sorted IDs and `id > entity.id` merge ordering make runs reproducible.
- **Review band** — cosine distance between **0.10** and **0.30** requires human or agent confirmation.
- **Low-confidence orphans** — token scores below **10** are never auto-parented.



## Dream-state vs. garbage collector


|                     | Dream-state compactor          | Garbage collector                        |
| ------------------- | ------------------------------ | ---------------------------------------- |
| **Mutates graph?**  | Yes                            | Yes (through `GraphIntegrityService`)    |
| **Orphan handling** | Auto-parent or queue           | Report only (stricter orphan definition) |
| **Duplicates**      | Deletes identical observations | Deletes duplicate observations           |
| **Entity merges**   | Auto-merge when cosine < 0.10  | —                                        |


The garbage collector still creates diagnostic reports, but it now actively deletes duplicate observations and repairs `memory_observations_count` counters. A brand-new compaction run also runs `GraphIntegrityService` before processing to repair relation integrity and stale counters. Per-entity failures inside `tree_walk` are logged and skipped instead of halting the whole run.

See [garbage_collector.md](garbage_collector.md) for details on the self-healing GC job.

## Acceptance and usefulness benchmark

GraphMem includes a deterministic integration benchmark that exercises the real dream-state pipeline end to end:

- **Spec:** `spec/integration/dream_state_usefulness_spec.rb`
- **Helpers:** `spec/support/dream_state_acceptance_helper.rb`
- **Tag:** `:with_test_embeddings` (enables MariaDB `VEC_FromText` test vectors without Ollama)

### What the passing scenarios cover

The benchmark builds a deliberately messy graph (orphans, duplicate observations, auto-merge and review-band entity pairs, protected Project roots, and control entities) and runs compaction through `CompactionRunner` → `DreamStateCompactionJob` until `completed`.

It asserts:

- safe orphan parenting and low-confidence review queueing;
- byte-identical observation deduplication;
- high-confidence auto-merge with provenance preserved;
- review-band pairs queued in `compaction_review`;
- cooperative pause/resume from `cursor_entity_id` without losing progress;
- structural usefulness deltas (fewer entities, observations, orphans, duplicate groups);
- deterministic text-search behavior before and after compaction;
- MCP readability via `dream_state_status` and `get_maintenance_reports`.

### Pending discovery scenarios

The benchmark also covers **relationship discovery** end to end: shared cross-project evidence, `solves` proposals for issue/solution pairs, duplicate-suppression for existing relations, and reachability improvements after manually accepting a proposal.

Run the benchmark:

```bash
bundle exec rspec spec/integration/dream_state_usefulness_spec.rb
```

## Typical agent workflow

1. At session start, call `dream_state_status` to see if compaction is `running` or `paused`.
2. During work, mutating tools automatically pause an active run if needed.
3. Periodically call `get_maintenance_reports(report_type: "compaction_review")`.
4. Apply clear merge suggestions with `merge_entities`; parent orphans manually when scores are ambiguous.
5. Prefer `search_entities` before `create_entity` to avoid creating duplicates the compactor must later merge.

