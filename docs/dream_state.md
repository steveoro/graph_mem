# Dream-State Compaction

GraphMem's **dream-state** mode is a background compaction pipeline that periodically optimizes the knowledge graph while MCP clients are idle or between batches. It canonicalizes stored relation types, auto-parents orphan nodes, deduplicates identical observations, and auto-merges near-duplicate entities—queuing lower-confidence cases for operator or agent review.

The name evokes offline consolidation: work happens in the background on a predictable schedule, similar to how biological systems consolidate memory during sleep.

## Purpose

Agent sessions routinely produce graph clutter:

- **Relation type drift** — the same edge stored as `has_many`, `Has Many` and `has-many`, or under a synonym of a canonical type
- **Structural orphans** — entities with no `part_of` parent (`depends_on` doesn't count as a parent)
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
        ├── RelationTypeSweep       (relation_types phase: relation ids)
        ├── CompactionTraversal     (phase entity lists)
        ├── OrphanMatchingStrategy  (token match to Projects)
        └── NodeOperationsStrategy  (move_to_parent, merge_into)

CompactionRun (DB)  ←── cursor, phase, stats, pause state
CompactionValve     ←── cooperative pause from MCP tools
```


| Component                 | Location                                  | Role                                                                      |
| ------------------------- | ----------------------------------------- | ------------------------------------------------------------------------- |
| `DreamStateCompactionJob` | `app/jobs/dream_state_compaction_job.rb`  | Processes one batch per invocation; re-enqueues itself while work remains |
| `DreamStateCompactor`     | `app/strategies/dream_state_compactor.rb` | Core compaction logic for each phase (`DreamStateCompactor::RelationTypesPhase` for `relation_types`) |
| `RelationTypeSweep`       | `app/services/relation_type_sweep.rb`     | Canonicalizes the stored relation types; also run by a rake task and a job |
| `CompactionRunner`        | `app/services/compaction_runner.rb`       | Starts/resumes runs; exposes `status_snapshot` for MCP, Home and Background jobs      |
| `CompactionRun`           | `app/models/compaction_run.rb`            | Persists run state, cursor, and cumulative stats                          |
| `CompactionTraversal`     | `app/strategies/compaction_traversal.rb`  | Deterministic entity ordering per phase                                   |
| `CompactionValve`         | `app/services/compaction_valve.rb`        | Requests cooperative pause when MCP tools need the graph                  |




## Compaction phases

Each run progresses through four phases in order:

### Phase 1: `relation_types`

**Set:** every relation, by id, 200 at a time (`RelationTypeSweep::BATCH_SIZE`). This phase walks relations, not entities.

A relation's type is normalized when it is written (see [mcp_tools.md](mcp_tools.md#relation-type-canonicalization)), but relations stored earlier, or written by a path that restores a stored type, can still carry a variant. `RelationTypeSweep` computes each stored type's canonical type: the type folded to lower snake case, then an operator's row in `relation_type_mappings`, else `GraphVocabulary::RELATION_TYPE_MAPPINGS` in code. A type nothing maps keeps its folded spelling.

**Per relation**, one outcome:

| Outcome | When | What happens |
| --- | --- | --- |
| `unchanged` | The stored type already is the canonical type | Nothing |
| `case_only` | The two types differ only in case or trailing spaces (the column compares them as equal) | Plain update in place; the row is its own twin, so it can't collide |
| `retyped` | A different type, and no relation of the canonical type on the same two entities | The type is updated in place |
| `merged` | A different type, and a relation of the canonical type already joins the same two entities (the twin) | The variant is deleted into the twin: the twin keeps the higher `weight` and `confidence`; if the twin has no `properties` it takes the variant's, otherwise the variant's are kept on the twin under `merged_from` |
| `queued` | The canonical type is `part_of` and there is no `part_of` twin | Nothing is written. A `relation_retype` review row is queued instead (see the review table below) |

Three more counts keep the totals honest: `already_queued` (a row for it is pending, or you dismissed it), `skipped_part_of` (a stored `part_of` whose canonical type is another type; it can't happen today, and the sweep never retypes out of `part_of`) and `error` (a relation that changed during the sweep, or failed validation; the sweep goes on and the next run retries it). They and the five outcomes add up to `scanned`.

A `part_of` edge decides which project an entity belongs to, and an update skips the create-time checks (one parent, no cycle) and the membership sync. So the sweep never creates, deletes or retypes a `part_of` edge, and never takes the membership lock.

**Writes:** each batch that writes is one change set of kind `dream.relation_types`, actor `compaction:<run id>`. That kind is not undoable (see "Relation type change sets" below). The run keeps one report for all its batches: a `relation_type_sweep` maintenance report listing every change that wasn't `unchanged`, up to 2,000 (the counts always cover the whole run). That report type is internal: `get_maintenance_reports` doesn't return it. Read it on **System › Background jobs › Relation types › View the changes**.

### Phase 2: `orphans`

**Entity set:** All non-`Project` entities with no `part_of` parent: no outgoing `part_of` edge, since `child part_of parent` runs from the child (`OrphanMatchingStrategy#orphan_nodes`). `depends_on` is not a parent relation here.

**Per entity:**

1. Tokenize the orphan name and score matches against every `Project` name and aliases.
2. If the best match scores **≥ 10** (`AUTO_ORPHAN_SCORE`), call `NodeOperationsStrategy#move_to_parent` to create a `part_of` link.
3. Otherwise, queue the orphan for review in a `compaction_review` report, with up to three `suggested_parents` (best score first). Applying the row (Review & Fix or `apply_maintenance_review`, also `dry_run`) without a chosen `parent_id` uses the first suggested parent that still exists (1.86.2); the Dangling review policy dismisses the row once its chosen parent, or every suggestion, is gone.

**Scoring highlights** (from `OrphanMatchingStrategy`):


| Match type                   | Score |
| ---------------------------- | ----- |
| Exact token in project name  | +10   |
| Substring in project name    | +5    |
| Exact token in project alias | +8    |
| Substring in project aliases | +3    |




### Phase 3: `tree_walk`

**Entity set:** Breadth-first walk from the `Project` roots (ordered by ID) down their `part_of` children: the children of an entity are the entities whose `part_of` edge points at it. `depends_on` edges aren't followed. Every non-`Project` entity the walk didn't reach (no `part_of` chain to a Project) is then appended, ordered by ID.

**Per entity:**

1. **Observation deduplication** — for each duplicate `content` on the entity, keep the lowest `id` and delete the rest.
2. **Entity merge scan** — if the entity has an embedding (`embedded_at` set; an unembedded entity's zero-vector placeholder is never compared, 1.93.5) and is not a `Project`:
  - Find up to 3 candidates with cosine distance **< 0.30** (`REVIEW_MERGE_DISTANCE`), excluding Projects, **requiring the same `entity_type`**, and `id > entity.id` for deterministic ordering.
  - If distance **< 0.10** (`AUTO_MERGE_DISTANCE`), auto-merge via `NodeOperationsStrategy#merge_into`.
  - Otherwise, queue a merge review item, but only when the pair's evidence score reaches `EntityMergeEvidence::REVIEW_SCORE` (6). Distance in the review band scores 4 and each shared observation adds 2 (max 6), so a distance-only pair is not queued. A shared observation counts only when `ObservationEvidence` finds it distinctive: at least 40 characters and held by at most 3 entities.

`Project` entities are never auto-merged or queued for merge review.

**What a merge does with the hierarchy (1.93.1).** Every merge follows one rule, whether it is the auto-merge here, a queued `entity_merge` row, `graph_delete` `merge_entities`, REST `merge_into` or Explore's merge: the target keeps its own relationships and its own parent, and everything that hung on the source moves to the target.

- All of the source's `part_of` children move to the target (and into its project, with their subtrees).
- The source's own parent edge is dropped when the target already has a parent, or when re-pointing it would make a `part_of` cycle. The dropped edge is in the merge snapshot, so undo restores it.
- When the target has no parent, it takes the source's. The target and its subtree then move into that parent's project, before the source's children follow.
- Undo puts both edges back and syncs the target back to its own scope.
- A name that is already taken in the scope a child or the target moves to refuses the merge, with nothing merged: a `422` on REST `merge_into` and in Explore, a failure reason on a review row,, and in the auto-merge the failure is logged for that entity and the run goes on.

The row's preview (and Explore's merge dialog) says which of the two happens to the parent edge, and whether the target changes project.

### Phase 4: `relationship_discovery`

**Entity set:** All non-`Project` entities ordered by ID.

**Per entity:** `RelationshipDiscoveryStrategy` scans observation text and entity metadata for explainable link candidates. Proposals are **review-only** — dream-state never auto-creates inferred relations.

**Current rules:**

| Rule | Relation type | Evidence |
|------|---------------|----------|
| Issue/solution pairing | `solves` | `PossibleSolution` + `Issue` observations sharing at least 3 topic tokens, with fix/solve vs block/problem language |
| Named dependency | `depends_on` | Observation contains dependency language and references another entity by name or alias |

Each proposal is queued as `relationship_proposal` with `from_entity_id`, `to_entity_id`, `relation_type`, `confidence_band`, `score`, `supporting_observation_ids`, `explanation`, and optional `evidence_terms`.

There is no `relates_to` rule: identical observation content (even distinctive content) was dropped as evidence because none of its proposals were ever approved, and boilerplate lines ("Status: Completed") made cliques of them.

Safety filters: no self-links, no duplicate same-direction relations, no Project-root involvement, allowed relation types only, max 3 proposals per entity per run.

To accept a proposal: inspect `get_maintenance_reports(report_type: "compaction_review")`, then create the relation manually (web UI or `create_relation`).

## Batch processing and cursor

Compaction is **incremental**, not monolithic:

- `BATCH_SIZE` entities per job invocation (`DREAM_STATE_BATCH_SIZE`, default 1, at most 50); in `relation_types`, 200 relations
- `CompactionRun#cursor_entity_id` records the last processed entity; the next batch resumes after it. The `relation_types` phase keeps its cursor, a relation id, in `stats["relation_cursor_id"]`, so `cursor_entity_id` stays empty while it runs
- When a phase's list is exhausted, the run advances to the next phase (or marks `completed`)
- Progress totals count the entities once per entity phase (`orphans`, `tree_walk`, `relationship_discovery`) plus the relations the first phase walks (`total_relations`, read when the run starts)

`DreamStateCompactionJob` returns:


| Result       | Job behavior                                           |
| ------------ | ------------------------------------------------------ |
| `:continued` | Re-enqueue immediately with the same `run_id`          |
| `:paused`    | Stop; resume on next scheduled trigger or manual start |
| `:completed` | Stop; run marked finished                              |

## The membership lock

An orphan's auto-parent (`orphans`) and an auto-merge (`tree_walk`) change a `part_of` edge, so they take the membership lock (`ProjectMembership.with_membership_lock`, see [architecture](architecture.md#project-membership-1931-1932-1933)). The lock must come **before** any transaction, and a batch runs inside two: the compactor's per-entity transaction, and `run.with_lock` in `DreamStateCompactionJob`, which wraps the whole batch. Since 1.93.2 both are covered. `DreamStateCompactor.with_membership_lock(phase)` takes the lock for the phases in `MEMBERSHIP_PHASES` (`orphans` and `tree_walk`) around each entity's transaction, and the job takes it around `run.with_lock`, so the first `GET_LOCK` of a batch has no transaction open and the inner ones just re-enter it. The other phases (`relation_types`, `relationship_discovery`) don't take it: neither writes a `part_of` edge (the relation sweep queues a `part_of` variant as a review row, and discovery only proposes). Cursor and pause handling are unchanged.

- **Hold time.** A batch is one entity by default (`DREAM_STATE_BATCH_SIZE`), so the lock is held for one entity's work: 23 to 52 ms per batch on the test database. Neither phase makes an LLM call (the orphan and merge evidence come from the database), so no network call runs inside it. A larger batch size holds it longer, for the whole batch.
- **A busy lock retries.** When an import, the backfill or a merge holds the lock for the full wait (`ProjectMembership::LOCK_TIMEOUT_SECONDS`), the job logs a warning and enqueues itself again after `DreamStateCompactionJob::LOCK_RETRY_WAIT` (1 minute) with the same run. The run isn't failed and its cursor hasn't moved, so the batch is simply tried again.
- **The merge survivor is re-embedded later.** The lock is never held across an embedding call. An interactive merge (REST, MCP, Explore, a review row) defers the survivor's inline embedding to the exit of the outermost lock block (1.93.3, `EmbeddingService::InlineDeferral`), so it is embedded before the call returns. Dream state is unattended batch work, so it suppresses inline embeddings inside its lock instead of deferring them, and the embedding backfill embeds the survivor. A merge changes the survivor's aliases, which clears its embedding stamp. After each auto-merge the compactor enqueues the embedding backfill once the merge has committed (`EmbeddingsMaintenanceEnqueuer`; the queue can live in its own database, so an earlier enqueue could start a backfill that doesn't see the survivor yet; a failed enqueue is logged and never undoes the merge). If a backfill is already running and has passed the survivor, the nightly backfill picks it up. Until the backfill runs, the survivor has no embedding and drops out of vector search.


Failed runs store the error message in `stats["error"]` and set status to `failed`. `CompactionRunner#acquire_run!` can resume a failed run when no other active run exists.

## Cooperative pause (CompactionValve)

Live MCP traffic takes priority over background compaction.

Before executing, these MCP tools call `CompactionValve.request_pause_if_running!`:

Canonical mutation tools `graph_write`, `graph_edit`, and `graph_delete`, plus
maintenance/heavy-read tools `summarize`, `suggest_merges`,
`detect_contradictions`, `apply_maintenance_review`, and
`dismiss_maintenance_review`. Reads through `search`, `get_entities` and the
other context and read tools don't pause it. `ToolMutationPolicy::COMPACTION_VALVE_TOOLS`
is the source of truth.

When a compaction run is `running`:

1. The valve sets `pause_requested` on the active `CompactionRun`.
2. The compactor checks the flag after each entity in the current batch (after each batch of 200 relations in `relation_types`); if set, it flushes pending review items, pauses the run, and yields.
3. The valve polls up to **3 seconds** for the run to reach `paused` status.

Operators can also pause manually from **System › Background jobs** (`/system/jobs`, which posts to `POST /system/jobs/compaction/pause`).

Paused runs resume from `cursor_entity_id` (`relation_cursor_id` in the first phase) on the next scheduled job or when an operator clicks **Start / Resume**.

## Review queue (`compaction_review`)

Items that are not safe to apply automatically are batched into `MaintenanceReport` rows with `report_type: "compaction_review"`.


| `kind`          | Contents                                                                     |
| --------------- | ---------------------------------------------------------------------------- |
| `relation_retype` | A stored variant whose canonical type is `part_of`: `operation` (`"retype"`), `relation_id`, `from_entity_id`, `from_name`, `to_entity_id`, `to_name`, `old_type`, `new_type`, `reason` |
| `orphan_parent` | Orphan entity, top 3 suggested `Project` parents with scores, optional error |
| `entity_merge`  | Two entities, cosine distance, `recommendation: "review_manually"`           |
| `relationship_proposal` | Suggested link with relation type, confidence band, supporting observation IDs, explanation |


`relation_retype` rows come from the `relation_types` phase, the rake task and the UI sweep alike. A `part_of` edge moves membership, so the row is applied by hand and one at a time: bulk apply, group apply and the auto-apply policies never touch it. **Apply** runs under the membership lock: it deletes the variant, creates the `part_of` edge through the normal path (one parent, no cycle) with the variant's `weight`, `confidence` and `properties`, and syncs the child's project. A refusal (a cycle, a name taken in the new project) is returned as an error and nothing is written. When the child already has another `part_of` parent (typically the Project itself, while the variant points at a more specific entity in it), the plain Apply would give it a second parent, so the row asks for a choice instead (its `reason` says so when it is queued): **Move under** the row's target (the variant and the old parent edge are deleted and the child moves under the target, with its subtree, through the same move as `reparent_entity`; the preview says from which parent to which and whether the project changes) or **Keep** the current parent (the variant becomes `relates_to`, merged into a `relates_to` twin with the sweep's rule if one exists; no membership change). Over MCP the choice is `action_params.parent_choice`, `"move"` or `"keep"`; without it the apply answers a validation error naming both. A row that is already done succeeds with nothing written; the Dangling policy dismisses a row whose relation is gone, already has the new type, has a twin of it (the next sweep merges into the twin), or whose type no longer maps to it. The row can't be edited, only applied or dismissed, and its undo is the ordinary audit undo (the `part_of` edge is removed and the variant comes back with its stored type; after Move the old parent comes back too, after Keep the variant gets its stored type back).

Reports are flushed at the end of each batch and when advancing phases. Read them via:

- **MCP:** `get_maintenance_reports(report_type: "compaction_review")`
- **Projects & Data › Background jobs:** Dream State card → "Compaction review queue" details

To action a queued merge: inspect the report, then call `graph_delete` with a
`merge_entities` operation.

To action a queued relationship proposal: inspect the evidence, then call
`graph_write` with a `create_relation` operation.

## Run stats

`CompactionRun#stats` accumulates counters during a run:


| Key                    | Meaning                            |
| ---------------------- | ---------------------------------- |
| `relations_processed`  | Relations the `relation_types` phase has scanned |
| `relation_cursor_id`   | The relation id that phase resumes after |
| `relation_types_fixed` | Relations retyped in place or fixed for case (`retyped` + `case_only`) |
| `relation_types_merged` | Variant relations merged into their canonical twin |
| `relation_retypes_queued` | `relation_retype` review rows queued |
| `relation_types_report_id` | The run's `relation_type_sweep` report |
| `total_relations`      | Relations counted when the run started (for the progress bar) |
| `entities_processed`   | Entities visited across the entity phases |
| `integrity_sweep_done` | The pre-flight integrity sweep ran for this run |
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


Times are GMT as noted in `config/recurring.yml`. On a machine that is off at 3:00, **Run all
scheduled jobs now** on System › Background jobs (1.81.0) runs compaction with the other scheduled
jobs and waits for it to finish; its **Stop** pauses the compaction run, and **Resume** continues
from its cursor. Since 1.86.0 the machine does that by itself: `ScheduledRunCatchUpJob` starts the
run about 20 minutes after Solid Queue boots when no scheduled run and no compaction run started
since the last 3:00 slot, and resumes a run a power cut interrupted (setting
`scheduled_run_catch_up_enabled`, on by default). A host that stayed up overnight ran the 3:00
compaction itself, so nothing is started.

Resolved review rows are pruned by a separate daily job, `MaintenanceReportRowCleanupJob`
(5:15 AM GMT in production, after compaction): approved, dismissed and ignored rows older than
`compaction_review_row_retention_days` (default 30) are deleted; active rows are kept. Set the
retention in Settings › Telemetry. Suggestions you dismissed stay suppressed after their row is
gone (both the original and, if you edited it, the edited proposal); ignored ones can be proposed
again. Rows a project rescan dismisses on its own record no suppression.

The cleanup job also prunes `expired` rows, keeps a snoozed row until its snooze ends, and deletes
suppressions that expired more than the retention ago. The review policies run nightly at 5:00 AM GMT
(`ReviewPolicyJob`, before the cleanup) and after a compaction run that seeded rows; see
[architecture](architecture.md#review-queue-classification-limits-and-policies-ui-5a).

Change sets (UI-4a) are pruned by `ChangeSetPruneJob` (5:30 AM GMT): snapshots older than 30
days are cleared (every undo window has passed), and sets older than 90 days that no audit row
references are deleted. Compaction auto-merges are change sets too (actor `compaction:<run_id>`),
so the operator can undo one for 7 days (see [architecture](architecture.md#change-sets-and-undo-ui-4a-1570)).

### Feature flag


| Setting                        | Default | Effect                                                           |
| ------------------------------ | ------- | ---------------------------------------------------------------- |
| `enable_dream_state_compactor` | `true`  | When `false`, scheduled and manual compaction starts are skipped |


Configure under **System › Settings › Feature Flags**.

## Operator controls

The **Dream State / Compactor Run** card on **System › Background jobs** (`/system/jobs`; the Maintenance hub that held it until 1.62.0 is gone) shows:

- Run status badge (`idle`, `running`, `paused`, `completed`, `failed`)
- Phase stepper (`relation_types` → `orphans` → `tree_walk` → `relationship_discovery`)
- Cursor entity, pause flag, timestamps, duration
- Live stat chips (**Relation types fixed** counts the retyped, case-fixed and merged relations)
- **Pause** / **Start / Resume** buttons
- **Repair relation duplicates** when a failed run may be caused by relation integrity issues

Manual start enqueues `DreamStateCompactionJob` via `CompactionRunner.start_or_resume!`.

The **Relation types** card below it runs the same sweep on demand and lists the types that nothing maps. A run that was created before the `relation_types` phase existed keeps its phase and never visits it.

### Relation types card

**Canonicalize relation types** opens a dry run: the sweep's counts, with nothing written (the page lists counts only; the report of the real run lists each change). **Run the sweep now** then queues `RelationTypeSweepJob`, which shows its progress on the card. The button is refused while another sweep is queued or running, and while a dream-state run is in progress (its first phase is the same sweep): pause that run or wait for it. A sweep from the card asks a running dream-state run to pause first, like a graph write does.

The card also shows the last sweep of any source (the card, the rake task or a dream-state run: when, by whom, the counts), **View the changes** (the report, 100 changes a page) and **Unmapped relation types (N)**. That page lists each stored type that is neither canonical nor mapped, with its use count, the spellings it is stored under and two example edges. Per type, **Map** to a canonical type adds a row to `relation_type_mappings`, and **Accept** keeps it as a known type of its own (a row mapping it to itself). The **Mappings** table lists every row with **Remove**. None of these retypes anything: the next sweep applies a mapping, and removing a row changes no relation. A type mapped to `part_of` is queued for review by the sweep, like any variant of it.

The same sweep runs from the command line:

```bash
bin/rails graph_mem:canonicalize_relations                 # runs the sweep
DRY_RUN=1 bin/rails graph_mem:canonicalize_relations      # counts only, nothing written
VERBOSE=1 bin/rails graph_mem:canonicalize_relations      # also lists the changes
```

### Relation type change sets

The sweep's change sets (`dream.relation_types`, one per batch that writes) can't be undone from System › Activity or `POST /changes/:uuid/undo`: a restored variant would be canonicalized again on save, and a merged row would collide with its twin. Activity shows why in the set's Undo column. To reverse a change by hand, use the sweep's report, which lists each relation's id, old and new type and the id of the twin it was merged into; past the 2,000 changes a report lists, the set's audit rows (Audit log) have the rest.

Two other undos restore a deleted relation with the type it had stored, without canonicalizing it again: the audit undo (for instance of a `relation_retype` apply) and the undo of an entity merge. The next sweep canonicalizes such a relation.

## MCP tools


| Tool                      | Purpose                                                                                              |
| ------------------------- | ---------------------------------------------------------------------------------------------------- |
| `dream_state_status`      | Returns `dream_state`, `run_id`, `phase`, `cursor_entity_id`, `pause_requested`, `stats`, timestamps |
| `get_maintenance_reports` | Read `compaction_review` queue and other maintenance reports                                         |
| `graph_delete`            | Apply a known merge as a `merge_entities` operation (also triggers cooperative pause)                 |
| `suggest_merges`          | On-demand duplicate search (separate from dream-state auto-merge thresholds)                         |


On the maintenance profile, agents should call `dream_state_status` for a cheap health check and `get_maintenance_reports(report_type: "compaction_review")` to drain the review queue.

## Relation integrity recovery

Compaction merges and moves assume relations are well-formed. Duplicate or conflicting relation rows can cause `merge_into` to fail with uniqueness errors.

`RelationIntegrityRepairer` (`app/services/relation_integrity_repairer.rb`) scans for:

- Same-direction duplicates — multiple rows for the same `(from, to, type)` (auto-deleted)
- Reverse pairs — `A→B` and `B→A` with the same type
- Merge collisions — one child linked to multiple parents with a single-parent type such as `part_of`

Default integrity sweeps (`GraphIntegrityService`) auto-repair same-direction duplicates and queue ambiguous reverse pairs / merge collisions into `compaction_review` as `relation_integrity` rows. Each row preserves a reviewed `keep_id` and the selected `delete_id` / `delete_ids`.

Operators and agents can apply those rows from the compaction-review UI or via `apply_maintenance_review` (deletes the reviewed duplicates with `Current.deletion_reason = "duplicate"`; already-absent relations are a safe stale outcome). The dashboard **Repair relation duplicates** button still runs an explicit destructive repair (`review_ambiguous: false`), then operators can **Start / Resume** compaction.

Since 1.93.1 that button is safe for membership. A `part_of` edge decides which project an entity belongs to, so the repair takes the membership lock before one transaction, finds the issues under it, deletes the extra parents and the newer edge of each reverse pair, and syncs each child of a deleted `part_of` edge to the parent it keeps (or to no project). If a child's name is already taken in that parent's project, the whole repair rolls back and the notice says "Relation repair refused, nothing was deleted: …"; rename or re-parent one of the two, then repair again. The unattended callers (the pre-flight and the nightly garbage collection run with `review_ambiguous: true`) delete only same-direction duplicates, which the unique key makes impossible, so they never delete a `part_of` edge: they queue `relation_integrity` rows.

## Safety guarantees

- `Project` **roots are protected** — never auto-merged, never deleted by compaction logic (`NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR`).
- **Deterministic traversal** — sorted IDs and `id > entity.id` merge ordering make runs reproducible.
- **Review band** — cosine distance between **0.10** and **0.30** requires human or agent confirmation.
- **Type-safe merges** — only entities of the same `entity_type` are considered for auto-merge or merge review. `NodeOperationsStrategy#merge_into` refuses cross-type merges.
- **Low-confidence orphans** — token scores below **10** are never auto-parented.
- **Pre-flight integrity sweep** — before each run, `GraphIntegrityService` auto-repairs counter cache drift and dangling relations (a dangling `part_of` whose child survives is deleted with a membership sync, and kept with a logged warning on a name collision), backfills missing embeddings (queuing failures for review), and detects observation lifecycle corruption (active with `obsoleted_at`, superseded without `superseded_by`, cross-entity `superseded_by` references). Lifecycle issues and embedding failures are queued into `compaction_review`. A lifecycle row's **Repair** (1.86.0) re-reads the observation: superseded without `superseded_by` points at its active same-entity `outdated_by`, else becomes obsolete; active with `obsoleted_at` has it cleared; a cross-entity `superseded_by` is Dismiss only. Undoable; a row already consistent is resolved, and the Dangling policy dismisses it.



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

The benchmark also covers **relationship discovery** end to end: issue/solution and dependency proposals are limited to the source entity's resolved `part_of` project subtree. Disconnected entities are self-scoped. The sole cross-project exception is an active observation whose content is byte-identical on both entities; that evidence may propose `relates_to`. It also covers duplicate-suppression for existing relations and reachability improvements after manually accepting a proposal.

Run the benchmark:

```bash
bundle exec rspec spec/integration/dream_state_usefulness_spec.rb
```

## Typical agent workflow

1. On the maintenance profile (`/mcp/maintenance`), call `dream_state_status` to see whether compaction is `running` or `paused`. Default-profile agents don't need to: mutating tools pause compaction automatically.
2. During work, mutating tools automatically pause an active run if needed.
3. Periodically call `get_maintenance_reports(report_type: "compaction_review")`.
4. Apply clear merge suggestions with a `graph_delete` `merge_entities` operation; parent orphans manually when scores are ambiguous.
5. Prefer `search` before `graph_write` to avoid creating duplicates the compactor must later merge.

