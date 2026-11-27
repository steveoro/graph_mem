# Plan: Dream State R2, a lifecycle for relations

> Status: draft, 2026-11-27, written on `main` at 1.96.1 (`12f2e7b8`). It answers the questions the
> Dream State plan left for R2 ([`dream-state-semantics-plan.md`](dream-state-semantics-plan.md), "R2").
> Two PRs, released together as **1.97.0**; the vector search plan's steps 2-4 stay 1.98.0. Steve answers
> the questions at the end; the kickoff waits for the answers and, if he agrees (Question 5), for the count
> in "Measure before the kickoff".
> File:line references are to `12f2e7b8`; the kickoff rechecks them.

## Context

A relation has no lifecycle. `memory_relations` has `weight`, `confidence` and `properties`
(`db/structure.sql:316-333`), but no status or dates. A relation that stopped being true can only be
deleted, and in practice it is left alone.

Steve's example, with synthetic names: SynthApp used SynthLib, then replaced it with SynthParser.
R1b turns `SynthLib part_of SynthApp` into `SynthApp depends_on SynthLib` and moves SynthLib to the global
scope. The edge still says SynthApp uses SynthLib. A traversal from SynthApp still brings SynthLib back,
and so does `get_entities` on SynthApp. **R2's goal:** the edge is kept as history ("SynthApp used SynthLib
until 2026-11-27: replaced by SynthParser"), hidden from default reads, shown on request.

R1c already finds the candidates: an informational `relation_review` row when a project fact says a
library the Project still uses was removed, replaced or dropped
(`app/services/compaction_review_applier/relation_review.rb:17-49`). R2 gives that row its apply.

Decisions this plan builds on (Steve, 2026-11-20, in the Dream State plan): retype before delete
(Decision 2); the lifecycle is its own release, with a migration (Decision 3); measure first (Decision 4);
docs follow each release (Decision 5); deleting stays available by hand only.

## Measurements (production, 2026-11-27, counts only)

Taken by the lead on production, which still runs **1.95.0** (the container wasn't rebuilt), so R1b's
swaps and R1c's rows haven't run there yet.

| What | Count |
|---|---|
| Relations / distinct types | 844 / 106 |
| Relations outside the vocabulary | 183 (94 types), all awaiting the operator; 0 accepted |
| Relation deletes since 2026-09-01 | **20** |
| ... by reason | 8 R1a retype moves, 7 duplicate cleanups, 2 legacy-type replacements, 1 smoke cleanup, 1 reparent (these add up to 19 of the 20) |
| ... by actor | operator 13, agents (MCP) 3, no actor 4 |
| ... because the relation stopped being true | **0** |
| Tool calls in 90 days | `search` 415, `get_context` 164, `get_entities` 124, `traverse_graph` 4, `find_shortest_path` 1; `graph_write` 278, `graph_edit` 23, `graph_delete` 8 |
| R1b baseline | 22 dependency-like entities, 21 of them `part_of` a Project root; 26 orphans |

What they say:

- **A delete fixes a wrong edge; nothing ends a true one.** Every classified delete corrected a type, a
  duplicate or a parent, or removed test data. No edge was removed because it stopped being true: outdated edges simply stay.
  So `delete_relation` keeps its meaning (a wrong edge), and ending needs its own operation.
- **Agents read relations through `get_entities` and `search`, rarely by traversal.** Every one of the 124
  `get_entities` calls returns a relation projection (`entities_fetch_service.rb:43`); `traverse_graph` and `find_shortest_path` ran 5 times in 90 days.
  Hiding ended edges matters most in `get_entities`, `search`'s ranking and the MCP Apps view.
- **Agents rarely delete** (`graph_delete` 8 calls, 3 relation deletes). An ending operation will be
  used rarely too, so its MCP cost must stay small: no new tool.
- **R2's main input isn't measured yet.** R1c's rows exist only from 1.96.0 on. See "Measure before the
  kickoff".

## 1. Schema

**Migration** (`AddLifecycleToMemoryRelations`), on `memory_relations` only:

| Column | Type | Notes |
|---|---|---|
| `status` | `varchar(16) NOT NULL DEFAULT 'active'` | `active` or `ended`, like observations' `status` (`db/structure.sql:265`) |
| `ended_at` | `datetime(6) NULL` | when graph_mem learned it ended (system time), like `obsoleted_at` (`:266`) |
| `ended_reason` | `varchar(255) NULL` | like `obsolescence_reason` (`:267`) |

- **Every existing row becomes `active`** through the default. The table is small (844 rows).
- **`valid_from` / `valid_until`: not in R2** (Question 8). Nothing reads a validity window on relations:
  temporal recall reads observations only (`docs/mcp_tools.md`, "Temporal recall"). `ended_at` and
  `ended_reason` say "used until". A column with no reader is cost without use.
- **The unique key stays** `index_memory_relations_uniqueness (from_entity_id, to_entity_id,
  relation_type)` (`db/structure.sql:327`). It covers ended rows, so a triple has one row, active or
  ended. Re-adding an ended edge reactivates that row (Question 2; item 5). History lives in the audit rows.
- **No new index.** Ended rows are expected to be a few percent of 844. The readers that will hide them
  already narrow by `from_entity_id`, `to_entity_id` or `relation_type` (`db/structure.sql:327-330`), and
  the status filter runs on those rows (a `traverse_graph` with no filter lists every edge, a full scan
  today). The kickoff checks the plans with `EXPLAIN` on a synthetic graph of 10,000
  relations, 5% ended. A reader that falls back to a full scan gets `(from_entity_id, status)` or
  `(to_entity_id, status)`, and the PR says which.
- **No DB CHECK constraint**, as for observations: the model validates, and the SQL import's guards check
  raw rows (item 8).
- **`db/structure.sql` keeps its `vector(768)` lines.** The migration doesn't touch them, but a dump from
  a MariaDB older than 11.8, or from a database without `embeddings:add_indexes`, would drop them.
  `StructureDumpGuard` (`app/lib/structure_dump_guard.rb`, hooked in `lib/tasks/structure_dump.rake:11-14`)
  catches the second case. After `db:migrate`, `git diff db/structure.sql` must show only the
  `memory_relations` hunk and the new `schema_migrations` row. The two `vector(768)` columns
  (`db/structure.sql:219`, `:259`), the two `VECTOR KEY`s (`:231`, `:292`) and the `@OLD_NOTE_VERBOSITY`
  pragma (`:12`) stay as they are.

## 2. The model and one lifecycle service

- **`MemoryRelation`** (`app/models/memory_relation.rb`) gains `ACTIVE_STATUS`, `ENDED_STATUS`,
  `STATUSES`, scopes `active` and `ended`, and validations: `status` in `STATUSES`; `ended_at` present
  exactly when ended; `ended_reason` at most 255 characters; **an ended relation is never `part_of`**
  (item 3). No `default_scope`: a default scope would hide an ended twin from the unique-key checks, the
  merges and the deletes, which then fail on the key or leave rows behind.
- **JSON:** `serializable_hash` leaves the three columns out of an active row, so `as_json` (the REST API,
  the MCP resources) follows the rule the MCP payloads follow (item 6): an active relation's JSON is as
  before, an ended one carries `status`, `ended_at` and `ended_reason`.
- **The trust-score hook** runs on create and destroy only (`memory_relation.rb:11`). Since ended edges
  stop counting in the structural boost (item 4), it also runs on an update that changes `status`.
- **`RelationLifecycle`** (`app/services/relation_lifecycle.rb`), the one writer of the three columns:
  - `end!(relation, reason:)`: sets `ended`, `ended_at` now, the reason. Refuses a `part_of`, a blank
    reason and an ended relation (it answers "already ended" with nothing written).
  - `reactivate!(relation)`: sets `active` and clears both columns. Returns the end it undid
    (`ended_at`, `ended_reason`), for the caller's answer.
  - Both are ordinary audited updates (`Auditable`, `app/models/concerns/auditable.rb:20-27`), so the
    audit row holds the old and the new values, and both bump `updated_at` (the SQL exchange's newer-wins
    reads it, item 8). Neither takes the membership lock: no `part_of` is involved.
  - Callers: `graph_delete` `end_relation`, `graph_write` and the other explicit writers (item 5), the
    REST API, the entity panel, and the `relation_review` apply (item 7).

## 3. Membership: a `part_of` is never ended

**Recommendation (Question 1):** a relation whose stored type reads as `part_of`, or whose canonical type
is `part_of`, can't be ended. `RelationLifecycle.end!` refuses it, the model validation refuses any write
that would leave one (a retype of an ended row into `part_of` through REST `PATCH`, the data-exchange
retype or a review apply), and the SQL import's guards refuse a staged one.

Why:

- A `part_of` decides an entity's project (`ProjectMembership.sync!`,
  `app/services/project_membership.rb:151-156`). With no ended `part_of` in the graph, every `part_of`
  reader stays as it is: membership and `member_ids` (`:216-231`), `ProjectSubtree` (`project_subtree.rb:18-45`,
  `:47-63`), the single-parent and cycle checks (`relation_semantics.rb:39-58`, `:66-83`), the orphan rule
  (`orphan_matching_strategy.rb:41-47`), the backfill and its drift report (`project_id_backfill.rb:137-140`,
  `:162`, `:247`, `:258`) and the SQL import's checks (`lib/graph_mem/sql_exchange/v1/06_checks.sql`). About
  15 readers would otherwise learn the status, each a chance of drift.
- The `part_of` that R1c reads is a library's (`removal_evidence.rb:48-56`: a `part_of` into a Project root
  only from a dependency-like entity). R1b says such an edge is a `depends_on` in the wrong shape. So the
  `relation_review` apply on it **swaps and ends** (item 7): `SynthLib part_of SynthApp` becomes `SynthApp
  depends_on SynthLib`, ended, and SynthLib turns global. One decision, one change set, one undo.
- A component that leaves a project is a move or a delete, which the graph already does under the lock.

Without it (Question 1, option 3): an ended `part_of` stops counting, `project_id` follows on the end (a
membership move under the lock, `ProjectMembership.reassign!`, refused on a `Collision`), undo restores it
through `ChangeSetUndo::AuditInverse#sync_memberships` (`audit_inverse.rb:166-173`) once `note_touched`
(`:157-164`) reads the status, and every reader above gets `.active`.

## 4. Every reader of relations

The rule: **an ended edge is history.** A reader that answers "what is connected now" (traversal, paths,
relation projections, ranking, detection pools, evidence) reads `active` edges. A reader that answers
"does this row exist" or "were these two ever related" (unique-key and duplicate checks, merges, deletes,
integrity, exports, the orphan rule, fact relatedness) reads every edge.

Legend: **Hidden** (active only by default; "on request" names the parameter), **Always hidden**, **All**
(every row; no code change unless noted), **`part_of` only** (unaffected: item 3).

### MCP tools, resources and the MCP Apps view

| Reader | Where | Ended edges |
|---|---|---|
| `traverse_graph`, expansion | `GraphTraversalService#frontier_edges` / `#relations_scope` (`graph_traversal_service.rb:137-159`), tool `traverse_graph_tool.rb:55-61` | Hidden; on request with `include_ended`, which also walks through them |
| `traverse_graph`, relation query | `RelationQueryService#relation_scope` (`relation_query_service.rb:32-40`), tool `:87-109` | Hidden; on request with `include_ended` |
| `find_shortest_path` | `GraphTraversalService#shortest_path` (`:94-133`), tool `find_shortest_path_tool.rb:38-44` | Always hidden: a path through history isn't a connection |
| `get_entities`, relation projection | `EntitiesFetchService#relation_payloads` (`entities_fetch_service.rb:106-116`), tool `get_entities_tool.rb:46-57` | Hidden; on request with `include_ended` |
| `search`, subgraph mode | `SubgraphSearchService#relations_for` (`subgraph_search_service.rb:280-285`) | Always hidden (Question 4, option 2 would add `include_ended`) |
| `summarize`, `max_depth` | `SummarizerService#expand_entities` (`summarizer_service.rb:151-170`) through `GraphTraversalService` | Always hidden (the service's default) |
| `get_context` | `GraphMemContext#scoped_entity_scope` (`graph_mem_context.rb:103-113`) reads `project_id` | Unaffected (membership doesn't change, item 3) |
| `get_graph_stats` | totals `get_graph_stats_tool.rb:49-54`, `orphan_count` `:61-68`, degrees `:91-96` | All; `totals` gains `ended_relations`. `relations` keeps counting every row, as `observations` counts obsolete ones |
| Relation payload | `GraphTraversalSerializer.relation_json` (`graph_traversal_serializer.rb:98-110`) | An ended relation adds `status`, `ended_at`, `ended_reason`; an active one is unchanged |
| Resources | `memory_graph_resource.rb:24-28`, `:94`; `memory_entity_resource.rb:265-266`; `memory_relation_resource.rb:24` | Hidden; no new template parameter. Their payloads are `as_json` (`memory_relation_resource.rb:100`, `memory_graph_resource.rb:53`, `:69`), unchanged for active rows (item 2) |
| MCP Apps view | `adapter.js:30-37` (`relationSummary`); its own calls `loader.js:20`, `:39`, `interaction.js:78`, `:107`, `:124` | Draws what a tool result holds. Its own calls never pass `include_ended`. `relationSummary` keeps `status`, and an ended edge is drawn dashed |
| Maintenance review tools | item 7 | |

### REST API (`app/controllers/api/v1`)

| Reader | Where | Ended edges |
|---|---|---|
| `GET /memory_relations` | `memory_relations_controller.rb:9-19` | All (an ended row carries the three columns, item 2); a `status` filter (`active`, `ended`) |
| `GET /memory_relations/:id`, `PATCH` | `:62-94` | All; a `PATCH` of `status` goes through `RelationLifecycle` |
| `POST /memory_relations`, `POST /bulk` | `memory_relations_controller.rb:28`, `bulk_controller.rb:67-68` | Explicit writers: reactivate (item 5) |
| `GET /memory_entities/:id` | `memory_entities_controller.rb:63-84`, `:216` | All; its hand-built `relations_from` / `relations_to` hashes gain the three keys on an ended row |
| Search subgraph, `subgraph_by_ids` | `search_controller.rb:67`, `:91` | Hidden; `include_ended` on `subgraph_by_ids`, as `get_entities` |
| Traverse, shortest path | `graph_traversal_controller.rb:11-47` | As the MCP tools (`include_ended` on traverse) |
| Stats | `maintenance_controller.rb:55`, `:62-63`, `:93-94` | As `get_graph_stats` |
| Explore's graph data | `graph_data_controller.rb:109` (neighbours), `:130` (edges drawn); `:86` is `part_of` only | Hidden; `include_ended=1` from Explore's toggle |

Swagger (`swagger/v1/swagger.yaml`) is regenerated with the new parameters and fields.

### Operator UI

| Reader | Where | Ended edges |
|---|---|---|
| Explore canvas | the graph data above | Hidden; a **Show ended relations** toggle draws them dashed |
| Entity panel | `EntityPanel#relations`, `#relation_counts` (`entity_panel.rb:83-96`), `app/views/entities/_relations.html.haml` | All: ended ones under their own heading with date and reason; **End…** on an active row, **Reactivate** on an ended one (operator only) |
| Explore's add relation | `explore_edits/relations.rb:18` | Explicit writer: reactivates |
| Type suggestions | `explore_controller.rb:18`, `explore/relations_controller.rb:37` | All |
| Explore's move card | `explore_move_card.rb:24` | `part_of` only |
| Search page counts | `GraphSearch::Page#relation_counts` (`graph_search/page.rb:187-190`) | Hidden |
| Review cards | `review/kinds/_relation_review.html.haml:6`, `_relation_retype.html.haml:8`, `_relation_retype_dependency.html.haml:18`, `_delete_relation.html.haml:1` | All (by id); an ended relation is labelled "(ended)" |
| Data exchange page | `data_exchange_controller.rb:84-87` (`part_of`), `:234-241` (retype; the model refuses an ended row into `part_of`), `:275`, `:316` (by id), `:370-377` (reverse duplicates) | All |
| System dashboard | `maintenance_dashboard_snapshot.rb:110`, `:145-146` | As `get_graph_stats` |

### SQL exchange

| Reader | Where | Ended edges |
|---|---|---|
| A Project's members | `SqlExport::Scope` (`sql_export/scope.rb:79`) | `part_of` only |
| The `depends_on` hop | `scope.rb:90` | All: an ended `depends_on` carries its library as rows too, so the history travels with the project |
| The relations | `scope.rb:139` | All; status travels (item 8) |
| The export picker's roots | `sql_export/roots.rb:27` | `part_of` only |
| The merge | `lib/graph_mem/sql_exchange/v1/05_relations.sql:12-14`, `:38-57` | item 8 |
| The follow-up's touched ids | `sql_import/touched.rb:45` | All |

### Project scans and the import engines

Unattended writers **never reactivate** an ended edge and never add a twin: an end is a decision, and a
scan's model or an import file can repeat an old statement (item 5).

| Reader | Where | Ended edges |
|---|---|---|
| Reconcile: relation exists | `project_scanner.rb:593-599` | All; never reactivates |
| Two names related | `project_scanner.rb:730-731` | All |
| A project's global libraries | `ProjectScanner::GlobalDependencies.entity_ids` (`global_dependencies.rb:44`) | All: the project's validation keeps covering the facts its scans wrote on a library it used |
| Link a global library | `global_dependencies.rb:69` | All; never reactivates |
| Link two Project roots | `project_links.rb:85-86` | All |
| Code-map edges | `skeleton_writer.rb:181` | All; never reactivates |
| Code-map gone edges | `skeleton_writer.rb:209-221` | Hidden: no `delete_relation` review row for an ended edge |
| Containment and skeleton parents | `containment.rb:33`, `skeleton_writer.rb:139`, `membership_sync.rb:32`, `project_scan_skill.rb:414` | `part_of` only |
| Scan validation | `ProjectScanValidator#validate_entity_relations` (`project_scan_validator.rb:363-385`) | Hidden: it skips ended edges (no `delete_relation` row; its `part_of` branch can't meet one) |
| Graphify import | `graphify_importer/matching.rb:30`; `:138`, `:190`, `:232` are `part_of` | All; never reactivates |
| Graphify rescan | gone edges `graphify_rescan.rb:159-165`; `:200`, `:349` are `part_of`; `:343` by id | Gone edges: hidden (no row for an ended edge) |
| JSON import engine (`graphify:import`, `rails_ast:import`) | `import_execution_strategy/relations.rb:219-222`, `:245-252`, `:330`; `claims.rb:32` (`part_of`); `import_matching_strategy.rb:323-330`; `import_entity_resolver.rb:138-142` | All; never reactivates |

### Dream state and the other jobs

| Reader | Where | Ended edges |
|---|---|---|
| `relation_types` sweep | `relation_type_sweep.rb:117`, `:126`, `:200`, `:295`, `:321`, `:335` | All: ended rows are canonicalized too. An ended variant whose canonical type is `part_of` is never queued (new count `skipped_ended`). A merge into a twin keeps the twin active when either row is active, and an ended variant's end goes into `merged_from` |
| `dependency_edges`, swap pass | `dependency_edges_phase.rb:68` | `part_of` only |
| The swap's apply | `relation_retype_dependency.rb:125`, `:186` | All: an ended `SynthApp depends_on SynthLib` is kept ended (the end was a decision) |
| The `add` apply | `relation_retype_dependency.rb:255` | All |
| `dependency_edges`, removal pass | `RemovalEvidence.edges` (`removal_evidence.rb:48-56`) | Hidden: no new row on an ended edge |
| `orphans` | `OrphanMatchingStrategy.orphan?` and `#orphan_nodes` (`orphan_matching_strategy.rb:41-47`, `:52`, `:57-70`) | All, no change: an ended `Project depends_on` still keeps its target from being an orphan. Otherwise the target would be an orphan again: phase 1 would queue an `add` row for it, or parent a target that isn't dependency-like back into the project by name (R1b's loop) |
| `tree_walk` | `compaction_traversal.rb:50` | `part_of` only |
| Auto-merge, and every merge | `NodeOperationsStrategy` (`node_operations_strategy.rb:305-307`, `:355-395`, `:403-428`, `:445`) | All. The target keeps its own twin with its status (the merge rule). `EntityMergePreview` (`entity_merge_preview.rb:104-111`) warns when an active edge of the source is dropped for an ended twin |
| `relationship_discovery` | `relationship_discovery_strategy.rb:199-205`; scope `dream_state_compactor.rb:185-186` (`part_of`) | All: an ended edge is never proposed back |
| Integrity sweep | `graph_integrity_service.rb:76-77` | All |
| Relation repair | `relation_integrity_repairer.rb:114`, `:138-160`, `:170-202`, `:252` | All; a reverse pair with one ended edge keeps the active one (today the lower id, `:151`) |
| Garbage collection | `garbage_collection_runner.rb:37-42`, `:154-160` | All: an ended edge keeps its node out of the orphan report, which is the history Steve wants kept |
| Stale scan, "addressed" | `stale_memory_scanner.rb:89-94`, `:246` | Hidden: an ended `solves` no longer says the issue is addressed |
| Contradiction neighbours | `contradiction_detector.rb:233-237` | Hidden |
| Progress totals | `compaction_runner.rb:132`, `relation_type_sweep_job.rb:34` | All |
| Unmapped types page | `unmapped_relation_types.rb:68`, `:83-86` | All |

### Membership, merge, delete and undo

| Reader | Where | Ended edges |
|---|---|---|
| `ProjectMembership`, `ProjectSubtree`, `RelationSemantics`, `ProjectIdBackfill` | listed in item 3 | `part_of` only |
| Entity delete | `relation_membership_write/entity_delete.rb:94`, `:105` | `part_of` only; the entity's other edges, ended ones too, go with it (`dependent: :destroy`, `memory_entity.rb:18-19`) |
| Merge snapshot | `entity_merge_snapshot.rb:19`, `:35` | All |
| Undo | `change_set_undo/audit_inverse.rb:136-149`, `change_set_undo/merge.rb:110-144` | All |
| `graph_delete` `delete_relation` | `graph_delete_service.rb:250-259` | All: deleting an ended edge stays allowed |

### Search ranking and relevance

| Reader | Where | Ended edges |
|---|---|---|
| Structural boost, hybrid search | `HybridSearchStrategy#apply_structural_boost` (`hybrid_search_strategy.rb:233-243`) | Hidden |
| Structural boost, subgraph | `SearchRelevanceBooster.apply_structural_boost` (`search_relevance_booster.rb:82-91`) | Hidden |
| Trust score's structural boost | `observation_trust_ranker.rb:60-67` | Hidden (and recomputed on an end, item 2) |
| Review priority by degree | `review_row_classifier.rb:187` | Hidden |
| Merge direction weight | `entity_merge_evidence.rb:130` | All |
| Fact relatedness | `fact_keywords/relatedness.rb:215-220`, `fact_supersede/candidates.rb:114-120`, `compaction_review_applier/fact_supersede.rb:135-142` | All: an ended edge still says the two subjects are related |
| Context boost | `graph_mem_context.rb:103-113` | Unaffected (`project_id`) |

### Review rows, rake tasks and tools

- **Review appliers and policies, by relation id or existence:** `compaction_review_applier.rb:200`, `:224`;
  `preview.rb:40`, `:55`, `:74`, `:95`, `:116`, `:180-187`; `relation_retype.rb:43`, `:63`, `:94`;
  `relation_retype_choice.rb:35`, `:94`, `:103`, `:148`; `review_row_classifier/anchors.rb:99`;
  `review_policies/dangling_check.rb:27`, `:34`, `:50`, `:59`, `:75`, `:85`, `:90`, `:116-118`;
  `review_policies/auto_apply_relation_retype.rb:78`; `compaction_review_service/queries.rb:79` (`part_of`). All.
  A `retype` row whose variant is ended is refused on apply ("the relation is ended") and dismissed by
  the Dangling policy. `DanglingCheck#relation_review_reason` (`dangling_check.rb:105-111`) also dismisses a
  row whose relation is ended.
- **Rake tasks:** `memory_graph_utilities.rake:36-37`, `:209-233` (All; an ended edge is printed with
  "(ended …)"), `memory_data.rake:310` (All; never reactivates), `:552` (All).
- **Scan profiling:** `lib/graph_mem/scan_profile/metrics.rb:33`, `graph_snapshot.rb:23`. All.

## 5. Writers: ending and reactivating

- **Ending:** only `RelationLifecycle.end!`, from `graph_delete` `end_relation` (item 6), REST `PATCH`, the
  entity panel's **End…**, and the `relation_review` apply (item 7). Nothing ends an edge unattended.
- **Re-adding an ended edge (Question 2): an explicit writer reactivates it.** `graph_write`
  `create_relation` (`graph_write_service.rb:335` today refuses any existing triple), its duplicate
  check (`graph_write_service/duplicates.rb:148-152`, which must not call an ended twin a duplicate), REST
  `POST /memory_relations` and `/bulk`, Explore's add relation and `tools:create_relation` (through
  `GraphWriteService.execute_one`). The row comes back `active`; the audit row keeps the end; the answer
  says so (item 6). Why: one row per edge, so nothing else changes in the unique-key readers, and an agent
  that learns the project uses SynthLib again needs no other operation.
- **Unattended writers never reactivate** (scans, the JSON import engine, Graphify, dream state's `add` and
  swap, discovery, the sweep). They see the ended row and skip, as for an active one. The SQL import is the
  exception by design: it carries the source's status under newer-wins (item 8).
- **`delete_relation` stays a hard delete**, for a wrong edge. Its description says to end a relation that
  was true and no longer is.

## 6. The MCP surface

- **Ending, over MCP (Question 3): a `graph_delete` operation `end_relation`** (`relation_id`, `reason`,
  both required). `graph_delete` already holds the soft lifecycle operation for facts:
  `delete_observation` marks an observation obsolete (`graph_delete_tool.rb:21`), and `graph_edit`'s
  description sends obsoleting there ("Do not use to obsolete, delete, or merge data", `graph_edit_tool.rb:26`).
  `GraphDeleteService::TYPES` (`graph_delete_service.rb:4`) gains it; the batch's `summary` gains
  `relations_ended`. A `part_of` is refused as a validation error with a `next_move` (re-parent with
  `delete_relation` and `create_relation part_of`, as `skills/graph-mem-mcp-toolset/SKILL.md:89` already
  says, or apply the library's review row). An ended relation answers "already ended" with nothing written.
- **Showing ended edges (Question 4): `include_ended` (boolean, default false) on `traverse_graph` and
  `get_entities`.** The name follows `include_obsolete` (`get_entities_tool.rb:31`). With it, ended edges
  are returned and walked; without it, they are left out and the rest of the response is as before. `search`,
  `find_shortest_path`, `summarize` and the resources take no parameter.
- **Payload keys:** an ended relation carries `status: "ended"`, `ended_at` and `ended_reason`; an active one
  carries none of them, so a response with no ended relation doesn't change by a byte. `GraphTraversalSerializer.relation_json`
  is the one place (`graph_traversal_serializer.rb:98-110`).
- **Reactivation's answer:** `graph_write`'s relation result adds `reactivated: { ended_at, ended_reason }`
  (the end it undid) and its `summary` adds `relations_reactivated`, so an agent repeating a stale fact sees
  what it reversed.
- **`relation_review` over MCP:** `apply_maintenance_review` applies it (item 7); its `dry_run` preview
  says what ends. The R1c validation error and its `next_move` (`relation_review.rb:19-21`,
  `apply_maintenance_review_tool.rb:82`) go.
- **Schemas and snapshots:** two input schemas gain `include_ended`; `graph_delete`'s description and its
  `operations` description name `end_relation`; the `relation` output definition
  (`lib/graph_mem/mcp_output_schemas.rb:35-44`, `additionalProperties: true`) documents the three optional
  keys. The `tools/list` snapshots of all three profiles (`spec/fixtures/mcp/snapshots/*.json`,
  `spec/mcp/tools_list_snapshot_spec.rb`) are re-recorded, and the PR says so. Resource templates don't change.
- **Tool counts stay 12 / 9 / 22.** No new tool; the default `/mcp` budget stays 12. The added text is two
  optional parameters and one operation name.
- **Agent text:** `skills/graph-mem-mcp-toolset/references/tools.md` gets one line ("a relation that stopped
  being true: `graph_delete` `end_relation` with a reason; `delete_relation` only for a wrong edge"), within
  `agent_text_sync_spec`'s limits. The `persist` prompt and the server instructions don't change.

### MCP-visible changes, for Steve's approval

All in one place; each needs Steve's explicit yes (R1b's were approved in #204's review, the same way):

1. `traverse_graph` and `get_entities` hide ended relations by default (an output change for any graph
   that has one).
2. `include_ended` on `traverse_graph` and `get_entities` (Question 4).
3. Three keys on an ended relation's payload: `status`, `ended_at`, `ended_reason`.
4. `find_shortest_path`, `search` (subgraph relations and ranking), `summarize` and the three resources hide
   ended relations, with no parameter.
5. `graph_delete` `end_relation`, its `relations_ended` count, and the description change (Question 3).
6. `graph_write` reactivates an ended twin instead of answering `possible_duplicate`; its result's
   `reactivated` and `relations_reactivated` (Question 2).
7. `apply_maintenance_review` applies `relation_review` rows; the R1c refusal goes (item 7).
8. `get_graph_stats`' `totals.ended_relations`.
9. The `tools/list` snapshots, re-recorded for 2, 5 and the documented output keys.
10. The skill reference line (agent text, not served over MCP while Skills over MCP is off).

## 7. The `relation_review` apply

- **`depends_on` edge** (a Project root's, `removal_evidence.rb:51`): `RelationLifecycle.end!` with the reason
  `removal fact #<id> on '<entity>': <excerpt>`, cut to 255 characters. No membership lock.
- **`part_of` edge** (a dependency-like library not swapped yet, `removal_evidence.rb:52-55`): swap and end in
  one savepoint under the membership lock, reusing R1b's swap (`CompactionReviewApplier::RelationRetypeDependency`):
  the `part_of` goes, `SynthApp depends_on SynthLib` is created ended, SynthLib and its own `part_of`
  children turn global. The swap's refusals hold (a global namesake queues its merges, a taken child name
  is named), with nothing written.
- **Re-checks on apply:** the fact is still active and the edge still active and of its type. A row whose
  edge was ended already succeeds with nothing written; a gone edge is an error asking to dismiss it, like a
  stale `relation_retype` row.
- **Applied one by one, never unattended (Question 6):** `relation_review` leaves
  `ReviewRowClassifier::INFORMATIONAL_KINDS` (`review_row_classifier.rb:28`) for `DESTRUCTIVE_KINDS`
  (`:22-23`: "applied one by one only: never bulk-, group- or policy-applied"). No policy. Why: the rows are
  noisy by design (a fact that names SynthLib as the replacement is queued too, `docs/dream_state.md`,
  phase 2), and none has run in production. A policy can follow a measured approval rate (Decision 4).
- **Other rows on the same edge** (up to three per relation and run) are dismissed by the Dangling policy
  once the edge is ended. The removal pass queues no new row on it (item 4).
- **Review card:** `_relation_review.html.haml` gets **End the relation…** (preview, then confirm) next to
  Dismiss and Snooze, with captions under `ui.review.actions.relation_review.*`
  (`spec/requests/review_action_captions_spec.rb` covers every button). The preview says what ends, and for a
  `part_of`, the scope effect R1b's card already words ("SynthLib and its 2 children leave SynthApp's
  scope"). `CompactionReviewService.apply` (`compaction_review_service.rb:55-56`) and
  `ReviewGroupActions` (`review_group_actions.rb:88`) drop their informational branches.
- **Undo** is the audit undo (item 9).

## 8. The SQL exchange: format v2

The migration touches `memory_relations`, so `spec/services/sql_export/template_spec.rb:10-16` fails until a
format version supports it: **graph_mem-sql v2**.

- **`lib/graph_mem/sql_exchange/v2/`**, a copy of `v1/` with these changes:
  - `01_preamble`: `gm_stage_relations` gains `status`, `ended_at`, `ended_reason`, each `DEFAULT NULL`;
  - `02_guards`: value guards (status `active` or `ended`; `ended_at` present exactly when ended, and no more
    than a day ahead, like the timestamp guard; no ended row whose type reads as `part_of`);
  - `05_relations`: the changed-fields JSON and the newer-wins update (`v1/05_relations.sql:38-50`) cover the
    three columns; the insert (`:52-54`) carries them; a NULL staged status means "not carried": insert
    `active`, never update a local status;
  - `06_checks`: no ended `part_of` after the merge (backstop);
  - `07_record`: the audit rows carry the new fields as any changed field.
- **`SqlExport::Template`:** `MAX_SCHEMA` (`template.rb:21`) becomes `{ 1 => "20261124120000", 2 => <the R2
  migration> }`. `COLUMNS` (`:28-36`) is one constant today and becomes per version, since the validator
  checks a v1 file's column lists against v1's.
- **Ended relations travel like any other** (`scope.rb:139`). The merge rules stay: match on `(from, to,
  type)`; **newer `updated_at` wins** on `weight, confidence, properties, status, ended_at, ended_reason`; a
  tie is kept local; **nothing is deleted**. So a newer end on the source ends the target's edge, a newer
  reactivation reactivates it, and an older one is `kept_local`.
- **v1 scripts on a 1.97 target (Question 7).** Today a v1 script is refused by its own guard once the
  target's schema is past v1's `max_schema` (`v1/02_guards.sql:22-23`). Recommendation: the app reads a v1
  file through v2. `SqlImport::Validator` still checks it as v1 (`validator.rb:83`, `:100-108`); the executor
  then runs v2's fixed sections with the file's data statements, whose column lists are a subset of v2's. v1
  carries no status, so new edges are active and a local ended edge stays ended. A hand run of a v1 file on
  1.97 is still refused by its own guard, which `data_exchange.md` says. A v2 script on a 1.96 target is
  refused by the validator ("v2 is not known"): upgrade the target first.
- **Found on the way:** `{{max_schema}}` is rendered into `02_guards.sql` (`:22-23`), and the validator
  compares the fixed part byte for byte (`validator.rb:100-106`). Moving a version's `max_schema`, which
  `data_exchange.md` prescribes for any non-graph migration, therefore makes every script exported before
  the move fail validation. R2 never moves v1's (frozen at `20261124120000`), but the next non-graph
  migration would hit v2. Not R2's to fix; a later patch can render the guard from the script's own header,
  or freeze `max_schema` per file. Steve decides when.
- **Docs:** `docs/data_exchange.md` (format v2, the staging columns, the merge rule, v1 reading).

## 9. Undo and audit

- Ending and reactivating are audited updates (item 2) inside a change set: `graph.delete` for
  `end_relation` (`graph_delete_service.rb:71`), `graph.write` for a reactivation
  (`graph_write_service.rb:80`), the review apply's, and the entity panel's.
- The generic audit undo inverts an update (`change_set_undo/audit_inverse.rb:4-6`), so **Undo** on System ›
  Activity reactivates an ended edge, or ends a reactivated one again. Its later-change check (`:36-55`)
  refuses an undo when the edge changed since, as for any row.
- The swap-and-end apply is one change set: undo deletes the ended `depends_on`, re-inserts the `part_of`
  with its id and syncs membership back (`:166-173`), as R1b's swap undo does.
- Over MCP there is no undo (no tool), as today; an agent reactivates with `graph_write`.

## 10. PR 1's cleanups (Steve, 2026-11-27)

1. **Move the first-run setup plan to `done/`.** `git mv docs/plans/first-run-setup-plan.md docs/plans/done/`;
   a status line `**✅ DONE:** shipped as 1.95.0 (#207, for issue #206)` under its title, as
   `done/sql-exchange-plan.md:3` has; a row in `docs/plans/done/README.md` after `sql-exchange-plan.md`
   ("First-run setup: a fresh clone boots without a shared master key or a hand-made `database.yml`" |
   1.95.0); and the link in `docs/plans/mariadb-vector-search-plan.md:451` points to `done/`.
2. **`spec/system/navigation_spec.rb:54`, locally flaky** (the sign-in toast; "Unable to find field
   username" in the `before` block's `sign_in_through_form`, `spec/support/system.rb:28-34`).
   - *The likely cause:* the login page redirects a signed-in browser to Home
     (`Operator::SessionsController#new`, `sessions_controller.rb:18-19`), so the form is never there when a
     previous example's session cookie survived its teardown. Locally, Capybara 3.40.0's
     `ChromeDriver#reset!` (`capybara-3.40.0/lib/capybara/selenium/driver_specializations/chrome_driver.rb:36-55`)
     ends with `Storage.clearDataForOrigin` on `"*"`, which Chrome 158 rejects. The wrapper
     (`spec/support/system.rb:43-53`) clears the cookies only for that exact message. Any other failure in
     the reset (its 10-second `wait_for_empty_page`, a changed message in a newer Chrome) skips both clears.
     CI's Chrome 156 accepts `"*"`, which fits "green in CI". Random order (`spec/spec_helper.rb:86`) makes it
     flaky rather than constant.
   - *Not reproduced in this session:* the plan was written with the docs specs only. The kickoff reproduces
     it first (the failing seed, then `--bisect`) and checks the failure screenshot: Home means the
     redirect, an empty login page means a slow first render.
   - *The fix:* `sign_in_through_form` stops depending on the previous teardown. It clears the browser's
     cookies before the visit (`page.driver.browser.manage.delete_all_cookies`), then waits for the form
     with a message naming the page it found:
     `expect(page).to have_css("[data-testid='operator-login-form']", wait: 10)`. That covers both readings.
3. **`spec/system/mcp_apps_graph_view_spec.rb:222`, locally flaky** (label overlap, "root entities with one
   relation between two of them").
   - *The cause, from the code:* the view adds nodes with no position (`adapter.js:125-127`), so every node
     starts at (0, 0). The connected pair runs Explore's `cose` layout with `randomize: false`
     (`app/javascript/graph/cytoscape_config.js:82-105`, used at `graph_view.js:66`). When two nodes coincide,
     cose's repulsion picks a random direction (`Math.random`, in the vendored
     `cytoscape.esm.min.mjs`, function `Iu`). The layout doesn't count labels (`nodeDimensionsIncludeLabels`
     is unset, so false), and the spec's labels are about 30 characters against an ideal edge length of 100.
     When the pair lands side by side, their labels overlap; one above the other, they don't. That is a
     real overlap in some runs, not a timing artifact, which also explains a green CI run by chance.
   - *The fix:* `graph_view.js:66` passes `nodeDimensionsIncludeLabels: true` to the connected part's
     layout, in the view only (Explore's options stay as they are). The spec then runs the example a few
     times in a loop at the kickoff to confirm.
4. **The "Outdated by a fact" group card shows `#—`.**
   - *What the header does:* `group.anchor_name || "##{group.anchor_id || '—'}"`
     (`app/views/review/_group_card.html.haml:10`, also `app/views/home/_digest.html.haml:22`). `#—` means the
     group's `MAX(anchor_entity_id)` is NULL (`review_digest.rb:83-93`). A gone entity would show `#<id>`.
   - *Where the anchor comes from:* for `fact_supersede`, the classifier takes the payload's `entity_id`
     (`review_row_classifier/anchors.rb:27`). `FactSupersede::Proposals.item` always writes it
     (`fact_supersede/proposals.rb:75`); both producers (`FactSupersedeJob` and the contradiction fallback,
     `contradiction_fallback.rb:80`) seed through `CompactionReviewService.seed_report`, which classifies
     every row (`compaction_review_service.rb:167-184`). No path was found that seeds one without the anchor.
     A row created directly, as some specs do (`spec/system/navigation_spec.rb:86-88`), has none.
     `ReviewRowClassifier.backfill!` re-classifies only rows with no `group_key` (`backfill.rb:51`), so such
     a row is never repaired.
   - *Cause not confirmed.* The kickoff asks where it was seen, and on that database runs a counts-only
     query: active `fact_supersede` rows with a NULL `anchor_entity_id`, and how many of them have a payload
     `entity_id`.
   - *The fix either way:* the header falls back to the payload's names when the anchor is NULL
     (`fact_entity_name` for a `fact_supersede` group, else `entity_name` or `from_name`), through one helper
     the card and Home's digest share; and the backfill also re-classifies active rows whose anchor is NULL
     while their payload names one. A spec seeds such a row and checks the header.

## Order, size and version

| PR | What | Version |
|---|---|---|
| **R2-1** | The migration and `db/structure.sql`; the model's status, scopes and validations; graph_mem-sql v2 (template, writer, validator, the v1 reading, the specs with ended rows written directly); `docs/data_exchange.md`; the four cleanups of item 10. No MCP-visible change: nothing can end a relation yet | none, CHANGELOG under `[Unreleased]` |
| **R2-2** | `RelationLifecycle`; every reader of item 4; the writers of item 5; the MCP surface (item 6) and its snapshots; REST and Swagger; Explore's toggle, the entity panel, the MCP Apps dashed edge; the `relation_review` apply and card; the sweep's and the repairer's rules; the docs; the 1.97.0 release | 1.97.0 |

- **Why this split:** the migration and v2 must land together (the template spec fails otherwise), and with no
  writer of `ended`, R2-1's readers are correct as they are. R2-2 then turns the lifecycle on in one piece.
- **Size:** R2-1 is about 1,500 lines, 650 of them the mechanical copy of `v1/` into `v2/`. R2-2 is about
  2,700 with specs. If R2-2 passes the ~3,000-line stop, its UI (Explore's toggle, the entity panel, the
  Review card) moves to an R2-3 before the release. Push-and-continue checkpoints as usual.
- **Version:** 1.97.0 (both PRs released together). The kickoff confirms it against `lib/graph_mem/version.rb`,
  then `bin/rails graph_mem:sync_skill_version`.
- **Docs in R2-2:** `docs/dream_state.md` (the `relation_review` apply; "a removal fact never ends a
  relation" becomes "never ends one unattended"; the sweep's `skipped_ended`), `docs/mcp_tools.md` (the
  parameter, the keys, `end_relation`, reactivation, `relation_review`), `docs/architecture.md` (a "Relation
  lifecycle" section), `docs/guides/ui-guide.md` (the panel, the toggle, the card), the CHANGELOG.

## Measure before the kickoff

R1c's `relation_review` rows are R2's main input, and none has been queued in production (still 1.95.0).

- **When:** after 1.96.1 is deployed and dream state has run 7 to 14 nights.
- **What (counts only, read-only):** `relation_review` rows by status (pending, dismissed, snoozed) and by
  `relation_type` (`depends_on`, `part_of`); the distinct relations they name; and, for R1b's "Done when",
  the applied `swap` rows, dependency-like entities still `part_of` a Project root (21 today) and orphans
  (26 today).
- **What the kickoff does with it:**
  - **0 to 2 pending rows:** R2's value is the hiding and the agents' `end_relation`; the review apply stays
    as planned but small, and no policy is discussed.
  - **Most resolved rows dismissed:** the phrase rule is too loose. R2-2 first tightens `RemovalEvidence`
    (for example, skip a fact where the entity follows "with" or "by" in a "replaced" phrase), then gives the
    rows their apply.
  - **20 or more pending, mostly right:** the apply matters as planned; Question 6 can be asked again with an
    approval rate.
  - **`part_of` rows:** their number says how much the swap-and-end path is used. If R1b's swaps were all
    applied first, it may be none.

## Questions for Steve

Eight questions, most important first, in two groups of four. Each recommendation comes first.

### Group 1

**1. Can a `part_of` be ended?** (header: part_of end)
R2 lets a relation be ended (kept as history, hidden by default). `part_of` decides an entity's project. May a
`part_of` be ended? A removal-fact review row can sit on a library's `part_of` (SynthLib part_of SynthApp)
before its swap.
- **Never; swap, then end (Recommended).** Membership, single parent, orphans and ProjectSubtree stay as they
  are. Applying the row turns SynthLib part_of SynthApp into SynthApp depends_on SynthLib, ended; SynthLib
  turns global, and undo restores it.
- **Never; refuse the row.** Same invariant, less code. The row on SynthLib part_of SynthApp answers "apply
  its swap first"; after the swap, the next night's run queues a new row on the depends_on, which then ends it.
- **Allowed; membership follows.** An ended part_of stops counting: SynthWidget part_of SynthApp ended →
  SynthWidget goes global under the lock, undo brings it back. About 15 part_of readers and the SQL checks
  learn the status.

**2. Re-adding an ended edge.** (header: Re-add)
The unique key (from, to, type) also covers ended relations, so each edge has one row. What happens when an
agent or the operator writes an edge that exists as ended?
- **Reactivate it (Recommended).** One row, history in its audit row; scans, imports and dream state never
  reactivate. SynthApp depends_on SynthLib was ended; graph_write of the same edge → it comes back active,
  the old end echoed in the result.
- **Refuse as a duplicate.** graph_write answers possible_duplicate with the ended edge as candidate; only
  the operator's Reactivate brings it back. An agent re-adding SynthApp depends_on SynthLib is refused.
- **Add a second row.** The unique key gains the status, so each period is its own row: SynthApp depends_on
  SynthLib has one ended and one new active row, and every (from, to, type) reader changes.

**3. How agents end a relation.** (header: End op)
How do agents end a relation over MCP? Today graph_delete has delete_relation (a hard delete) and
delete_observation, which already marks a fact obsolete; graph_edit's description says not to use it to
obsolete.
- **graph_delete end_relation (Recommended).** Next to delete_relation, reason required like every
  graph_delete op; no new tool. end_relation 41, reason "replaced by SynthParser" → SynthApp depends_on
  SynthLib ended, undoable; delete_relation stays for a wrong edge.
- **graph_edit end_relation.** The same operation on graph_edit; its "do not obsolete" line is rewritten.
  graph_edit end_relation 41 → the same result.
- **No MCP ending.** Only the operator (entity panel) and applied review rows end edges. An agent told
  SynthApp dropped SynthLib can only delete the edge or leave it.

**4. Which tools show ended edges.** (header: Show ended)
Ended relations are hidden from every default read (traversal, paths, search, relation projections). Which
MCP tools get an include_ended parameter to show them, marked with status, ended_at and ended_reason?
- **traverse_graph and get_entities (Recommended).** The two the Dream State plan named; search's schema (415
  calls in 90 days) stays as is. get_entities SynthLib, include_ended: true → "SynthApp depends_on SynthLib,
  ended 2026-11-27: replaced by SynthParser".
- **Those two plus search.** search's subgraph mode shows them too, between the page's hits. search "SynthLib"
  with relations and include_ended → the ended edge in relations.
- **None.** Hidden over MCP; only the operator UI and the audit log show them. An agent can't learn that
  SynthApp used SynthLib until 2026-11.

### Group 2

**5. When R2 starts.** (header: Kickoff)
R1c's relation_review rows are R2's main input, but production still runs 1.95.0, so none has been queued.
When does R2 start?
- **Measure first (Recommended).** Deploy 1.96.1, let 1-2 weeks of nightly runs pass, count the rows (counts
  only), then kick off. 0 rows → the apply stays small; mostly dismissed → R2-2 tightens the phrase rule first.
- **R2-1 now, count later.** R2-1 (schema, SQL v2, cleanups) needs no count; the count comes before R2-2's
  review apply. R2-1 starts this week; R2-2 waits for the deploy and the count.
- **Start now.** Both PRs without the count; R1c's rows get their apply blind. Fastest; the first production
  numbers arrive after 1.97.0.

**6. A policy for removal rows.** (header: Auto-end)
R1c's relation_review rows (a project fact says a library was removed, replaced or dropped) get an apply in R2:
end the relation, the fact as the reason. May a review policy apply them unattended?
- **No policy (Recommended).** The rows are noisy by design (a fact naming SynthLib as the replacement is
  queued too) and none has run in production. A row is ended only when the operator or an agent applies it,
  one by one.
- **A policy, off by default.** Like auto_apply_relation_retype, turned on in Settings. Once on, the fact
  "SynthApp migrated away from SynthLib" ends SynthApp depends_on SynthLib overnight; Undo the run reverses it.

**7. Reading v1 scripts.** (header: v1 scripts)
R2's migration makes the SQL export write graph_mem-sql v2 (relations carry their status). A 1.97 target is
past v1's max_schema, so today a v1 script from a 1.96 machine would be refused. Should the 1.97 app read v1
scripts?
- **Read v1 through v2 (Recommended).** The app validates the file as v1 and merges it with v2's template;
  v1 carries no status, so new edges are active and an ended one stays ended. A 1.96 machine's SynthApp
  script imports on 1.97.
- **Refuse v1, as today.** No code: the script's own guard says "upgrade graph_mem on the source machine and
  export again". The 1.96 machine is upgraded first, then exports v2.

**8. Validity dates on relations.** (header: Validity)
Observations have valid_from / valid_until (when a fact held in the world) besides obsoleted_at. Should
relations get them in R2, next to status, ended_at (when graph_mem learned it ended) and ended_reason?
- **Not now (Recommended).** Nothing reads a validity window on relations yet; ended_at and ended_reason say
  "used until". SynthApp depends_on SynthLib: ended 2026-11-27, "replaced by SynthParser in March".
- **valid_until only.** end_relation takes an optional valid_until: when it stopped in the world. SynthApp
  depends_on SynthLib: ended 2026-11-27, valid until 2026-03-31.
- **Both, like observations.** graph_write, end_relation and the SQL template carry both; temporal recall still
  ignores them until a reader exists. SynthApp depends_on SynthLib valid 2025-01 to 2026-03.

## What stays out

- **Nothing ends a relation unattended.** No policy (Question 6), and no scan, import or dream-state phase
  ends one. Scans could end a `depends_on` whose library left the manifest, or a code-map edge the map no
  longer has (today a `delete_relation` row, `skeleton_writer.rb:209-221`): later, behind a measurement.
- **No automatic delete**, and `delete_relation` keeps its meaning.
- **No history of periods:** one row per edge; the audit log holds the earlier ends.
- **No change to membership, `ProjectSubtree`, the orphan rule or the backfill** (item 3).
- **No temporal recall over relations** (Question 8), and `as_of` still reads observations only.
- **No MCP undo**, as today.
- Nothing here weakens the `/mcp` lockdown, the anonymizer or the cloud gate.
