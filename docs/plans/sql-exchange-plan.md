# Plan: SQL-script export/import for graph_mem (idempotent project sync)

> Status: approved by Steve on 2026-11-19, not started. Written against `main` at ef3c900 (1.91.0),
> rechecked against `main` at a0869d4 (still 1.91.0).
> Nothing in the repository is touched and no branch is created until Steve says the repo is free.

> **Revision 2026-11-19 (review).** Changes folded in after a review against the code on `main`:
> 1. Newer wins: checked which writes move `updated_at` without a content change. Derived writes
>    (embeddings, keywords, trust score, counters, membership backfill) don't; the Cloud toggle on
>    a Project root does, so PR 1 makes it timestamp-neutral. Ties are `kept_local`.
> 2. Validator hardened (MariaDB executable comments, `--`/`#` comments, backslash escaping, a
>    pinned `sql_mode` without `NO_BACKSLASH_ESCAPES`, an upload size cap) and moved to PR 1, so
>    the rake import is validated from the start.
> 3. The sync endpoint keeps JSON as its default (`format=sql` opts in); only the UI defaults to SQL.
> 4. Each template version declares the newest schema it supports; a graph-table migration bumps
>    the format version.
> 5. `trust_score` is no longer exported; cloud flags stay off for new rows and are cleared like
>    the model callback does when a root stops being a root.
> 6. The hand-run lock name is the one `ProjectMembership.lock_name` builds; observations match on
>    a SHA2 of the content; exporter de-duplication remaps lifecycle links; the contradiction pass
>    gets the touched entities; compaction after an import starts only when review rows were seeded.
> 7. Docs: hand runs only on a file you exported yourself, never with `mariadb --force`; no machine
>    or live-project names in the repo.
>
> Added later the same day: an opt-in **Run full maintenance now** after an import (report checkbox,
> `FULL=1` on the rake task); the release version becomes "next minor" (see Delivery).

## Context

Today graph data moves between instances as a JSON tree (`ExportStrategy`, format 1.0) that the
import has to *match and review*: fuzzy root matching, one decision per root, synchronous execute.
It is also lossy: observation `status`, `perspective`, supersede links and entity `description`
are not exported, so retired facts come back active.

Goal: a second format, a **self-contained SQL script**, that becomes the default export. Running
it on another graph_mem database adds what is missing, updates what is older, deletes nothing, and
either commits everything or nothing. Target workflow: work on `<project>` on a source machine,
export that project, import the script on a target machine to bring its `<project>` subgraph up
to date (or create it). Duplicates the script cannot resolve by key are left to the background jobs
(auto-merge or review rows). JSON export and the reviewed JSON import stay as they are.

## Decisions (Steve, 2026-11-19)

1. **Newer wins.** A row that matches by key but differs is updated only when the incoming
   `updated_at` is later; otherwise the local row is kept and reported as "kept local". A tie
   (same `updated_at`, different content) is also "kept local" and listed in the report.
   *Review note:* on `main` the derived writers leave `updated_at` alone: `EmbeddingService#store_vector`
   (raw `UPDATE`), `FactKeywords` and `FactKeywords::LlmWords` (`update_columns`), the trust-score
   recomputes (`update_column`), the `memory_observations_count` counter cache (no `touch`) and its
   GC repair, and the membership backfill (`update_all(project_id:)`). There are no `touch: true`
   associations and no `ON UPDATE` timestamp columns. The one non-content write that does bump it
   is the Cloud toggle (`Projects::CloudAccessController#update`, `project.update!`), which would
   make a Project root "kept local" against a newer source description. PR 1 changes it to
   `save!(touch: false)` (validations and callbacks still run) and adds a spec that each derived
   writer above leaves `updated_at` unchanged, so `updated_at` stays a content timestamp and no
   migration is needed. Merges, GC link repointing and review-applied confidence changes are real
   local changes and keep bumping it.
2. **Retire/move are updates.** Obsolete/superseded status (with its link) and a changed
   `part_of` parent are applied by `UPDATE` under rule 1. No row is ever deleted.
3. **Embeddings are regenerated on the target**, not carried in the script.

## Approach

One generated `.sql` file that carries the data in staging temp tables plus a fixed merge
section written in plain SQL. The same file runs two ways:

- **in the app** (operator UI or rake task): validated, dry-run for a preview, executed over the
  ActiveRecord connection, followed by the post-import jobs. This is the recommended path.
- **by hand**: `mariadb graph_mem < file.sql`. Same data result; derived values are then filled by
  the nightly jobs.

Rejected: (a) a data-only file with the merge logic in Ruby: not a runnable script, and not what
was asked; (b) plain `INSERT ... ON DUPLICATE KEY UPDATE` on the real tables: ids differ per
instance and observations have no unique key, so keys must be resolved through staging tables;
(c) shelling out to the `mariadb` client from the app: `SubprocessGuard` forbids processes under
`app/` and `lib/` (stored convention), and `StructureLoader` already executes scripts in-process.

## Script format (`graph_mem-sql v1`)

```
-- graph_mem-sql v1
-- app: 1.92.0  schema: 20261112120000  exported_at: 2026-11-19T10:00:00Z
-- roots: SynthPrj (Project)   counts: entities=84 observations=912 relations=140
-- embedding_model: nomic-embed-text/768 (informational)   sha256: <digest of the body>
[1 preamble]  SET NAMES utf8mb4; SET time_zone='+00:00'; SET SESSION sql_mode=<pinned list>;
              START TRANSACTION; GET_LOCK(CONCAT('graph_mem.project_membership:', DATABASE()), 60);
              DROP TEMPORARY TABLE IF EXISTS gm_*;
[2 guards]    BEGIN NOT ATOMIC ... SIGNAL SQLSTATE '45000' ... END   (DELIMITER //)
[3 staging]   CREATE TEMPORARY TABLE gm_stage_entities / _aliases / _observations /
              _relations / _refs  (utf8mb4_general_ci, like the real tables)
              INSERT INTO gm_stage_* (...) VALUES (...),(...);      <- the only variable part
[4 resolve]   gm_map_entities(src_id -> target_id, action), gm_map_observations(...)
[5 merge]     entities -> observations -> lifecycle links -> relations -> counters
[6 checks]    post-merge integrity guard (SIGNAL on violation)
[7 record]    INSERT audit_logs rows + one operation_progresses row (see "Record of affected rows")
[8 report]    SELECT table, action, rows  (summary)
              SELECT table, action, id, project, entity, detail, changed  (affected rows)
              COMMIT;
```

Sections 1, 2, 4–8 are a fixed template per format version; only the staging `INSERT`s vary.
Only temporary-table DDL is used, so nothing commits implicitly. Any error aborts the client
(or raises in the app) before `COMMIT`, so nothing is written.

The `sql_mode` is pinned to an explicit strict list (`STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,
NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION`, final list fixed in step 0). It must never
contain `NO_BACKSLASH_ESCAPES`: the writer quotes through `connection.quote`, which escapes with
backslashes, and the validator scans with the same rule. A spec pins the list.

The lock name is the one `ProjectMembership.lock_name` builds (`LOCK_NAME_PREFIX` +
`":"` + current database), so a hand run and app writes serialize on the same lock. The template
renders it from the constant, and a spec checks the rendered expression evaluates to
`ProjectMembership.lock_name`.

**What is exported.** Selected roots, as in today's picker:
- a Project root → itself + `ProjectMembership.member_ids` (the set that matches `project_id`),
  plus nested Projects and their members (option, default on);
- a non-Project root (global scope, e.g. "User Preferences") → itself + `part_of` descendants.

Columns carried: entity `name, entity_type, aliases, description, created_at, updated_at`;
observation `content, confidence, source, valid_from, valid_until, tags, status, obsoleted_at,
obsolescence_reason, perspective, created_at, updated_at` + supersede/outdated links as staging
keys; relation `relation_type, weight, confidence, properties, created_at, updated_at`.
Never carried: ids as ids (only as staging keys), `project_scope` (generated), `embedding`,
`embedded_at`, `keywords*`, `trust_score` (recomputed on the target, so the app path and a hand
run end up with the same value), `cloud_allowed`, `cloud_root`.

**Cloud flags.** New rows get the column defaults (`cloud_allowed = 0`, `cloud_root NULL`), so an
imported Project starts cloud-off and the operator turns it on on the target. Members never carry
the flag: `Llm::CloudGate` reads it from the Project root of each project id, so a moved entity
follows its new `project_id`. The merge never sets either column to anything but off. Raw SQL skips
`drop_cloud_access_off_root`, so any `UPDATE` that changes `entity_type` away from `Project` or
gives a root a `project_id` also sets `cloud_allowed = 0, cloud_root = NULL` in the same statement,
as the callback does. Nothing here touches the anonymizer.

Relations: all with both ends in the set, plus edges crossing the boundary (either direction).
The outside end goes to `gm_stage_refs` as (project root name or NULL, name, type) and is
resolved read-only on the target; an unresolved ref skips that edge and is listed in the report.
No stub entities are created.

**Keys and merge rules** (name comparisons use the tables' `utf8mb4_general_ci`, same as the
unique keys; observation content is compared as `SHA2(content, 256)` on both sides, which avoids
the `PAD SPACE` rule that makes `"abc"` equal `"abc "` and slow `TEXT` comparisons):

| Row | Match | New | Matched |
|---|---|---|---|
| Entity | `(scope, name)`: scope-0 rows first (Project roots, globals), then members inside the mapped root. Fallback: exactly one same-type entity in that scope whose alias equals the incoming name, or whose name is an incoming alias, and not already claimed | `INSERT` with `project_id` = mapped root, `embedded_at NULL`, source timestamps | aliases are always unioned (written with `\|`); `entity_type`, `description` updated when incoming is newer; `embedded_at = NULL` when an embedding field changed. On an alias match the local name stays and the incoming name becomes an alias |
| Observation | `(mapped entity, SHA2(content))`; if several, active first, then highest id. The exporter emits one row per `(entity, SHA2(content))`, chosen the same way in SQL, and remaps the supersede/outdated links of every dropped duplicate to the kept row (a link to itself becomes NULL) | `INSERT` with status/lifecycle fields, `keywords_at NULL`, `embedded_at NULL` | when newer and different: `confidence, source, valid_*, tags, perspective, status, obsoleted_at, obsolescence_reason`; `embedded_at = NULL` if `source`/`tags` changed |
| Supersede/outdated link | second pass through `gm_map_observations` | set | set when the row was inserted or updated; a `superseded` row whose target cannot be mapped is stored as `obsolete` (keeps the lifecycle validation true) |
| Relation | `(from, to, relation_type)` | `INSERT` | `weight, confidence, properties` when newer |
| `part_of` | the entity's existing `part_of` row | `INSERT` | parent differs and incoming edge is newer → `UPDATE ... SET to_entity_id` on the existing row (a move, not a delete + insert) |

Then: recount `memory_observations_count` for touched entities; fill `gm_report` and
`gm_touched(kind, target_id, action)`.

**Guards** (each raises with a readable message and rolls everything back): target schema version
older than the script's, or newer than the newest schema the script's template version supports
(the message names both versions); lock not obtained; an incoming Project root whose name matches a
non-Project entity; after the merge, any touched entity with two `part_of` parents, a `part_of`
cycle (recursive CTE), or a member whose `project_id` is not its mapped root.

## Record of affected rows (added 2026-11-19)

Every run, in the app or by hand, shows and records what it touched. All of it is written inside
the same transaction, so a rolled-back run leaves no record and a dry run shows the lists without
storing them.

**Collected while merging.** `gm_touched(tbl, target_id, action, changed)` gets one row per
affected row: `action` is `new`, `updated`, `kept_local` or `skipped_link`; `changed` is a JSON
object `{field: {from, to}}` built by an `INSERT ... SELECT` that runs *before* each `UPDATE`, so
the old values are captured. Unchanged rows are only counted.

**Shown (section 8).** Two result sets at the end of the script:

```
table                action       rows
memory_entities      new             6
memory_entities      updated         4
memory_entities      unchanged      74
memory_entities      kept_local      1
memory_observations  new            58
...
table                action      id    project         entity        detail                       changed
memory_entities      new         9012  SynthPrj        ImportRunner  Service                      NULL
memory_entities      updated     8841  SynthPrj        SolverBase    Class                        {"description":{"from":"…","to":"…"}}
memory_observations  updated     40233 SynthPrj        SolverBase    Uses the legacy matcher fo…  {"status":{"from":"active","to":"obsolete"}}
memory_relations     new         5120  SynthPrj        ImportRunner  depends_on -> SolverBase     NULL
memory_relations     skipped_link NULL SynthPrj        ImportRunner  relates_to -> (missing) Foo  NULL
```

`detail` is the entity type, the first 80 characters of the observation, or `type -> other end`.
By hand: `mariadb --table graph_mem < file.sql > import.log` prints and keeps both tables.

**Recorded in the database (section 7).**

- `audit_logs`: one row per new or updated row, in the shape `Auditable` writes
  (`app/models/concerns/auditable.rb`): `auditable_type` = the model name, `auditable_id`,
  `action` `create`/`update`, `changed_fields` = a snapshot for creates and the `{from, to}` JSON
  for updates, `actor` = `sql_import`, `reason` = `sql_import:<operation id>`. The rows then show
  in System › Audit log and in each entity's history like any other write, and the old values of
  an overwritten field stay recoverable. `kept_local` and `skipped_link` are not audit events.
- `operation_progresses`: one `import` row with `status = completed`, `counters` = the summary,
  `details` = `{format: "sql", source: <header fields>, roots, affected: [...]}` where `affected`
  is the second result set (ids, action, changed field names; capped at 5,000 entries, with the
  full count kept). Its `operation_id` is `COALESCE(@gm_operation_id, UUID())`: the app sets the
  variable before running so the row is the one its report page shows; a hand run generates its
  own id and still appears in the Imports history, labelled "run outside the app".

**In the app.** The dry-run preview and the final report page show the summary plus the affected
rows as a filterable table (by table and action), each row linking to its entity, with a
"Download as CSV" link. `graph_mem:import_sql` prints the same two tables to the terminal.

To check in step 0: the exact snapshot keys `auditable_snapshot` writes, and that audit rows with
no `change_set_id` render correctly in the audit log views.

## New code

Follow the existing layering; keep each file under 500 lines.

- `app/services/sql_export/scope.rb` — root ids → entity/observation/relation sets and refs.
  Reuses `ProjectMembership.member_ids` (`app/services/project_membership.rb:148`) and
  `RelationSemantics.descendant_ids`.
- `app/services/sql_export/template.rb` + `lib/graph_mem/sql_exchange/v1/*.sql` — the fixed
  sections, one directory per format version. Each version declares the newest schema version it
  supports (`max_schema`, set to the current schema when the version is written); the guard
  refuses a target whose schema is newer and names both versions. Any migration that touches
  `memory_entities`, `memory_observations` or `memory_relations` adds a new format version (a spec
  fails when the current schema is past the newest `max_schema`).
- `app/services/sql_export/writer.rb` — streams header + staging inserts (batches of ≤200 rows
  or 512 KB, values through `connection.quote`) + template; yields progress.
- `app/services/sql_import/validator.rb` — marker and version, body digest, fixed sections
  byte-equal to this app's template for that version, and every other statement an
  `INSERT INTO gm_stage_<known> (<known columns>) VALUES` made only of literals (strict scanner:
  `NULL`, numbers, quoted strings). An uploaded file therefore cannot run arbitrary SQL.
  The scanner rejects MariaDB executable comments (`/*!`, `/*M!`) anywhere, rejects any comment
  (`/* */`, `-- `, `#`) outside the fixed sections and the header lines, and reads quoted strings
  with the same backslash rules `connection.quote` writes (so `\'` cannot close a string early).
  It also checks the pinned `sql_mode` line. Uploads above a size cap (default 50 MB, a constant
  in the validator, not a new setting) are refused before reading.
- `app/services/sql_import/executor.rb` — runs the statements on one connection. Splits with the
  DELIMITER-aware `statements` from `lib/graph_mem/scan_profile/structure_loader.rb:20` (extract
  it to a shared module). Skips the file's own `START TRANSACTION`/`COMMIT` and wraps the run in
  `ActiveRecord::Base.transaction` inside `ProjectMembership.with_membership_lock`, so a dry run
  is `raise ActiveRecord::Rollback` and specs keep working. Reads `gm_report`/`gm_touched`
  before the end. Calls `CompactionValve.request_pause_if_running!` first.
- `app/jobs/sql_import_follow_up_job.rb` — see "After the import".
- `lib/tasks/graph_mem.rake` — `graph_mem:export_sql[project,...] OUT=path` and
  `graph_mem:import_sql FILE=path [DRY_RUN=1]` (validator + executor + follow-up). The validator
  ships with the rake task in PR 1, so no import path ever runs an unvalidated file.

Changed code:

- `app/jobs/export_job.rb`, `app/controllers/projects/exports_controller.rb`,
  `app/views/projects/exports/{index,show}.html.haml`, `config/locales/projects.en.yml`: a format
  choice (SQL script, preselected; JSON), stored in `OperationProgress.details`, file
  `export_<uuid>.sql`, correct download name and type.
- `app/controllers/data_exchange_controller.rb`: `format=sql|json` on the sync endpoint; JSON
  stays the default there.
- `app/controllers/projects/cloud_access_controller.rb`: the toggle saves with `touch: false`
  (see Decision 1), PR 1.
- `app/services/import_flow.rb`, `lib/import_session.rb`,
  `app/controllers/projects/imports_controller.rb`, `app/views/projects/imports/*`: detect the
  file kind by its first line; `.sql` goes validate → dry run → preview → execute → report.
  JSON keeps its current review flow untouched.
- `app/strategies/import_execution_strategy/reporting.rb:6`: move
  `recompute_trust_for_touched_entities` into a small shared service used by both imports.

Operator view of an SQL import (replaces the per-row review):

```
Import SynthPrj.sql            from graph_mem 1.92.0, exported 2026-11-19 10:00 UTC
                 new   updated   unchanged   kept local
Entities           6        4          74            1
Observations      58       12         840            2
Relations          9        1         130            0
Matched by alias: "Synth Prj" -> SynthPrj
Skipped links (other end not found here): 2   [show]
[ Execute ]  [ Cancel ]      Tip: take a backup first (System > Backups)
```

## After the import (derived data and residual duplicates)

Raw SQL skips the model callbacks, so `SqlImportFollowUpJob(operation_id)` does, for the ids in
`gm_touched`:

1. recompute `trust_score` (shared service above);
2. `EmbeddingService#backfill_all` (rows with `embedded_at IS NULL`); retry if the lock is busy;
3. request `FactKeywordsJob` for new observations and enqueue `FactSupersedeJob` for new active
   `source-fact` ones (what `after_commit` would have done);
4. seed review rows through `CompactionReviewService.seed_report(report_type:
   "compaction_review", source: "sql_import", source_ref: operation_id)`:
   - `entity_merge` for touched entities whose name or alias equals another entity's name or
     alias in the same scope (scored with `EntityMergeEvidence`);
   - `delete_observation` for a newly inserted active observation whose nearest active sibling on
     the same entity is within `AppSettings.import_observation_duplicate_max_distance`
     (no background job catches reworded duplicates inside one entity today);
5. record the touched entity ids in the operation's `details` (`contradiction_entity_ids`); the
   stale-memory contradiction pass (`StaleMemoryScanner.detect_contradictions`) adds the ids of
   imports completed after its watermark to the entities it scans. Imported rows keep the source
   `updated_at`, so its `updated_at` filter alone would miss them;
6. `CompactionRunner.start_or_resume!`, only when step 4 seeded at least one review row. The
   normal run walks every entity, so near-identical same-type entities are auto-merged
   (distance < 0.10, score ≥ 10) and the rest queued, exactly as on any other night. Without seeded
   rows the import leaves compaction to its schedule, so freshly imported entities are not
   auto-merged straight away. Step 2 runs first because merge detection ignores unembedded rows and
   a resumed run skips the pre-flight sweep.

After a hand-run script the same things happen later through GC (embeddings, counters), the
nightly keywords job and the next new compaction run; steps 1, 3, 4 and 5 are skipped. The docs
will say to prefer the rake task, to run a hand-run script only on a file you exported yourself
(it skips the validator), and never with `mariadb --force` (it would keep going past a failed
statement and commit a partial merge).

**Opt-in full maintenance (added 2026-11-19).** The import report (and the dry-run preview, for
the real run) has a **Run full maintenance now** checkbox, off by default; the rake task takes
`FULL=1`. When set, once `SqlImportFollowUpJob` has finished, the import starts the existing
"Run all scheduled jobs now" run: `ScheduledRunJob.start!(trigger: "sql_import")` (a new trigger
constant next to `TRIGGER_MANUAL`/`TRIGGER_CATCH_UP` in `app/jobs/scheduled_run_job.rb`). It runs the
`ScheduledRun::ORDER` steps from `app/services/scheduled_run.rb`, each skipped when its own setting
is off: `DatabaseBackupJob`, `GarbageCollectionJob`, `DreamStateCompactionJob`,
`EmbeddingScheduledBackfillJob`, `FactKeywordsJob`, `StaleMemoryScanJob`, `ReviewPolicyJob`,
`MaintenanceReportRowCleanupJob`, `ChangeSetPruneJob` and `ExportJob.cleanup_old_exports`. With it
set, step 6 above doesn't start compaction itself (the run's compaction step does). If a run is
already going (`start!` returns nil), nothing new starts and the report says so; the backup step is
taken after the import, so it never replaces the backup the preview recommends. System › Background
jobs shows the run as usual. This also helps after a hand-run script: the follow-up job doesn't run
there, so the docs point to **Run all scheduled jobs now** to get embeddings, keywords, the
contradiction pass and review policies done at once instead of waiting for the schedule.

## Delivery

Step 0 is a throwaway check on the test DB (MariaDB 11.8): temp-table DDL does not commit;
`BEGIN NOT ATOMIC ... SIGNAL` works through `connection.execute` and through the client; a temp
table can be referenced twice in one statement; `REGEXP_REPLACE` and the recursive CTE behave as
the merge SQL needs. If a point fails, the template changes, not the design.

| PR | Content |
|---|---|
| 1 | `SqlExport` (scope, template v1, writer), `SqlImport::Validator`, `SqlImport::Executor`, both rake tasks (import validated), Cloud toggle `touch: false`, round-trip specs. No UI. |
| 2 | Import UI (upload, dry-run preview, execute, report), `SqlImportFollowUpJob`, the contradiction-pass hook, the opt-in full maintenance (checkbox and `FULL=1`). |
| 3 | Export UI and job format choice, SQL as the UI default, sync endpoint `format` (JSON default). |
| 4 | Docs (`docs/guides/ui-guide.md`, `docs/architecture.md`, new `docs/data_exchange.md` with the format reference and the source machine → target machine recipe), CHANGELOG, release as the next minor after Dream State R1a (expected 1.94.0: 1.92.0 was the contradiction auto-resolve policy, 1.92.1 is mcp 1.11.0, 1.93.0 is R1a; see `dream-state-semantics-plan.md`, "Order and size") (`lib/graph_mem/version.rb` then `bin/rails graph_mem:sync_skill_version`). |

PRs 1–3 put their CHANGELOG lines under `## [Unreleased]`. No migration, no new MCP tool, no new
`OperationProgress` type (`export`/`import` are reused). Docs and CHANGELOG use "source machine" /
"target machine" and `<project>` or `SynthPrj`, never real machine or project names.

## Verification

Specs (real MariaDB, `OLLAMA_URL=http://127.0.0.1:9`, run through `rvm use ruby-3.4.12@graph_mem`):

- round trip: export a project, destroy and alter some of its rows, import → equal graph;
- idempotency: importing the same script twice → second run reports only "unchanged";
- newer wins both ways; a tie (same `updated_at`, different content) is `kept_local` and listed;
  obsolete/superseded status and a parent move arrive as updates; row counts never decrease;
- `updated_at` stays put for each derived writer (embedding store, keywords, LLM words, trust
  recompute, counter cache, membership backfill) and for the Cloud toggle;
- content match by SHA2: `"abc"` and `"abc "` are different observations; exporter
  de-duplication remaps supersede/outdated links to the kept row;
- cloud flags: an imported Project is cloud-off; a retyped or re-parented root loses the flag;
- atomicity: a script with one failing statement, and each guard, leaves every table unchanged;
- alias match, ambiguous alias (inserted as new, review row seeded), unresolved external ref;
- validator rejects an edited template, an unknown table, a non-literal value, a wrong digest,
  `/*!` and `/*M!` comments, `--`/`#` comments in the data part, a `\'` string-break attempt, a
  changed `sql_mode` line (and the pinned list has no `NO_BACKSLASH_ESCAPES`), an oversized file;
- schema guard: a template whose `max_schema` is older than the target schema is refused with both
  versions named; lock: the rendered lock expression equals `ProjectMembership.lock_name`;
- dry run writes nothing; follow-up job: embeddings requested, trust recomputed, review rows
  seeded, contradiction ids recorded, compaction started only when rows were seeded; with full
  maintenance on, one `scheduled_run` row with trigger `sql_import` (none when off, and none
  started when a run is already going);
- request specs for both UI flows; job spec for `ExportJob` with each format.

### Scenario spec: restore an older export over an edited graph

`spec/integration/sql_exchange_synth_project_spec.rb`, on the test DB, built with the factories
(randomized names apart from the root), no doubles. It is written first, in PR 1, and drives the
merge template.

1. **Build** `SynthPrj` (Project) with a `part_of` tree at least 3 levels below the root, e.g.
   `SynthPrj ← ModuleA ← ServiceA1 ← MethodA1x`, `SynthPrj ← ModuleB ← ServiceB1`, each node with
   2–3 observations (one of them obsolete, one superseded by another), aliases on some nodes, and
   a few non-hierarchy relations (`depends_on`, `relates_to`) inside the tree.
2. **Export** the whole `SynthPrj` subtree to a script (`SqlExport::Writer`); keep the text.
3. **Edit the graph** after the export time (`travel_to` a later instant):
   - *new subnodes*: add `ServiceA2` under `ModuleA` with observations, and a new observation on
     `ModuleB`;
   - *changed nodes*: change `ServiceA1`'s description and aliases, change one observation's
     tags/confidence, mark one active observation obsolete, move `ServiceB1` under `ModuleA`;
   - *missing rows*: destroy the `MethodA1x` leaf, the whole `ModuleB`-side leaf subtree that is
     left, one observation of `ModuleA` and one `depends_on` relation;
   - *bystander*: create a second Project `OtherPrj` with its own small tree, including an entity
     that has the same name as a `SynthPrj` member, plus one global entity.
   Snapshot every row of the three graph tables (all columns except embeddings) keyed by id.
4. **Import** the script from step 2 (`SqlImport::Executor`).
5. **Verify**:
   - reinstated: the destroyed entities, observations and relation exist again, under the right
     parents, with `project_id` = `SynthPrj`'s id and the exported field values and lifecycle
     status/links;
   - kept local: every row edited in step 3 is byte-identical to the snapshot (description,
     aliases, tags, status, the moved parent), because the local `updated_at` is later;
   - unchanged: every untouched `SynthPrj` row is identical to the snapshot, `updated_at` included;
   - additions survive: `ServiceA2` and the new observation are still there and identical;
   - bystanders: every `OtherPrj` row and the global entity are identical to the snapshot, and the
     same-named entity was not matched across projects;
   - bookkeeping: no table has fewer rows than before the import; each touched entity has one
     `part_of` parent; `memory_observations_count` equals the real count; reinstated rows have
     `embedded_at IS NULL`; the report says `new` = the reinstated rows, `kept local` = the edited
     ones, `updated` = 0.
   - record: the affected-rows list names exactly the reinstated rows (`new`) and the edited ones
     (`kept_local`) with the right ids; `audit_logs` has one `create` row per reinstated row with
     `reason` `sql_import:<operation id>` and none for bystanders; one completed `import` row
     exists in `operation_progresses` with matching counters.
6. **Run it again**: the second import reports only `unchanged`/`kept local`, changes no row and
   adds no audit row. A dry run and a failed run leave no audit or operation row at all.

Two companion examples in the same file reuse the setup:
- *forward sync*: export **after** step 3, restore the step-1 state from a snapshot, import → the
  edits arrive as updates (description, tags, obsolete status, the parent move), additions are
  created, and nothing is deleted; each update has an audit row whose `changed_fields` holds the
  old and new value;
- *fresh target*: delete the whole `SynthPrj` tree, import → the project is created from nothing
  and matches the export; `OtherPrj` is untouched.

By hand: `graph_mem:export_sql[<project>]` on the source machine, load it into a scratch database
with the `mariadb` client and with `graph_mem:import_sql`, compare the two; then the real
source machine → target machine run with `DRY_RUN=1` first. `bundle exec rubocop` and the full suite before each PR.

## My calls (correct any of these)

- The sync endpoint `GET /data_exchange/export` keeps JSON as its default (the UI guide documents
  it as the JSON download for scripts); `format=sql` returns the script. Only the export UI
  preselects SQL. Listed under "Added" in the CHANGELOG (no breaking change).
- Cross-boundary links are made only when the other end already exists on the target.
- An SQL export from another format version is importable while its template directory is still
  in the repo and the target schema is not newer than that version's `max_schema`; otherwise the
  UI refuses it and names the format and schema versions.
- No MCP tool for export/import in this plan (tool budget); it can be proposed separately.

## Known limits

- Deletions and merges done on the source are not replayed. A merged-away entity stays on the
  target and is caught as an alias collision (review row) or by compaction.
- An entity moved to a *different project* on the source is inserted in the new project; the old
  copy stays and is left to compaction/review.
- Observations match on exact content. When the source edits an observation's text, the target
  gets a new row and the old one stays active; the follow-up job's near-duplicate check (step 4)
  or compaction review catches it.
- An SQL import has no one-click undo (no `ChangeSet`); the preview recommends a backup. It does
  write audit rows with the old and new values, so single fields can be put back by hand.
