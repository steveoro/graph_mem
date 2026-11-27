# Data exchange: graph_mem-sql

GraphMem moves graph data between machines as **graph_mem-sql** scripts (1.94.0). This page is the reference: what it is, how to move a project from a source machine to a target machine, the format, the merge rules, the guards and the limits.

- [What it is and when to use it](#what-it-is-and-when-to-use-it)
- [Source machine to target machine](#source-machine-to-target-machine)
- [What happens after an import](#what-happens-after-an-import)
- [Format reference (graph_mem-sql v1)](#format-reference-graph_mem-sql-v1)
- [Merge rules](#merge-rules)
- [Guards](#guards)
- [Hand runs](#hand-runs)
- [Known limits](#known-limits)
- [The sync endpoint, for scripts](#the-sync-endpoint-for-scripts)

Examples use `<project>` and `SynthPrj` for a Project root, and "source machine" and "target machine" for the two installs.

## What it is and when to use it

A graph_mem-sql script (`.sql`) is one self-contained SQL script: the data in staging tables plus a fixed merge section.

- **Import.** It is merged by key in one transaction: what is missing is added, what is older is updated, nothing is deleted, and either everything commits or nothing does.
- **Carries.** Entity `description` and aliases, every observation with its status (`active`, `obsolete`, `superseded`), perspective, validity, tags, confidence, source and supersede / outdated-by links, and relations with weight, confidence and properties.
- **Use it for** keeping a project in step between two machines, repeatedly, and for restoring an older export over a graph that moved on.
- **Where.** Projects › Exports writes it (the only format), Projects › Imports takes it (the only format), the shell runs it with `graph_mem:export_sql` / `graph_mem:import_sql`, and the sync endpoint returns it ([below](#the-sync-endpoint-for-scripts)).

**The GraphMem JSON export and upload were retired in 1.94.0**, with no deprecation period. An old JSON backup can't be imported from the UI any more: Projects › Imports refuses a `.json` file and points to the SQL export. The JSON import engine remains only for `bin/rails graphify:import` (a Graphify `graph.json`) and `bin/rails rails_ast:import`, which run headless.

## Source machine to target machine

The goal: bring the target machine's `<project>` up to date with the source machine's, or create it there.

1. **Export on the source machine.**
   - In the operator UI: Projects › Exports, tick the Project root, **Export selected**, then **Download** (the file is named after the root, `synthprj.sql`; with several roots `synthprj_plus_2.sql`). Files are deleted after an hour.
   - Or from a shell: `bin/rails graph_mem:export_sql[<project>] OUT=path/to/synthprj.sql`. `OUT` defaults to `tmp/exports/<name>.sql`. Several roots go in one call (`graph_mem:export_sql[SynthPrj,UserPrefs]`); `NESTED=0` leaves Projects nested inside the tree out. A name must be a Project root or a global entity: a member of a project is refused ("export its Project instead").
2. **Move the file** to the target machine (any way you like; it contains your graph's text, so treat it like a backup).
3. **Take a backup on the target machine** (System › Backups › **Run backup now**). An SQL import has no one-click undo.
4. **Preview.** Projects › Imports, upload the `.sql` file. It is validated and run as a dry run; nothing is written. Or `bin/rails graph_mem:import_sql FILE=path/to/synthprj.sql DRY_RUN=1`, which prints the same two tables.
5. **Import.** On the preview, **Execute import**. Or `bin/rails graph_mem:import_sql FILE=path/to/synthprj.sql`. Add `FULL=1` (or tick **Run full maintenance now**) to also run every scheduled job once after the follow-up.
6. **Read the report.** It keeps the counts per table (new, claimed, updated, unchanged, kept local), the entities matched by alias or claimed from global, the links that were skipped or dropped, and every affected row; the history on Projects › Imports lists the import afterwards.

The target machine must run the same graph_mem or newer, with a database schema at least as new as the script's ([format and schema versions](#format-and-schema-versions)). The preview is a dry run of the merge at upload time; **Execute** validates the stored file again and runs the merge against the graph as it is then, so the report is the record of what was written.

Running the same file twice is safe: the second run reports only "unchanged" and "kept local".

## What happens after an import

The raw SQL skips the model callbacks, so a job does their work once the import has committed and released the membership lock. `SqlImportFollowUpJob` is queued after every import the app or `graph_mem:import_sql` runs (not after a dry run, and not after a [hand run](#hand-runs)). For the rows the import wrote it:

1. embeds every row without an embedding (the embedding backfill), after a connection check; while another backfill holds the embeddings lock it runs again every minute, up to five times, and the last attempt goes on without the backfill;
2. recomputes trust scores (`ObservationTrustRecompute`, the same service the relation hook and the headless JSON import use);
3. requests keyword paths and queues "Outdated by a fact" for each new source fact, and for each fact that gained the `source-fact` tag;
4. seeds review rows (source `sql_import`): an `entity_merge` for a written entity that shares a name or an alias with another entity of its type in its scope, and a `delete_observation` for a new fact within `import_observation_duplicate_max_distance` of an active fact the entity had before the import ([settings](app_settings_reference.md#imports)). New facts are not compared with each other, so a fresh project import does not propose pairs the source may have reviewed;
5. records the entities it touched, so the stale scan's contradiction pass looks at them too (the imported rows keep the source `updated_at`, which the scan's own filter would miss);
6. starts (or resumes) dream-state compaction, only when step 4 seeded a review row, and runs the review policies for those rows. With **Run full maintenance now** set it starts "Run all scheduled jobs now" with the trigger `sql_import` instead (System › Background jobs shows it); when a run is already going nothing new starts and the report says so.

If the follow-up can't be queued once the import has committed (for example the job queue's database is down), the import still counts as done: its record says `follow_up: failed` with the error, the report shows it, and **Run full maintenance now** starts at once. The scheduled jobs embed the rows and fill their keyword paths; trust scores and review rows come only from the follow-up, so queue it again on the server with `bin/rails runner 'SqlImportFollowUpJob.perform_later("<operation id>")'` (the report shows the command with the id). Only a failure before the commit says "nothing was written"; any later failure names the operation that was written.

Nothing in the job takes the membership lock, so nothing embeds under it. The report page shows each step's outcome in its "After the import" card, with a **Run full maintenance now** button until it has been asked for. When the embedding service is down the card warns how many new facts the near-duplicate check could not compare; on an install without vector columns it says so as a hint.

## Format reference (graph_mem-sql v1)

The closest thing to a reference in the code is the comment block at the top of `lib/graph_mem/sql_exchange/v1/01_preamble.sql`; the fixed sections are the files `01` to `08` next to it, and `SqlExport::Template` (`app/services/sql_export/template.rb`) assembles them.

### Header

The first lines of a script are comments, written by `SqlExport::Writer`. The first is the marker, then `-- key: value` lines (at most ten), ending with the digest:

```
-- graph_mem-sql v1
-- app: 1.94.0
-- schema: 20261124120000
-- exported_at: 2026-11-25T10:00:00Z
-- roots: SynthPrj (Project)
-- counts: entities=84 observations=912 relations=140 refs=3
-- embedding_model: nomic-embed-text/768 (informational)
-- sha256: <64 hex digits: the SHA-256 of everything after the header>
```

`app` is the exporting graph_mem version and `schema` its newest migration. The header names no host and no path; control characters are replaced by spaces and `/*` by `/ *`, so a header can never hold an executable comment.

### The script

After the header the file is one body, checked against `sha256`:

| Part | What it holds | Varies |
|---|---|---|
| 1 Preamble (`01_preamble.sql`) | The usage comment, `SET NAMES utf8mb4`, `SET time_zone`, the pinned `sql_mode`, the membership lock, `START TRANSACTION`, `DROP TEMPORARY TABLE IF EXISTS gm_...`, and the `CREATE TEMPORARY TABLE` of every `gm_` table | no |
| Staging `INSERT`s | `INSERT INTO gm_stage_<table> (<columns>) VALUES (...),(...);`, at most 200 rows or 512 KB each, every value quoted by `connection.quote` | **yes, the only part** |
| 2 Guards (`02_guards.sql`) | Structure and value checks, each raising `SQLSTATE '45000'` with a readable message | no |
| 3 Entities (`03_entities.sql`) | Matching by scope and name, the alias fallback, claims, new rows, newer-wins updates | no |
| 4 Observations (`04_observations.sql`) | Matching by SHA-256 of the content, lifecycle links, new rows, updates | no |
| 5 Relations (`05_relations.sql`) | Matching by `(from, to, type)`, the `part_of` move, new rows, updates | no |
| 6 Checks (`06_checks.sql`) | After the merge: one `part_of` parent, no cycle, the project of every member, lifecycle columns, source-fact rules | no |
| 7 Record (`07_record.sql`) | The affected rows, the `audit_logs` rows and one completed `import` operation row | no |
| 8 Report (`08_report.sql`) | The two result sets, then `COMMIT` | no |

Only temporary-table DDL is used, so nothing commits implicitly. An error before `COMMIT` leaves the real tables as they were.

### Staging tables

The variable part may insert into exactly these tables, with exactly these columns, in this order (`SqlExport::Template::COLUMNS`):

| Table | Columns |
|---|---|
| `gm_stage_meta` | `k, v`: `format`, `app`, `schema`, `exported_at`, `roots` (a JSON array of names) |
| `gm_stage_entities` | `sk, root_sk, name, entity_type, aliases, description, created_at, updated_at` |
| `gm_stage_aliases` | `sk, pos, alias`: one row per alias, without blanks or repeats |
| `gm_stage_refs` | `sk, project_name, name, entity_type`: the outside end of an edge that crosses the export's boundary |
| `gm_stage_observations` | `sk, entity_sk, content, confidence, source, valid_from, valid_until, tags, status, obsoleted_at, obsolescence_reason, perspective, superseded_by_sk, outdated_by_sk, created_at, updated_at` |
| `gm_stage_relations` | `sk, from_sk, to_sk, relation_type, weight, confidence, properties, created_at, updated_at` |

`sk` is a staging key: entities are numbered `1..n`, then references in the same key space; observations and relations have their own. `root_sk` is the staged Project root of a member (`0` for a root or a global entity), so a member's scope is its root. Ids are never carried as ids, only as these keys. Timestamps are UTC with microseconds.

Never written: `embedding`, `embedded_at`, keywords, `trust_score`, `project_scope`, `cloud_allowed`, `cloud_root`. They are derived on the target machine, and an imported Project starts with cloud access off.

What an export contains:

- a **Project root**: itself, its members (`ProjectMembership.member_ids`, the entities its `part_of` tree reaches) and, unless `NESTED=0`, the Projects nested in that tree with their own members;
- **its libraries, one hop of `depends_on`** (1.96.0): for each exported Project (the roots, and the nested Projects when they are exported), each target of the Project's own outgoing `depends_on` that is global and not a Project travels as rows, with its own `part_of` subtree, in the global scope (`root_sk` 0). That is where a library sits after Dream State's swap ([dream_state.md](dream_state.md#phase-2-dependency_edges)): before 1.96.0 such a script carried the edge with the library as a reference only, so its facts and children didn't travel and a target without the library skipped the edge. The hop stops there: a library's own `depends_on` (on another library), a member's `depends_on` and the Projects nested under a library stay references, and so does a `depends_on` to a Project or to a member of another project. The library's other dependents are left out: an edge from outside the export into it (another project's `depends_on` it) is not carried, so the script names no other project for it. A library two exported Projects use travels once;
- a **global root** (for example "User Preferences", or a library exported on its own): itself and the global entities its `part_of` tree owns. A library exported alone carries its subtree and every edge into it, so the Projects that depend on it travel as references only;
- every observation of those entities, one per entity and content: when a local entity holds the same text twice, the active copy (else the highest id) is kept and the supersede and outdated-by links of the dropped copies point at it;
- every relation with an end in the set (but those into a library from outside, above). The outside end of a crossing edge travels as a reference (its Project's name, its name and type) and is only looked up on the target.

The hop needed no change to the template: a script with libraries is a v1 script, and an older v1 importer reads it (a library is staged like a global root's entities).

**Which entities can be exported** (the export picker and `GET /data_exchange/root_nodes`, `SqlExport::Roots`): the Projects, then every entity with no outgoing `part_of` edge, each group by name, capped at 500 with a filter by name. Only `part_of` makes an entity a child (1.96.0; an outgoing `depends_on` did too before), since scope follows `part_of` alone: a global library is a root of its own after its swap, also when it `depends_on` another library.

Relation types are written as the source machine canonicalizes them (`MemoryRelation.canonical_relation_type`, followed until stable), except that a variant of `part_of` that SQL does not read as `part_of` (for example `child_of`) keeps its spelling.

An inert `source-fact` tag is left out (1.96.0): an active fact whose entity is global and not a Project (a library after its swap, a global root's member) is written without that tag. Outside a project the tag does nothing (the fact is no source fact, and nothing is outdated by it), the model refuses it when such a fact is saved, and the import's checks would refuse the whole script for it. The source keeps the tag; every other tag travels as stored.

### Format and schema versions

A format version is a directory under `lib/graph_mem/sql_exchange/` (today `v1`). Each version declares the newest database schema it supports (`SqlExport::Template::MAX_SCHEMA`). A migration that touches `memory_entities`, `memory_observations` or `memory_relations` adds a new format version; any other migration moves the newest version's `max_schema` (a spec fails until one of the two is done).

The script refuses, rolling everything back, a target whose schema is older than the script's (`schema` in the header), and one newer than the version's `max_schema`; each message names both versions. An export from another format version imports while this app still has that version's template directory and the target schema is not past its `max_schema`; the validator refuses a version it doesn't know and names the versions it reads.

### sql_mode

The script sets `sql_mode` to a pinned list:

```
STRICT_TRANS_TABLES,STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION
```

It never contains `NO_BACKSLASH_ESCAPES`: the writer escapes with backslashes, and the validator reads strings by the same rule. The validator compares the line byte for byte, and the app puts the session's `sql_mode`, time zone and character sets back after the run.

### Lock

The script takes the membership lock (`GET_LOCK` on `graph_mem.project_membership:<database>`, 60 seconds), the one every `part_of` writer takes, so a hand run and the app's own writes serialize. Inside the app the executor holds the same lock itself and the script only checks it.

### The two result sets

The last statements print a summary (`table, action, rows`) and the affected rows (`table, action, id, project, entity, detail, changed`). `changed` is a JSON object `{field: {"from": ..., "to": ...}}`. Actions: `new`, `claimed`, `updated`, `unchanged` (counted, not listed), `kept_local`, `skipped_link` (and `dropped_link` in the list). The app shows the same data on the preview and report pages, filterable by table and action, and `graph_mem:import_sql` prints both tables.

### The record

Inside the same transaction, so a rolled-back or dry run leaves none of it:

- `audit_logs`: one row per new or updated row, in the shape `Auditable` writes (a snapshot for a create, the `{from, to}` fields for an update), actor `sql_import`, reason `sql_import:<operation id>`. They show in System › Audit log and in each entity's history, and the old value of an overwritten field stays recoverable. `kept_local` and `skipped_link` are not audit events.
- `operation_progresses`: one completed `import` row (the existing type) with the counters and `details`: the format, the header fields, the roots, whether it ran outside the app, and the affected rows (capped at 5,000 entries with the full count kept).

## Merge rules

Names compare with the tables' collation (`utf8mb4_general_ci`), as their unique keys do. Observation content compares as the SHA-256 of the text on both sides, so `"abc"` and `"abc "` are two facts.

**Keys.**

| Row | Matched by | New | Matched |
|---|---|---|---|
| Entity | `(scope, name)`: global scope first (Project roots, globals), then members inside their mapped root. Fallback: exactly one same-type entity in that scope whose alias is the incoming name, or whose name is an incoming alias, that no other staged row claims | Inserted with the mapped root as `project_id` and the source timestamps | Aliases are always unioned; `entity_type` and `description` are updated when the incoming row is newer. On an alias match the local name stays and the incoming name becomes an alias |
| Observation | `(entity, SHA-256 of content)`; of several local copies, the active one, then the highest id | Inserted with its status and links | `confidence, source, valid_*, tags, perspective, status, obsoleted_at, obsolescence_reason` and the links, when the incoming row is newer |
| Relation | `(from, to, relation_type)` | Inserted | `weight, confidence, properties` when newer |
| `part_of` | the entity's existing `part_of` row | Inserted | A different parent on a newer incoming edge moves the existing row (an update of `to_entity_id`, not a delete and an insert) |

**Newer wins.** A row that matches by key but differs is updated only when the incoming `updated_at` is later. Otherwise the local row stays and is reported as `kept_local`. A tie (same `updated_at`, different content) is also `kept_local`. `updated_at` is a content timestamp: the derived writers (embeddings, keywords, trust scores, counters, membership backfill) and the Cloud toggle leave it alone, and a spec pins that.

**Nothing is deleted.** Retiring a fact (obsolete or superseded, with its link) and moving a `part_of` parent arrive as updates under the newer-wins rule. A superseded row whose replacement is not in the file is stored as `obsolete`.

**Claiming the global namesake.** A project member with no match in its project takes over a global entity (`project_id` NULL) of the same name and type, as the JSON import does, when that entity has no owned `part_of` parent. Newer wins on its content, the incoming `part_of` attaches it, `project_id` becomes the mapped root, and its owned `part_of` subtree is stamped into the project in the same run. The report lists these rows as `claimed`. A reference stub's park edge (a `part_of` with `reference_stub` in its properties) does not own: it is re-pointed to the incoming parent, not deleted. A namesake is **not** claimed, and a copy is inserted with the reason in the report, when:

- it is a Project, or of another type;
- it has an owned `part_of` parent, or several `part_of` edges;
- it is a reference stub that another project also declares (it stays shared);
- another staged entity matched or would claim it;
- a name in its `part_of` subtree is already taken in the project, or the subtree is not global.

**Dropped `outdated_by` links.** `outdated_by` names the source fact that retired a row. The model takes it only on an inactive row, and only pointing at a source fact of the same project. A link that would fail that (an active row, the row itself, a fact not in the file, or a fact that is not a source fact of the same project once the run has written both) is **dropped, not refused**: the row keeps its status, `obsoleted_at` and reason, and the report lists a `dropped_link` with the reason (no audit row, not counted in the summary).

**Relation types.** In the app, the staged relation types are canonicalized with the target machine's mappings between the staging `INSERT`s and the merge (`SqlExport::Template.relation_type`, which includes the operator's mapping rows). A variant whose canonical twin is staged on the same ends keeps its spelling, and the next relation-type sweep merges it. A [hand run](#hand-runs) skips this step and leaves it to the nightly sweep.

**Cross-boundary links** are made only when the other end already exists on the target machine. An unresolved reference skips that edge and the report lists it (`skipped_link`, with the reason); no stub entity is created. A second `part_of` parent for one entity, an edge into another project and an edge between one entity and itself are skipped the same way.

**Membership.** The script stamps `project_id` itself (new members get their root's id, claimed subtrees are stamped) and checks it before `COMMIT`: a touched entity with two `part_of` parents, a `part_of` cycle, or a member whose project does not match its parent's refuses the import. A `part_of` edge that crosses the export's boundary and would move an entity into another project is skipped (`skipped_link`). Raw SQL skips the model callback that clears cloud access when a Project stops being a root, so the merge never sets `cloud_allowed` or `cloud_root` to anything but off.

**Embeddings.** New and changed rows keep `embedded_at` NULL. A changed `entity_type`, `description` or alias, or a changed observation `source` or `tags`, clears it. The follow-up (or the scheduled backfill) embeds them; nothing embeds inside the import.

**Counters.** `memory_observations_count` is recounted for entities that got new observations.

## Guards

Each guard raises a readable message, rolls everything back and names the field and the row where it can. In the app a refusal shows on the page ("The import was refused and nothing was written: ..."); `graph_mem:import_sql` prints "import refused, nothing was written: ...". See [troubleshooting](troubleshooting.md#problem-an-sql-import-was-refused).

**Before the script runs, the validator** (`SqlImport::Validator`) checks the file, so an uploaded file cannot run SQL of its own:

- a size cap of 50 MB, checked before the file is read (a constant in the validator, not a setting);
- the marker, a known format version, valid UTF-8, no carriage returns (the writer escapes every CR in a string, so a raw one means the line endings were changed), and a header of at most ten lines ending with `sha256`;
- the body's SHA-256 against the header (a changed or cut file fails);
- the fixed part byte for byte against this app's template of that version, the pinned `sql_mode` line included;
- the part between: only `INSERT INTO gm_stage_<known table> (<the template's columns>) VALUES` statements in the writer's exact layout, made of `NULL`, numbers and quoted strings. Executable comments (`/*!`, `/*M!`), comments of any kind outside the fixed sections, a raw quote or line break inside a string and a backslash escape that `connection.quote` doesn't write are refused. This is a whitelist: anything else is "expected ..., found ...", with the line of the data part.

**Structure** (first statements of `02_guards.sql`): the membership lock was obtained; the schema versions (older than the script's, or newer than `max_schema`); every staged member has a staged Project root, and no Project is staged as a member; no key is both an entity and a reference; every observation and relation end is staged; an incoming Project root whose name matches a non-Project entity (a Project on one side, not on the other) is refused with "rename one of them first".

**Values**, since the SQL path skips the models' validations (each message names the field and the staged row):

- a blank name, entity type, content or relation type (blank as Rails reads it, Unicode whitespace included);
- a Project root typed `Project` only under the collation (`project`), because its members' `project_id` must point at a Project;
- an observation status outside `active`, `obsolete`, `superseded` or a perspective outside `world`, `experience`;
- a confidence outside 0..1, a negative weight, a `valid_until` before `valid_from`;
- tags that are not an array of strings, properties that are not an object, and tags or properties that are not JSON at all;
- after the merge, on a new row or a changed field as the model applies it: an observation whose lifecycle columns disagree (status, `obsoleted_at`, supersede links), or an active source fact outside a project.

**Timestamps:** a staged `created_at` or `updated_at` more than a day ahead of the target machine's UTC clock is refused, because it would win every newer-wins comparison until that date. The day allows for clock skew.

**After the merge**, `06_checks.sql` (membership, above, and the lifecycle rules).

A value that passes the validator's grammar but that MariaDB rejects (a number like `1e999`) fails its statement and rolls the run back as well.

## Hand runs

You can run a script with the `mariadb` client:

```bash
mariadb --table <database> < synthprj.sql > import.log
```

The data result is the same, and `import.log` keeps both result tables. The preamble's comment says the same. Rules:

- **Only on a file you exported yourself.** A hand run skips the validator, so it would run whatever the file holds.
- **Never with `--force`.** The client would keep going past a failed statement and commit a partial merge.
- Take a backup first, as for any import.

What a hand run skips, compared with the app:

- the validator (above) and the dry-run preview;
- the relation-type canonicalization: staged types go in as the source machine wrote them, and the next relation-type sweep normalizes them (dream state runs it nightly; `bin/rails graph_mem:canonicalize_relations`);
- the follow-up job: trust scores, keyword paths, "Outdated by a fact", the review rows, the contradiction hook and the compaction start. Embeddings, counters and keywords come later from the garbage collector, the embedding backfill and the nightly keywords job. To get them done at once, press **Run all scheduled jobs now** on System › Background jobs.

The script still stamps and checks membership, runs every guard, and writes the audit rows and an `import` operation row; that row is labelled "graph_mem-sql script run outside the app" in the history. It uses the lock name the app uses, so a hand run and the app's writes serialize.

## Known limits

- **Deletions and merges done on the source machine are not replayed.** A merged-away entity stays on the target machine and is caught as an alias collision (a review row) or by compaction.
- **An entity moved to a different project on the source machine** is inserted in the new project; the old copy stays and is left to compaction and review.
- **A target that hasn't swapped a library yet** (1.96.0). A Project's script carries its swapped library as a global entity. On a target where the library is still `part_of` the Project, the merge doesn't match the member (it matches a global row in the global scope only), so it adds a global copy of the library and of its children next to the member, with `Project depends_on` the copy. Nothing is refused, and membership stays consistent. The target's dream state then queues the member's swap, which is refused (the copy holds the name) and queues the merges: the copy into the member, and each of the copy's children into the member's child of the same name and type. Apply the child merges, then the library merge, then the swap: one global library remains, with one set of children, and identical facts sit twice on it until dream state's dedupe removes them. The clean path is to swap on the target first (run dream state there and apply the swaps), then import. A name of the copy's subtree that an unrelated entity of the project holds still refuses the library merge, naming it: rename one of the two.
- **Observations match on exact content.** When the source machine edits a fact's text, the target machine gets a new row and the old one stays active. The follow-up's near-duplicate check or compaction review catches it.
- **No one-click undo.** An SQL import writes no `ChangeSet`, so System › Activity has nothing to undo; take a backup first. The audit rows hold the old and new value of every updated field, so single fields can be put back by hand.
- **The near-duplicate check needs embeddings.** It reads stored vectors, so it is skipped for facts that could not be embedded (the report says how many) and on an install without vector columns.
- **Format changes.** A migration that touches the three graph tables adds a format version; an older script keeps importing while its version is still in the app and the target schema is within its `max_schema`.
- **No MCP tool.** Export and import are operator and shell features; the three MCP profiles and their tool counts are unchanged.

## The sync endpoint, for scripts

`GET /data_exchange/export?ids[]=<id>[&format=sql]` returns the roots as one graph_mem-sql script, directly (no background job):

| `format` | Response |
|---|---|
| omitted, or `sql` | a graph_mem-sql script (`application/sql`, an attachment named `graph_mem_export_<time>.sql`) |
| `json` | 400: "The JSON export was retired in 1.94.0 …" |
| anything else | 400 |

`ids[]` are entity ids. A request with none answers 422, and so does an unknown id or a member of a project, with the reason (export its Project instead). Authentication is unchanged (the operator sign-in, like the other Data Exchange endpoints).

Before 1.94.0 this endpoint returned the GraphMem JSON tree by default. A script that calls it without `format` now gets the SQL script, so point its reader at the SQL format (or at `graph_mem:import_sql`).
