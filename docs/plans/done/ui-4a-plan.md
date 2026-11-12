# UI-4a → graph_mem 1.57.0: change sets, merge snapshots and undo (backend only, one PR)

**Written 2026-10-26 (Europe/Rome)** for Claude, from the 1.56.0 code (`a33e7c1`, UI-1a + UI-1b merged).
Every file:line below was checked against that commit. If a line has moved, find the code by the quoted
text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.

Context: `ui-dashboard-plan.md` §2.4 (what Explore needs from this PR), §2.5 (what Review & Fix, UI-5, needs),
§5.1-§5.4 (guardrails, confirm levels, change sets, role matrix) and §6 UI-4a. This file **replaces** §5.3 and
§6 UI-4a as the step list: where they differ, this file wins (the differences are listed under "Decisions
(changeable)"). It is self-contained; read the other plan only for background.

## Brief

| | |
|---|---|
| **Branch** | `claude/ui-4a-1.57.0`, off current `main` (supersedes `claude/ui-4a-change-sets-undo` in §6). |
| **PR** | Open **one PR against `main`**. Title: `UI-4a: change sets, merge snapshots and undo (1.57.0)`. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | In this order, so the PR can be split cleanly if Steve asks (see "Size and split"): **A1** schema + `ChangeSet` model, **A2** recording (Auditable stamp + every entry point), **B1** audit-inverse undo + review-row undo + `ChangesController`, **B2** prune job, **C1** merge snapshot, **C2** merge undo + redo + concurrency spec, **D** docs, **R** release (version, SKILL.md, CHANGELOG). Review fixes go in new commits; no force-push after review starts. |
| **Scope** | Backend only. **No new pages, no Explore UI, no Activity feed, no MCP tool, no `/api/v1` endpoint.** The only new route is `POST /changes/:uuid/undo` (operator only). |
| **Data** | Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Beta Service`). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (implementer brief: spec hygiene, test-DB truncate, done criteria). |

## What the code looks like today (verified at `a33e7c1`)

- **Stack.** Rails 8.1.4, Ruby 3.4.1, MariaDB 11.8 with `vector(768)` columns. `config/application.rb:38`
  `schema_format = :sql`: **`db/structure.sql` is the schema**; `db/schema.rb` is stale (`version: 2026_02_27_122156`)
  and must not be edited or regenerated. Latest migration: `20261019120000`.
- **Audit.** `app/models/concerns/auditable.rb` (47 lines) is included by `MemoryEntity`, `MemoryObservation` and
  `MemoryRelation` only. `after_create`/`after_update`/`after_destroy` (7-9) call `write_audit` (31-42), which does
  `AuditLog.create!(…, actor: Current.actor, …, reason: … Current.deletion_reason …)` and **rescues every error with a
  warning** (40-41). Snapshots are `attributes.except("embedding")` (44-46); updates store
  `{ field => { from:, to: } }` without `updated_at` (18-25). `app/models/audit_log.rb`: `changed_fields` is a JSON
  `longtext`, `MAX_AGE_DAYS = 90`, `prune!` deletes expired rows (called by `GarbageCollectionRunner:118` and
  `Operator::AuditLogsController:19`). `audit_logs` (structure.sql:45-57) has no `change_set_id`.
  `maintenance_report_rows`, suppressions and `project_id` stamping are **not audited**.
- **Current.** `app/models/current.rb` has `actor` and `deletion_reason` only. Actors:
  `ApplicationController#set_current_actor` (`app/controllers/application_controller.rb:35-44`:
  `api:<X-MCP-Client>`, `operator:<user>@<ip>`, `guest:…`, `<ip>:<controller>`), `ApplicationTool#call`
  (`app/tools/application_tool.rb:101-104`: `mcp:<tool_name>`, reset to nil in `ensure`, 98). Jobs set no actor (nil).
- **Merge.** `app/strategies/node_operations_strategy.rb` (410 lines). `merge_into` (93-111) retries
  `merge_into_once` up to `MAX_MERGE_RETRIES = 3` on deadlock / lock-wait / "record has changed" (18-22).
  `merge_into_once` (113-194): `Current.deletion_reason = "duplicate"`; `ProjectMembership.with_membership_lock`
  **then** `ActiveRecord::Base.transaction`; locks both rows `ORDER BY id FOR UPDATE` (126-131); refuses missing rows,
  Project roots and different types (135-154); `merge_aliases` (`target.update!(aliases: …)`, 276-287);
  `transfer_observations!` (289-298: `memory_entity_id` → target, `trust_score` re-ranked, `save!`, **no re-embedding**:
  the D-3 change from #122); `reassign_outgoing_relations!`/`reassign_incoming_relations!` (307-345: re-point, or
  destroy when the triple already exists on the target; incoming `part_of` children are `ProjectMembership.sync!`ed);
  deletes source↔target edges (170-171); `cleanup_duplicate_relations` (349-385; a no-op in practice because
  `index_memory_relations_uniqueness` forbids duplicates); `target.update_column(:memory_observations_count, …)` (177);
  `source.destroy!` (182). **Embedding side effect:** `target.update!(aliases:)` clears `embedded_at`
  (`MemoryEntity#invalidate_stale_embedding`, `memory_entity.rb:34-35, 85-88`) and `after_commit :refresh_embedding`
  (33, 90-98) calls Ollama **after commit but still inside the membership lock**, because the lock block wraps the
  transaction (when nested in an outer transaction, it fires when that one commits).
- **Merge callers** (all go through `merge_into`): `GraphDeleteService#merge_entities`
  (`app/services/graph_delete_service.rb:268-280`, inside its own lock + transaction, 83-84, up to 50 ops per batch),
  `CompactionReviewApplier#merge_entities` (`app/services/compaction_review_applier.rb:75-83`, inside
  `CompactionReviewService.apply`'s lock + `row.with_lock`), `Api::V1::MemoryEntitiesController#merge`
  (`app/controllers/api/v1/memory_entities_controller.rb:167-179`), `DataExchangeController#merge_node`
  (`app/controllers/data_exchange_controller.rb:533-…`), `DreamStateCompactor#process_entity_merges`
  (`app/strategies/dream_state_compactor.rb:239-264`, `EntityMergeEvidence.pick_survivor` then `merge_into`, no outer
  transaction; the run is `@run`, a `CompactionRun`).
- **Other writers.** `GraphWriteService` (`create_entity/observation/relation`, lock then transaction, 88-95),
  `GraphEditService` (`update_entity/observation`, transaction only, 45), `GraphDeleteService`
  (`delete_entity` hard delete with `dependent: :destroy`, `delete_observation` = mark obsolete, `delete_relation`,
  `merge_entities`). MCP tools: `graph_write`/`graph_edit`/`graph_delete` (profiles `default maintenance`),
  `apply_maintenance_review`/`dismiss_maintenance_review` (`maintenance` only, call `CompactionReviewService`).
  `DreamStateCompactor#dedupe_observations_for_entity` (198-224) hard-deletes duplicate observations.
- **Review actions.** `app/services/compaction_review_service.rb` (608 lines): `apply` (90-122: lock, `row.with_lock`,
  `CompactionReviewApplier.apply`, row → `approved`/`applied_at`), `dismiss` (124-131: `suppress(row)` creates
  `MaintenanceReportSuppression` rows (588-599), row → `dismissed`; no transaction), `bulk_dismiss`, `bulk_apply`
  (per-row `apply`), `restore` (172-183: deletes the row's suppressions and resets the row to `active`; **it does not
  revert the graph change of an applied row**), `ignore`. Callers: `DataExchangeController:280-292`, the two MCP review
  tools, `ProjectScanner:787`, `CompactionReviewApplier:212`. No code closes review rows when a merge happens
  (§5.3 step 8 of the dashboard plan has nothing to undo; see Decision 9).
- **Locking.** `app/services/project_membership.rb:51-75` `with_membership_lock` = `GET_LOCK('graph_mem.project_membership:<db>', 60)`,
  re-entrant, taken **before** any transaction (the advisory-first rule, 31-42). `reassign_locked!` (110-…) stamps
  `project_id` with `update_all` (not audited) and raises `ProjectMembership::Collision` on a same-name clash.
- **Embeddings.** `memory_entities.embedding` and `memory_observations.embedding` are `vector(768) NOT NULL` with a zero
  default, a `BEFORE INSERT` trigger (`trg_memory_*_embedding_bi`, structure.sql:191, 245) and a `VECTOR KEY`.
  `embedded_at` is the real-vector flag; only `EmbeddingService#store_vector` sets it, as a compare-and-set on
  `updated_at` (`app/services/embedding_service.rb:339-351`). `EmbeddingService.suppress_inline_embeddings` (52-58)
  skips the inline `after_create`/`after_commit` embeds; rows left with `embedded_at` NULL are picked up by the daily
  backfill (`config/recurring.yml`, `embedding_backfill`, 4 am). Entity text = name, type, aliases, description;
  observation text = content, source, tags (`EMBEDDING_FIELDS`): moving an observation never changes its vector.
- **Trust.** `MemoryObservation#assign_trust_score` (`before_save`, 52, 62-64) re-ranks on every save and the rank is
  time-dependent (`ObservationTrustRanker#validity_factor`). A stored "before" score must not be written back.
- **Schema facts that bound undo.** `memory_relations` FKs to both endpoints without `ON DELETE`, unique
  `(from_entity_id, to_entity_id, relation_type)`; `memory_observations.memory_entity_id` FK; `memory_entities`
  unique `(project_scope, name)` with `project_scope = COALESCE(project_id, 0)` (generated), self-FK `project_id`.
  InnoDB auto-increment is persistent, so ids aren't reused by normal inserts; an explicit-id insert can only collide
  with a row that already has that id.
- **Roles.** `ApplicationController` is operator-only unless a controller calls `allow_guest`
  (`app/controllers/concerns/role_authorization.rb`). `spec/requests/role_matrix_spec.rb` walks every route
  (dummy segments become `1`) and asserts guest 403 / no mutation via `record_counts`
  (`[MemoryEntity, MemoryObservation, MemoryRelation, AuditLog, MaintenanceReportRow].count`, 68-70).
- **UI plumbing from UI-1.** Toasts render in `#toasts` (`app/views/ui/_toasts.html.haml`, `layouts/_flash_messages`);
  `DataExchangeController:336` shows the Turbo Stream pattern.
- **Versions.** `lib/graph_mem/version.rb:4` `"1.56.0"`; `skills/graph-mem-mcp-toolset/SKILL.md:18`
  `graph-mem-version: "1.56.0"`; `CHANGELOG.md` has an empty `## [Unreleased]` (line 8).

## Scope

In: the `change_sets` table and `audit_logs.change_set_id`; `ChangeSet` + `Current.change_set`; recording at every
entry point listed under A2; merge snapshots on **every** merge path; `ChangeSetUndo` (audit inverse, merge undo,
review-row undo, redo); `POST /changes/:uuid/undo`; `ChangeSetPruneJob`; specs; docs; release 1.57.0.

Out (later PRs): the merge preview/dialog, `EntityMergePreview`, `EntityMergeService` and the preview digest (UI-4b,
see Decision 2); the Activity feed and undo toasts on pages (UI-2/UI-4b/UI-7); `maintenance_report_rows.change_set_id`
/ `resolved_by` and policy runs (UI-5 adds them on top of this API); undo of hard deletes of entities/observations;
imports and scans (Decision 6); any MCP or `/api/v1` surface (Decision 7).

## A1. Schema and the `ChangeSet` model

**Migration 1** `db/migrate/<timestamp>_create_change_sets.rb` (a real timestamp after `20261019120000`):
```
change_sets
  id                  bigint PK
  uuid                varchar(36)  NOT NULL, UNIQUE
  kind                varchar(64)  NOT NULL            -- ChangeSet::KINDS / KIND_PATTERNS
  actor               varchar(255) NULL                -- Current.actor at open time (or an explicit actor)
  summary             varchar(255) NULL                -- "merged 'SynthWidget' into 'Synth Widget'"
  subject_type        varchar(32)  NULL                -- "MemoryEntity" (anchor for the entity panel)
  subject_id          bigint       NULL
  undo_strategy       varchar(16)  NOT NULL DEFAULT 'audit'   -- audit | merge | none
  not_undoable_reason varchar(64)  NULL                -- hard_delete | mixed_merge | audit_incomplete | snapshot_too_large
  snapshot            json NULL (MariaDB: longtext + CHECK json_valid, like other JSON columns)
  snapshot_bytes      int          NULL
  undoable_until      datetime(6)  NULL                -- NULL = never undoable
  undone_at           datetime(6)  NULL
  undone_by           varchar(255) NULL
  undo_of_id          bigint       NULL  FK → change_sets.id ON DELETE SET NULL
  created_at, updated_at datetime(6) NOT NULL
  KEY (created_at), KEY (subject_type, subject_id), KEY (actor, created_at), KEY (kind, created_at), KEY (undo_of_id)
```
**Migration 2** `add_change_set_id_to_audit_logs`: `add_column :audit_logs, :change_set_id, :bigint, null: true` and
`add_index :audit_logs, :change_set_id`. **No DB foreign key** on `audit_logs` (Decision 4). Use plain `add_column` +
`add_index` (MariaDB adds a trailing nullable column instantly and builds the index online); no `change_table bulk:`.

Both migrations are reversible (`change`). Run them, then `git diff db/structure.sql`: only the new table, column,
index and FK may appear; **no `vector(768)`, `VECTOR KEY` or `trg_memory_*_embedding_bi` line may disappear**
(StructureDumpGuard). Don't touch `db/schema.rb`.

**`app/models/change_set.rb`** (≤ ~250 lines; move the in-memory context to `app/models/change_set/context.rb` if it
grows):
- `KINDS = %w[merge compaction.auto_merge graph.write graph.edit graph.delete review.apply review.bulk_apply
  review.dismiss review.bulk_dismiss review.restore review.ignore api.write maintenance.merge_node undo redo]`,
  `KIND_PATTERNS = [/\Apolicy\.[a-z_]+\z/, /\Aexplore\.[a-z_]+\z/]` (for UI-5 / UI-4b). Validate inclusion.
- `WINDOWS = { "merge" => 7.days, "audit" => 30.days }`; `MAX_SNAPSHOT_BYTES = 4.megabytes`; `SNAPSHOT_VERSION = 1`.
- `serialize`/JSON `snapshot` shape (versioned, every section optional):
  ```json
  { "v": 1,
    "merges": [ <merge step, see C1> ],
    "review_rows": [ { "id": 7, "row_uuid": "…", "before": { "status": "active", "applied_at": null,
                       "dismissed_at": null, "resolution_reason": null }, "after": { "status": "approved", … } } ],
    "suppressions_created": [ { "id": 3, "report_type": "compaction_review", "signature": "…" } ],
    "suppressions_deleted": [ { full maintenance_report_suppressions row } ],
    "audit_failures": 0 }
  ```
- `ChangeSet.record(kind:, summary: nil, subject: nil, actor: Current.actor) { |context| … }`:
  - if `Current.change_set` is already set, **join it** (yield the existing context, ignore the arguments): a merge
    inside a `graph_delete` batch or a review apply belongs to the outer set;
  - otherwise build a `ChangeSet::Context` (uuid, kind, actor, summary, subject, in-memory flags and sections),
    `Current.set(change_set: context) { yield context }`, and return the block's value.
  - **It opens no transaction and takes no lock** (Decision 1). The row is written **lazily** by the first write that
    needs it (`context.persist!`), inside whatever transaction that write runs in, so it commits or rolls back with
    the first real change, and a change set with no changes never exists.
- `Context#persist!`: inserts the row once (`uuid`, `kind`, `actor`, `summary`, `subject_*`, `undo_strategy`,
  `undoable_until = now + WINDOWS[strategy]`) and caches its id; registers
  `ActiveRecord::Base.current_transaction.after_rollback { forget the id and any section entries added in it }`
  (Rails 7.2+ API; a no-op outside a transaction), so a rolled-back first attempt (e.g. a merge retry) re-inserts.
- `Context#note_audit!(record, action)`: called by Auditable; flips the strategy (see below) and persists.
- `Context#add_merge_step!(hash)`, `#note_review_row!(row, before:, after:)`, `#note_suppressions!(created:/deleted:)`,
  `#note_audit_failure!`: append to the in-memory section, then write the whole snapshot with one
  `UPDATE change_sets SET snapshot = ?, snapshot_bytes = ?, undo_strategy = ?, not_undoable_reason = ?, undoable_until = ?`
  in the current transaction. **These raise on failure** (a merge must roll back if its snapshot can't be written).
- Strategy transitions (one-way, persisted only when they change):
  - start `audit`;
  - first merge step: `merge` if no non-merge audit row was noted yet, else `none/mixed_merge`;
  - a non-merge audit row after a merge step: `none/mixed_merge`;
  - `delete` audit of a `MemoryEntity` or `MemoryObservation` **outside** a merge step: `none/hard_delete`
    (relation deletes stay undoable);
  - an audit write failure: `none/audit_incomplete`;
  - snapshot over `MAX_SNAPSHOT_BYTES`: drop the large sections, keep counts, `none/snapshot_too_large`.
  - `none` sets `undoable_until = NULL`.
- Instance helpers: `undoable?(now = Time.current)` = strategy ≠ `none` && `undone_at.nil?` && `undoable_until&.future?`;
  `audit_logs` association (`has_many :audit_logs`, `dependent: nil`); `undo_of` / `undos`.

## A2. Recording at every entry point

- `app/models/current.rb`: `attribute :change_set` (the Context, not the AR row).
- `app/models/concerns/auditable.rb#write_audit`: add `change_set_id: Current.change_set&.persist!` and call
  `Current.change_set&.note_audit!(self, action)` before the `create!`; in the existing `rescue`, call
  `Current.change_set&.note_audit_failure!` (itself rescued: the audit-never-blocks-a-write rule stays). Keep the file
  short; don't change the snapshot format.
- Wrap these entry points in `ChangeSet.record` (inside the method, so retries and nested calls behave):

| Entry point | kind | subject | actor |
|---|---|---|---|
| `GraphWriteService#call` / `.execute_one` | `graph.write` | first entity touched | `Current.actor` (`mcp:graph_write`, `api:…`) |
| `GraphEditService#call` | `graph.edit` | first entity | idem |
| `GraphDeleteService#call` / `.execute_one` | `graph.delete` | first entity | idem |
| `CompactionReviewService.apply` / `bulk_apply` / `dismiss` / `bulk_dismiss` / `restore` / `ignore` | `review.*` | the row's anchor entity if known | idem (operator, `mcp:apply_maintenance_review`, scanner) |
| `NodeOperationsStrategy#merge_into_once` (inside the transaction, after the row locks) | `merge` (joins an outer set if present) | target | idem |
| `DataExchangeController#merge_node` | `maintenance.merge_node` | target | operator |
| `DreamStateCompactor#process_entity_merges` around `merge_into` | `compaction.auto_merge` | survivor | **`compaction:<run_id>`** (explicit actor; one set per merge) |
| `Api::V1::BaseController` `around_action` for non-GET actions | `api.write` | — | `Current.actor` |

  `CompactionReviewService` also notes review-row before/after (`note_review_row!`) in `apply`, `dismiss`, `restore`,
  `ignore` and the bulk variants, and the suppressions it creates (`suppress`) or deletes (`restore`).
- `merge_into(source_id, target_id, change_set_kind: "merge")` gains the keyword only; the result hash gains
  `change_set_uuid:` on success (callers may ignore it). MCP tool output schemas don't change.
- Not recorded (attribution only via `actor` on audit rows, as today): `ImportExecutionStrategy`, `ProjectScanner`,
  `DreamStateCompactor#dedupe_observations_for_entity`, garbage collection, the embeddings jobs.

## B1. Undo (audit inverse, review rows, redo) and the endpoint

**`app/services/change_set_undo.rb`** `ChangeSetUndo.call(uuid, actor: Current.actor)` → `Result` (`ok?`, `message`,
`conflicts` (array of strings), `change_set` (the new `undo` set)). Steps:
1. `CompactionValve.request_pause_if_running!` (like the MCP mutation tools).
2. `ProjectMembership.with_membership_lock` → `EmbeddingService.suppress_inline_embeddings` → `ActiveRecord::Base.transaction`.
3. `ChangeSet.lock.find_by!(uuid:)`; refuse unless `undoable?` ("already undone", "window passed on <date>",
   "not undoable: <reason>").
4. `ChangeSet.record(kind: original.kind == "undo" ? "redo" : "undo", actor:, subject: original.subject)`; set
   `undo_of_id` on persist.
5. Dispatch on `undo_strategy`: `ChangeSetUndo::AuditInverse` or `ChangeSetUndo::Merge`; then
   `ChangeSetUndo::ReviewRows` for the `review_rows` / suppression sections.
6. Any conflict raises `ChangeSetUndo::Conflict` → transaction rolls back → `Result` with `ok? false` and the
   conflict list. On success: `original.update!(undone_at: now, undone_by: actor)`.
7. **After** the lock is released: re-embed entities/observations whose text fields the undo changed and whose
   `embedded_at` is NULL (`EmbeddingService.embed_entity` / `embed_observation`, at most 50 inline, best effort,
   failures logged); the rest wait for the backfill.

**`ChangeSetUndo::AuditInverse`** (`app/services/change_set_undo/audit_inverse.rb`): the set's audit rows ordered by
`id DESC`.
- **Later-change check first (all-or-nothing):** for every `(auditable_type, auditable_id)` touched, refuse if an
  audit row with a **higher id** and a different (or NULL) `change_set_id` exists, except rows of an earlier undo of
  this set. The message names it: "Can't undo: MemoryEntity 'SynthWidget' changed since (by `<actor>` at
  `<created_at in Europe/Rome>`)".
- `create` → destroy (observations: if any observation has `superseded_by_id` = it, mark obsolete instead; entities:
  refuse if they now have observations or relations not created by this set).
- `update` → restore `from` for every field except derived ones (`IGNORED = %w[updated_at embedded_at trust_score
  memory_observations_count project_id project_scope]`); first check the row still holds every `to` value, else
  conflict. Restoring `status/obsoleted_at/obsolescence_reason` is what UI-5 needs for "undo obsolete marks".
- `delete` → only `MemoryRelation` (the strategy rules exclude the rest): re-insert with the **original id** from the
  snapshot (`MemoryRelation.create!(id:, …, created_at:)`) after checking the id is free, both endpoints exist and the
  triple doesn't; `part_of` re-inserts also check `RelationSemantics.would_create_cycle?`.
- After the rows: `ProjectMembership.sync!` for each entity whose `part_of` edge changed (Collision → conflict),
  recount `memory_observations_count` for touched entities.
- Redo (`undo` set undone) is the same code: the undo set's own audit rows are inverted.

**`ChangeSetUndo::ReviewRows`**: for each noted row still holding its `after.status`, write back `before` (rows deleted
by the cleanup job, or changed since, are skipped and listed in the message, never a conflict); delete the
suppressions in `suppressions_created`; re-insert `suppressions_deleted` (skip if the signature exists).

**`app/controllers/changes_controller.rb`** (operator only: no `allow_guest`): `POST /changes/:uuid/undo`
(`resources :changes, only: [], param: :uuid { post :undo, on: :member }`). CSRF protected (normal
`ApplicationController`). Responses: Turbo Stream that renders a toast into `#toasts` (success: "Undone: <summary>",
failure: the refusal + conflicts) with `:ok` / `:conflict` (409) / `:unprocessable_content` (window passed, not
undoable) / `:not_found`; HTML falls back to `redirect_back(fallback_location: root_path)` with a flash. Strings in
`config/locales/ui.en.yml` (`ui.changes.*`). `ChangeSetUndo` maps `ProjectMembership::LockTimeout` to "Busy, retry
shortly" (503).

## B2. Retention

`app/jobs/change_set_prune_job.rb` (queue `low_priority`), scheduled in **both** `development` and `production` in
`config/recurring.yml` (`at 5:30am every day`): in batches of 1,000, (1) `snapshot = NULL, snapshot_bytes = NULL` where
`created_at < 30.days.ago` (merge windows are 7 days, audit windows 30, so nothing undoable loses data), (2) delete rows
older than `AuditLog::MAX_AGE_DAYS` (90) that no audit row references any more (`undo_of_id` is `ON DELETE SET NULL`).

## C1. Merge snapshot (every merge path)

**`app/services/entity_merge_snapshot.rb`**, called by `merge_into_once` inside the transaction, after the
row locks and the refusals:
- `before = EntityMergeSnapshot.capture_before(source, target)`:
  - `source`: every `memory_entities` column (incl. `id`, `project_id`, `aliases`, `description`, `created_at`,
    `embedded_at`) plus `"embedding_text"` from one `SELECT VEC_ToText(embedding) FROM memory_entities WHERE id = ?`;
  - `target`: `id`, `aliases_before`;
  - `observation_ids`: `source.memory_observations.pluck(:id)`;
  - `relations`: full rows (all columns) of every relation with `from_entity_id` or `to_entity_id` = source (one
    query); `children`: `[entity_id, project_id]` of the `part_of` children (from that list).
- run the existing merge steps unchanged;
- `EntityMergeSnapshot.complete(before, target)` (after `source.destroy!`): `aliases_after` (reload target), and for
  each captured relation one batched lookup by id: still present → `repointed` with `from_after/to_after`; gone →
  `destroyed` (keep the full row).
- `Current.change_set.add_merge_step!(step)` with the step `{ source:, target:, observation_ids:, repointed:, destroyed:,
  children:, at: }`. A snapshot write failure **raises and rolls the merge back** (spec it). Over the size cap the
  merge still succeeds and the set becomes `none/snapshot_too_large` (Decision 5).
- Wrap the source's own `destroy!` so its `delete` audit row (and the observation/relation audit rows of the merge)
  count as "inside a merge step" for the strategy rules (`context.within_merge_step { … }`).
- Query budget: the snapshot adds at most **5 queries per merge**, independent of the number of observations and
  relations (spec with `ActiveSupport::Notifications`). Keep `node_operations_strategy.rb` under 500 lines; if needed,
  move the private merge helpers to `app/strategies/node_operations_strategy/merge_helpers.rb`.

## C2. Merge undo and redo

**`ChangeSetUndo::Merge`** (`app/services/change_set_undo/merge.rb`), inside B1's lock + transaction, for the set's
merge steps **in reverse order**:
1. Lock `[target, children, relation endpoints]` `ORDER BY id FOR UPDATE`.
2. **Refuse** (collect all, then raise): target gone (if a later set deleted it, name that set: "undo <uuid> first");
   a row with `source.id` exists; an entity named `source.name` exists in `source.project_id`'s scope (or the project
   is gone); any `observation_ids` row missing or not owned by the target; any `repointed` relation missing or not at
   its `*_after` endpoints; any re-pointed or re-created `part_of` edge would create a cycle.
3. Re-insert the source with its **original id**: `MemoryEntity.new(source attrs except embedding/embedding_text/
   project_scope/memory_observations_count).save!` (validations run; Auditable writes a `create` row in the undo set;
   `set_initial_embedding` is suppressed), then one statement
   `UPDATE memory_entities SET embedding = VEC_FromText(?), embedded_at = ?, created_at = ? WHERE id = ?` with the
   snapshot values (`embedded_at` NULL in the snapshot stays NULL). **No re-embedding and no zero-vector placeholder.**
4. Move `observation_ids` back (`update!(memory_entity_id: source.id)`; `trust_score` is recomputed by
   `before_save`, never restored from a stored value: Decision 8). Vectors untouched.
5. Re-point `repointed` relations to their `*_before` endpoints. Re-create `destroyed` relations with their original
   ids, **skipping** (and reporting) any whose triple or id exists now.
6. Target aliases: remove only `aliases_after − aliases_before` (case-insensitive), keep anything added since. This
   clears the target's `embedded_at`; B1 step 7 re-embeds it after the lock.
7. `ProjectMembership.sync!` for the source and every child (Collision → conflict), recount
   `memory_observations_count` on source and target.
- **Redo** (undoing the `undo` set of a merge): re-run `NodeOperationsStrategy#merge_into(source.id, target.id,
  change_set_kind: "redo")`, which writes a fresh merge snapshot, so the redo is itself undoable.

**Concurrency** (Steve's rule: block or queue, never race): undo, merges, `graph_write` part_of writes, imports, the
backfill and review applies all take the membership lock first, so they serialize; the row locks stop the remaining
writers (`graph_edit`) from interleaving; a background embed that read the old text can't land because
`store_vector` compares `updated_at`.

## D. Docs

- `docs/architecture.md`: a "Change sets and undo" section (what records a set, strategies, windows, what is not
  undoable, embeddings on undo, the lock order).
- `docs/garbage_collector.md` (or wherever retention is listed): `ChangeSetPruneJob`.
- `docs/guides/ui-guide.md`: one paragraph: operator-only undo, guests can't, `POST /changes/:uuid/undo`.
- `docs/mcp_tools.md`: one sentence: merges and graph writes are recorded and an operator can undo them; agents can't.
- `ui-dashboard-plan.md` is not edited by this PR (Steve updates the plan).

## Specs

All synthetic, test-DB truncate before and after (`ui-dashboard-plan.md` §0.1).
- `spec/models/change_set_spec.rb`: kinds/patterns; lazy persistence (no row without a change; one row for many
  writes; rollback of the first write removes the row and the next write re-inserts); join semantics; every strategy
  transition; size cap; `undoable?`.
- `spec/models/concerns/auditable_change_set_spec.rb`: `change_set_id` stamped; NULL without a context; an audit
  failure still never blocks the write and marks the set `audit_incomplete`.
- `spec/services/change_set_recording_spec.rb`: one example per row of the A2 table (kind, actor, subject);
  `compaction:<run_id>` actor; review row/suppression notes.
- `spec/services/change_set_undo/audit_inverse_spec.rb`: each inverse (create/update/relation delete, observation
  obsolete → active with `obsoleted_at` cleared); refuses when changed since (message names actor and time); refuses
  hard-delete sets; redo.
- `spec/services/change_set_undo/review_rows_spec.rb`: apply/dismiss/restore round trips incl. suppressions.
- `spec/strategies/node_operations_strategy_merge_snapshot_spec.rb`: every caller path writes a snapshot
  (`graph_delete`, review apply, API merge, `merge_node`, compaction); a failing snapshot write rolls the merge back;
  query budget; a 50-merge `graph_delete` batch yields one set with 50 steps.
- `spec/services/change_set_undo/merge_spec.rb`: round trip restores the same ids, names, aliases, observation owners,
  relation endpoints and ids, `project_id`s, `embedded_at` and **the embedding bytes** (compare `VEC_ToText`); target
  embedded_at NULL then re-embedded (stub the HTTP client); refuses on name collision, moved observation, moved child,
  target deleted by a later merge (names that set), id taken, window passed; skips an existing triple; undo of undo =
  redo and redo is undoable.
- `spec/services/change_set_undo_concurrency_spec.rb` (`self.use_transactional_tests = false`, clean up in `after`):
  an undo racing a `graph_write` on the same target blocks on the membership lock, then refuses or succeeds; never a
  500, a partial state or a leftover lock.
- `spec/requests/changes_spec.rb`: operator 200 (Turbo Stream toast) / 409 / 422 / 404; guest 403; signed out →
  login; CSRF token required.
- `spec/requests/role_matrix_spec.rb`: add `ChangeSet.count` to `record_counts`.
- `spec/jobs/change_set_prune_job_spec.rb`: nulls old snapshots, deletes 90-day rows without audit rows, keeps the rest.
- All existing merge, review, graph-write/delete and dream-state specs stay green **unchanged** (except adding
  assertions).

## Release: 1.57.0 (commit R)

- `lib/graph_mem/version.rb:4`: `"1.56.0"` → `"1.57.0"`.
- `skills/graph-mem-mcp-toolset/SKILL.md:18`: `graph-mem-version: "1.56.0"` → `"1.57.0"` (`spec/docs/agent_text_sync_spec.rb` checks they match).
- `CHANGELOG.md`: under `## [Unreleased]` add `## [1.57.0] - <merge date>` with `### Added` (change sets for graph
  writes, merges, review actions and compaction auto-merges; merge snapshots; operator-only undo of merges, edits,
  relation changes and review actions within their window; `POST /changes/:uuid/undo`; nightly `ChangeSetPruneJob`),
  `### Changed` (audit rows carry `change_set_id`; compaction auto-merges are now undoable for 7 days).

## Size and split

Estimate: **about 2,400-2,800 changed lines, roughly half specs** (A ≈ 700, B ≈ 800, C ≈ 900, D+R ≈ 150).
**Decision (changeable): one PR.** Merge undo is the point of UI-4a; reviewing the infrastructure without its main
consumer would hide design mistakes, and the commit order keeps a split cheap. If the PR passes ~3,000 lines, stop and
propose the split:
- **UI-4a-1** (A1, A2, B1, B2, D for those parts): change sets, recording, audit-inverse and review-row undo, endpoint,
  prune. CHANGELOG lines under `## [Unreleased]`, **no version bump**. Branch `claude/ui-4a1-change-sets`.
- **UI-4a-2** (C1, C2, rest of D, R): merge snapshots, merge undo/redo, concurrency spec, **1.57.0**. Branch
  `claude/ui-4a-1.57.0`.

## Decisions (changeable)

1. **Lazy change sets, no new transaction or lock.** `ChangeSet.record` only sets `Current.change_set`; the row is
   inserted by the first write, in that write's transaction. Wrapping callers in a new transaction would break the
   advisory-first lock order (a transaction opened before `with_membership_lock`) and `merge_into`'s retry loop.
2. **The merge preview, `EntityMergeService` and the digest check move to UI-4b**, their only consumer (the Explore
   merge dialog). UI-4a keeps the hook they need: `merge_into(…, change_set_kind:)`.
3. **One `snapshot` JSON column with sections** (several merges per set are possible: `graph_delete` allows 50
   operations) instead of a single-merge snapshot or a second table.
4. **No DB foreign key on `audit_logs.change_set_id`** (index only): keeps the migration instant on a large table;
   change set rows are only deleted after their audit rows are pruned.
5. **Snapshot cap 4 MB**: over it the merge still runs and the set is marked not undoable (with the reason).
6. **Imports, scans, observation dedupe and GC are not recorded** in UI-4a (bulk work with its own report and history;
   UI-6 can add attribution).
7. **No MCP and no `/api/v1` exposure.** Agents' writes are recorded; only the operator can undo (web or console).
8. **Trust scores are recomputed, not restored** (the ranker is time-dependent and runs on every save).
9. **§5.3 step 8 dropped:** merges don't close review rows today (finding F7). Dangling rows are dismissed by UI-5's
   `dangling` policy inside its own change set; review-row changes are recorded by the review actions themselves
   (`review_rows`, suppressions) and undone with them.
10. **Homogeneous sets only:** a set mixing merges with other writes, or containing a hard delete of an entity or
    observation, is recorded but not undoable. Relation deletes and observation obsolete marks stay undoable.
11. **Undo re-embeds after releasing the lock** (inline embeds suppressed during the undo); the restored source keeps
    its snapshot vector and `embedded_at`. Merges themselves keep today's behaviour (target re-embed in `after_commit`).
12. **Windows are constants** (merge 7 days, everything else 30), not settings; the 10-minute toast is a UI-4b concern.
13. **Redo = undo of an undo**, recorded as kind `redo` and itself undoable; the original stays `undone`.

## Acceptance criteria

- Any merge made by any path (MCP `graph_delete`, review apply via web or MCP, `/api/v1/…/merge_into`, `merge_node`,
  compaction) can be undone from the console with `ChangeSetUndo.call(uuid)` within 7 days, restoring ids, owners,
  edges, aliases, project scope and the source's embedding bytes; refusals are all-or-nothing with a readable list.
- `graph_write`/`graph_edit`/`graph_delete` (without hard deletes) and review apply/dismiss/restore sets undo within
  30 days; hard-delete and mixed sets say why they can't.
- Guests get 403 on `/changes/*/undo` and no change set is written (role-matrix spec); `/mcp*` and `/api/v1` unchanged.
- Migrations reversible; `db/structure.sql` keeps every vector column, `VECTOR KEY` and trigger; `db/schema.rb` untouched.
- Required specs green; the **full suite run alone** green; `bin/rubocop` and `bin/brakeman` clean; the test DB has 0
  rows in every table before and after; existing merge/review specs unchanged and green.
- Files under ~500 lines, methods under ~60; version 1.57.0 in `version.rb` and `SKILL.md`; CHANGELOG entry; docs updated.
- **One PR against `main`**, CI green, body with the scope, the decisions above and a console transcript of a merge →
  undo → redo on synthetic data. Fix the review bot's should-fix findings with new commits; no force-push after review.

## Stop and ask Steve if

- any quoted line no longer matches the code, or `main` isn't at 1.56.0 when you start;
- `ActiveRecord::Base.current_transaction.after_rollback` isn't available or doesn't fire for nested transactions;
- an existing merge, review or dream-state spec needs changing (not just extending) to pass;
- the migration diff drops or rewrites a vector column, `VECTOR KEY` or trigger line;
- an explicit-id insert or `VEC_FromText` restore doesn't round-trip the embedding bytes exactly;
- recording needs a transaction or lock around an existing entry point;
- a route can't be classified in the role matrix, or anything seems to need an MCP tool or `/api/v1` endpoint;
- the PR grows past ~3,000 changed lines (then propose the split above).
