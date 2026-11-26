# Plan: Dream State as knowledge traversal (relations first)

> Status: draft, 2026-11-20, written on `main` at 1.92.0. Revised the same day after Steve's
> answers and two review rounds (see "Answers" at the end). **R1a shipped as 1.93.0** (see its
> "As built" note); R1b onward is not started. Each PR below gets its own kickoff.
>
> **Versions (2026-11-24):** the `part_of` membership PRs took 1.93.1 and 1.93.2 (their own plan), so
> the mcp 1.11.0 bump moved to 1.93.3. Later the same day the embedding calls moved out of the
> membership lock (a follow-up of those PRs, released as 1.93.3), so the mcp 1.11.0 bump moved on to
> 1.93.4. The minors below are unchanged.

## Context

Dream State was meant to walk the graph while agents are idle and improve what a search or a
traversal gives back: spot missing relations, fix wrong ones, lower noise. Today
(`docs/dream_state.md`, `app/strategies/dream_state_compactor.rb`) it tidies:

- phase 1 parents orphans under a Project by name-token match (automatic at score ≥ 10);
- phase 2 removes duplicate observations and merges near-identical same-type entities;
- phase 3 proposes relations from two text rules (`solves`, `depends_on`), review-only.

It never looks at a relation that already exists, and a relation has no lifecycle: `memory_relations`
has `weight`, `confidence` and `properties`, but no status or dates, so a wrong edge can only be
deleted.

Steve's example, with synthetic names: "SynthLib is a part of SynthApp". It *was* a library the
project used, never a part of it, and the dependency is gone. The node itself is worth keeping (it
holds the debugging history of its use); it needs the right edges. **The goal:** a search or a
traversal for a project doesn't bring back an outdated library through a past relation.

## Decisions (Steve, 2026-11-20)

1. All seven ideas below are wanted; relations come first.
2. **Retype before delete.** A node like a former library keeps its observations and gets the proper
   edges. Deleting a relation is the last resort, for clear cases only (none known yet).
3. A **lifecycle for relations** ("was used") is its own release: it needs a migration and changes
   what `traverse_graph` returns.
4. **Measure first**, and again after each release.
5. Docs under `docs/` are kept up to date with each release (`docs/dream_state.md` first of all).

## Measurements (production graph, 2026-11-20, read-only, counts only)

| What | Count |
|---|---|
| Entities / relations / Projects | 504 / 848 / 12 |
| `part_of` relations | 470 (55% of all), 455 of them straight to a Project |
| Non-Project entities whose only edge is `part_of` (or none) | 155 |
| `depends_on` relations | 10 |
| Library-like entities (framework, library, gem, tool types) | 21; about 20 of them are `part_of` a Project, 1 is a `depends_on` target |
| Library-like entities named in a removal-style fact somewhere | 2 |
| Distinct relation types | **117**, 62 of them not lower snake case |
| Relations whose type is outside `GraphVocabulary::RELATION_TYPES` | **239 (28%)** |
| Relations with a `weight` / a `confidence` | 1 / 0 |
| Relationship proposals: approved / dismissed | 58 / 170 (57 of the approvals by the auto-apply policy) |
| Orphan-parent suggestions: approved / dismissed | 2 / 28 |
| Merge suggestions: approved / dismissed | 0 / 234 |
| Orphans now | 26 |
| Active observations; per entity median / p90 / max | 3,588; 5 / 12 / 116 |
| Tool calls in 90 days | `search` 343, `get_context` 140, `get_entities` 93; `traverse_graph` isn't in the top eight |

What they say:

- **The graph is flat.** More than half of all edges only say "this belongs to project X", and 155
  entities have nothing else. There is little for a traversal to follow, which fits how rarely
  agents traverse.
- **The relation vocabulary is the largest noise source, and it wasn't on the list.** 117 types for
  848 edges: case and spacing variants of canonical types, and one-off verbs. `RelationTypeMapping`
  canonicalizes on every save, but through a table that was never seeded (see below), existing rows
  were never swept and unmapped variants pass through. A traversal filtered by `relation_types` misses 28% of the edges (the filter compares
  case-insensitively, so the 3 relations that differ from a canonical type by case alone do match;
  the 239 are spelling variants, synonyms and one-off verbs).
- **Libraries sit under `part_of`.** About 20 of 21 library-like entities are "part of" a project
  and one is a `depends_on` target: Steve's example is the rule, not the exception.
- **Removal is rarely said on the library's own node.** Only 2 library-like entities are named in a
  removal-style fact, and such facts sit mostly on Tasks and Issues. So "removed" can't be the main
  signal for retyping; the entity's type can.
- **The suggestion generators are mostly noise**: merges 0 of 234 approved, orphan parents 2 of 30,
  relationship proposals about 1 in 4. New discovery rules need a measured approval rate before
  they queue rows by default.
- **Weights and confidences are empty**, so nothing ranks one edge above another yet.

Why the vocabulary drifted (checked after Steve recalled an earlier canonicalization):

| What | Count |
|---|---|
| Canonical relation types in `GraphVocabulary` | 21 |
| Variants the code maps to them (`GraphVocabulary::RELATION_TYPE_MAPPINGS`) | 59 |
| Rows in production's `relation_type_mappings` table | **4** (55 seed rows missing) |
| Out-of-vocabulary types / relations | 108 / 239 |
| Fixed by the code's mapping plus trivial normalizing (case, spaces, hyphens) | 10 types, 56 relations |
| Left with no mapping at all | 98 types, 183 relations (69 types used once) |
| Case-only variants of a canonical type | 2 types, 3 relations |
| Library-like entities: same name held twice / already global / with `part_of` children | 0 / 1 of 21 / 5 children in all |
| Names of scoped libraries, or of their 5 children, already taken at global scope | 0 / 0 |

- Every ActiveRecord save of a relation canonicalizes its type (`before_validation` on
  `MemoryRelation`, so `graph_write`, the REST API and the importers), but only through the
  `relation_type_mappings` table, which was never seeded in production: there it does almost
  nothing. `EntityTypeMapping` falls back to the vocabulary in code; `RelationTypeMapping` doesn't.
- There is no task, job or UI that sweeps the relations already stored.
- Even fully seeded, the mapping covers a quarter of the drift. The rest are one-off verbs an
  operator has to map or accept, which is the case for a UI.

Not measured: how many `part_of` edges phase 1 created. Relation audit rows carry no dream-state
actor to tell (87 creations in the audit window have an empty actor). Release 1 fixes that first.

## Order and size

Steve's call (2026-11-20): **the vocabulary part ships first, the retyping after the SQL exchange.**
The versions, as expected today (each kickoff confirms its own against `version.rb`):

| PR | What | When | Version |
|---|---|---|---|
| **R1a** | Relation vocabulary: mapping fallback, normalize on write, the sweep, the unmapped-types page | first (shipped) | 1.93.0 |
| `part_of` membership, PR 1 | Every `part_of` writer keeps membership in step: entity delete, merge, relation repair, scans, imports, the drift guard (`done/part-of-membership-plan.md`) | after R1a (shipped) | 1.93.1 |
| `part_of` membership, PR 2 | The scan validator and scanner lock order, the rake tasks, dream state and the integrity sweep (`done/part-of-membership-plan.md`) | after PR 1 (shipped) | 1.93.2 |
| Embeddings outside the membership lock | A follow-up of the membership PRs (`done/part-of-membership-plan.md`, Follow-ups) | after PR 2 (shipped) | 1.93.3 |
| mcp 1.11.0 | (its own plan) | after the follow-up | 1.93.4 |
| SQL exchange | (its own plan, five PRs incl. the JSON export's retirement: `done/sql-exchange-plan.md`) | after mcp 1.11.0 (shipped) | 1.94.0 |
| **R1b** | Retype library `part_of` edges, the orphan rule, the SQL export's scope, dream-state actor on its edges | after the SQL exchange train | 1.95.0 |
| **R1c** | Removal-style evidence rows | with or right after R1b | with R1b, or 1.95.1 |
| **R2** | Relation lifecycle | after R1 | 1.96.0 |

Each PR has its own kickoff, the usual ~3,000-line stop and push-and-continue checkpoints. R1a is
about the size of 1.92.0; R1b is smaller in code but touches membership-adjacent paths.

Dependencies between the plans:

- The SQL exchange import writes relations with raw `INSERT`s (its staging tables), which skip the
  model's canonicalization. **Done in 1.94.0:** the import canonicalizes the staged relation types with the
  same canonicalizer and the target machine's mappings (`SqlExport::Template.relation_type`, which the
  exporter applies too), so an import doesn't bring variants back. A variant of `part_of` that SQL doesn't read
  as `part_of` (`child_of`) keeps its spelling, as the sweep never writes a `part_of` edge either, and a script
  run by hand skips the step and leaves it to the sweep (`done/sql-exchange-plan.md`, "As built";
  [`docs/data_exchange.md`](../data_exchange.md#merge-rules)).
- R1b moves libraries out of the `part_of` tree, so a project-subtree export no longer contains
  them. That is why it waits: the exchange lands on today's tree, and R1b's kickoff then decides
  whether a subtree export follows a Project's `depends_on` edges (it should, one hop).
- **The JSON export and its reviewed import are gone** (retired in 1.94.0, after the SQL exchange):
  they read `depends_on` as child → parent, like `part_of`, which R1b's swap would have broken, so
  nothing of them is left to change. What is left for R1b is **the SQL export's scope**
  (`SqlExport::Scope`): a Project's script carries its `part_of` tree (`ProjectMembership.member_ids`)
  and nested Projects, and every relation with an end in it, the other end travelling as a reference
  by name that the import only looks up. After the swap a Project's script would carry `Project
  depends_on library` with the library as a reference only: its facts and its own subtree would not
  travel, and an import on a machine that lacks the library would skip the edge. So R1b also makes
  the Project's export follow its outgoing `depends_on` edges one hop (the libraries as rows, with
  their own `part_of` subtrees, without their other dependents); the script format version moves
  only if the template changes. The export picker's roots (`SqlExport::Roots`) still treat an outgoing
  `depends_on` as a child edge, like `part_of`: R1b's kickoff decides whether that becomes `part_of`
  only. The JSON import engine, kept for `graphify:import` and `rails_ast:import`, still reads a
  `depends_on` child in its payload tree as child → parent; R1b's kickoff checks whether the Graphify
  translation writes any. `docs/dream_state.md` described `depends_on` as running "from children to
  parents" in the tree walk; the dream-state tree walk follows `part_of` only (R1a corrected that
  sentence).
- R2 changes `memory_relations`, so it bumps the SQL exchange script format version.

## R1a. Relation vocabulary (no migration; one stored-value change, approved)

1. **Mapping without a seed.** `RelationTypeMapping.canonicalize` falls back to
   `GraphVocabulary::RELATION_TYPE_MAPPINGS` when the table has no row, as
   `EntityTypeMapping.vocabulary_type` does. Nothing is written at boot (no race between booting
   processes); the table holds only what an operator adds.
2. **Normalize on write** (Steve: yes). Before the lookup, `MemoryRelation.canonical_relation_type`
   folds case, spaces and hyphens ("Has Many", "has-many" → `has_many`), in that one place, and
   returns the folded type when nothing maps. The save callback is switched to it
   (`self.relation_type = MemoryRelation.canonical_relation_type(relation_type)`): today it calls
   `RelationTypeMapping.canonicalize` directly and keeps the raw type when that answers nil, which
   would leave novel types un-normalized. So every save path stores the same type. A type that maps to nothing is stored normalized: novel types
   stay allowed, in lower snake case. **This is the one MCP-visible change of R1**: a `graph_write`
   with a variant type stores, and returns, the normalized or canonical type. No parameter, tool or
   schema changes.
3. **The sweep of stored relations**: `RelationTypeSweep`, one service with three callers.
   - **Callers:** a new dream-state phase `relation_types` that runs first (its own cursor over
     relation ids, the compactor's pause checks, 200 relations per batch); `bin/rails
     graph_mem:canonicalize_relations` with `DRY_RUN=1`; and a "Canonicalize relation types" button
     on System › Background jobs that shows the dry-run counts first and then queues the job.
   - **Per relation**, the canonical type is computed, then:
     - *same type*: nothing;
     - *differs by case only*: a plain update. The unique key (from, to, type) compares
       case-insensitively, so the row is its own "twin" and can never collide;
     - *another type, no row with the canonical type on the same endpoints* (looked up excluding
       the row's own id): retyped in place;
     - *another type, a canonical twin exists*: the variant row is merged into the twin (its
       `properties` kept under a key on the twin when the twin has none, the higher `weight` and
       `confidence` kept) and deleted;
     - *the canonical type is `part_of`*: never updated in place, because an update skips the
       create-time checks (single parent, no cycle) and the membership sync. It becomes a
       `relation_retype` review row, applied through the normal relation create path under the
       membership lock.
   - **Locks:** the membership lock is taken before the batch's transaction, as the lock-ordering
     rule requires, only for batches that hold a `part_of` candidate (which queue rows, so in
     practice the sweep never needs it).
   - **Undo:** each batch is one change set (`dream.relation_types`), **not undoable** through the
     generic undo: a restored variant would be canonicalized again on save, and a merged row would
     collide with its twin. Instead the run report lists every change (relation id, old type, new
     type, merged-into id), which is enough to reverse one by hand.
4. **The unmapped types go to the operator.** A page under System › Background jobs lists each type
   that is neither canonical nor mapped, with its use count and two example edges (names shown to
   the operator only), and two actions: **map** it to a canonical type (a row in
   `relation_type_mappings`; the next sweep retypes its relations) or **accept** it (kept as a
   known novel type and dropped from the list). Nothing is guessed. 98 types today, 69 used once.
5. **MCP review tools:** R1a adds one review `kind`, `relation_retype` (payload: `operation`, the
   relation id, both entity ids and names, the old and the new type, the reason). `operation` is
   `"retype"` here (same endpoints, a variant becoming `part_of`); R1b adds `"swap"` (a `part_of`
   becoming a `depends_on` with the endpoints swapped) and `"add"` (no edge yet: phase 1's
   suggestion to create `Project depends_on entity`). The apply branches on it. No policy applies
   a `"retype"` row: it creates a `part_of`, a membership move, so it stays the operator's. `list_maintenance_review`
   returns it like any row and `apply_maintenance_review` applies it; tool counts, parameters and
   schemas don't change. The kickoff lists the payload keys.
6. **Docs:** `docs/dream_state.md` (the new phase, and its sentence that an orphan has "no `part_of`
   or `depends_on`" parent, which the code never did: `part_of` only), `docs/mcp_tools.md`
   (normalized types), `docs/architecture.md`.

**As built (1.93.0).** What differs from the list above:

- **Where the UI is.** The Maintenance hub no longer exists (gone since 1.62.0): the card ("Relation
  types") and the unmapped-types page are under System › Background jobs, at
  `/system/jobs/relation_types`. The page also lists the mapping table with **Remove**, which the
  list above didn't have.
- **Order.** R1a shipped before mcp 1.11.0, so the mcp bump was 1.93.1, and the two `part_of` membership PRs then
  took 1.93.1 and 1.93.2, which made it 1.93.3, and the follow-up that moved the embedding calls out of the
  membership lock took 1.93.3, which made it 1.93.4 (the version table is
  updated; the SQL exchange stays 1.94.0, R1b 1.95.0, R2 1.96.0).
- **No seed.** The relation seed file was removed and `db/seeds.rb` keeps only the entity type
  seed; installs seeded earlier keep their rows (they still win over the code's mapping).
- **Properties of a merged variant.** The twin keeps its own `properties`. With none of its own it
  takes the variant's; otherwise the variant's are kept on the twin under `merged_from` (one entry
  per merged variant: relation id, stored type, properties).
- **Canonicalize only when the type is set.** The save callback runs on a create and on an update
  that changes the type, not on every save, so an entity merge re-pointing an edge, or its undo,
  keeps the stored spelling and can't turn a variant into `part_of` behind the create-time checks.
  An undo that re-inserts a deleted relation restores its stored type as it was.
- **The sweep's outcomes.** Besides the five in the list, a run counts `already_queued`,
  `skipped_part_of` and `error`; a variant that canonicalizes to `part_of` and has a `part_of` twin
  is merged into it (the edge exists, membership doesn't change) rather than queued.
- **REST membership fixes.** `POST /api/v1/bulk` and `POST`/`PATCH /api/v1/memory_relations`
  take the membership lock and sync the child's project when a relation is, becomes or stops being
  `part_of`, refusing with the existing 422. `DELETE` of a `part_of` relation through the REST API
  didn't sync membership in 1.93.0; the follow-up after it does (lock, delete, sync, 422 on a
  collision or a busy lock), and so do the operator's data-exchange retype, delete and duplicate
  cleanup. The writers still missing the lock or the sync at 1.93.0 (entity deletes, entity merges
  with two parents, the "Repair relation duplicates" button) were fixed in 1.93.1; scan
  validation, the rake tasks, the scan's lock order, dream state's and the integrity sweep's edge
  writes in 1.93.2 (see [`part-of-membership-plan.md`](done/part-of-membership-plan.md)).
- **Docs corrected.** `docs/dream_state.md` now says an orphan has no `part_of` parent (the
  `depends_on` clause was never in the code) and that the tree walk follows `part_of` children
  down from the Project roots.
- **Not changed:** tool counts (12 / 9 / 22), parameters and schemas. `relation_retype` appears in
  `list_maintenance_review` and `apply_maintenance_review`; its payload keys are `operation`
  (`"retype"`), `relation_id`, `from_entity_id`, `from_name`, `to_entity_id`, `to_name`, `old_type`,
  `new_type`, `reason`.

**Done when** (re-measured on production after the first sweep, counts only; **not done yet**: the
re-measurement waits for the release to be deployed and the first sweep to run, so the table below
still shows the targets only):

| Measure | Before | Target |
|---|---|---|
| Relations with a mapped or trivially normalizable variant type | 56 | 0 |
| Case-only variants | 3 | 0 |
| Relations outside the vocabulary | 239 | 183 or fewer, each of their types either accepted or awaiting the operator on the page |
| Relations lost | — | 0 (merges into a twin are counted and listed) |

## R1b. Libraries: `depends_on`, global scope, and the orphan rule (after the SQL exchange)

Steve's decision (2026-11-20, replacing the earlier "keep its project scope"): **a library a project
only uses is not part of it, so it leaves the project's scope.** Scope is derived from `part_of`
alone (`ProjectMembership`), and that rule stays as it is: no change to membership, `ProjectSubtree`
or the backfill. Retyping simply applies it.

1. **The retype swaps the endpoints.** `library part_of Project` becomes `Project depends_on
   library`: `depends_on` runs from the dependent to its dependency everywhere else in the repo. It
   is a delete of the `part_of` plus a create of the `depends_on` through the normal paths, in one
   audited change set, under the membership lock.
2. **What follows from membership, stated up front:**
   - the library's `project_id` becomes NULL (global), and so does its own `part_of` subtree (5
     such children exist today): they stay attached to the library;
   - a project search filtered by `project_id` no longer returns the library; a search boosted by
     the context project still finds it by name, and a traversal from the Project reaches it over
     `depends_on`. That is the goal: the project's own results stop carrying its libraries' noise;
   - a library two projects use is **one** global node with a `depends_on` from each;
   - a name collision at global scope raises `ProjectMembership::Collision` today. Two cases:
     - *the library's own name* is taken (a library with that name is already global, or two
       projects each hold one): the retype row is refused with that reason and an `entity_merge`
       suggestion for the two same-named libraries is queued; after the merge the retype applies;
     - *a child's name* is taken (a notes or config node under the library): the retype is refused
       naming the child, and nothing is queued: merging two unrelated generic children would be
       wrong. The operator renames or moves the child first.

     Neither exists today (0 library names and 0 of the 5 children's names are taken globally).
3. **Candidates:** a `part_of` edge from an entity whose type is in the **dependency-like types**
   setting (Settings, editable; seeded with the framework, library, gem and tool types seen in the
   graph) to a Project. Queued as `relation_retype` rows by a dream-state step, with the evidence:
   the type, and any fact of the project that says it uses or used the entity.
4. **Policy `auto_apply_relation_retype`, off by default.** It applies **only `operation: "swap"`
   rows** (never `"retype"`, which creates a `part_of`, nor `"add"`). It lifts the AutoApply hard
   rule for its own kind only, takes the membership lock before the row lock, counts a `Collision` as
   skipped (next to `LockTimeout` → busy), and applies only rows with no ownership signal. The
   ownership signal is testable: the project has no fact whose keyword path holds the library and
   whose text matches an ownership phrase list ("part of this project", "our own", "maintained
   here", "vendored", "forked"); the list is a constant, shown in the policy's help text.
5. **The orphan rule changes with it, in the same PR.** An entity is an orphan when it has no
   `part_of` parent **and** no Project `depends_on` it. Without that, every retyped library would
   become an orphan and phase 1 would parent it back by name match, in a loop. Phase 1 also stops
   auto-parenting an entity of a dependency-like type: it queues a `relation_retype` row with
   `operation: "add"` (`Project depends_on entity`) instead. It is deliberately not a
   `relationship_proposal`, which `AutoApplyRelationships` could apply unattended. Every edge dream state creates carries the
   actor "job:dream_state" in its audit row.
6. **Undo** is the ordinary audit undo (a delete and a create, plus the membership sync it already
   runs), so the library returns to the project's scope.

**Done when:** on a synthetic graph, retyping one library gives `Project depends_on library`, a
NULL `project_id` for it and its children, and no `part_of`; two dream-state runs afterwards create
no `part_of` and queue no orphan row for it; undo restores the `part_of` and the `project_id` of
the library and its children; redo makes them NULL again; a backfill run afterwards changes 0
rows; the Project's graph_mem-sql export still carries the library as rows (not only a reference by
name), and an export of the library doesn't carry the Project. On production: library-like entities under `part_of` a Project go from about 20
to those with an ownership signal; orphans don't rise; dream-state-created edges are countable by
actor.

## R1c. Removal-style evidence (with or right after R1b)

When a fact on any entity of a project says a named entity was removed, replaced or dropped, and a
Project still `depends_on` (or holds by `part_of`) that entity, a `relation_review` row is queued
with the fact as evidence. In R1 the row is **informational**: it can be dismissed or snoozed, and
`apply_maintenance_review` answers a validation error ("ending a relation arrives with the relation
lifecycle; remove the relation by hand if it is wrong"). R2 gives it its apply. Only 2 library-like
entities are named in such a fact today, so this is small.

## R2. A lifecycle for relations (migration; MCP output change, needs Steve's approval)

- `memory_relations` gains `status` (active / ended), `ended_at`, `ended_reason`, and optionally
  `valid_from` / `valid_until`, mirroring observations.
- An ended relation is kept and audited, hidden from default traversal and search, and shown on
  request (`include_ended` on `traverse_graph` / `get_entities`): "SynthLib: used by SynthApp
  until …". This is what finally keeps an outdated library out of a project's results.
- R1c's `relation_review` rows get their apply: end the relation, with the removal fact as the reason.
- Deleting stays available by hand only.

Questions the R2 plan must answer before a kickoff:

- the surface: the new parameter, the extra keys on relation payloads, whether `graph_edit` may end
  a relation;
- the unique key (from, to, type) also covers ended rows: does re-adding an ended edge reactivate
  it, or is it refused?
- an ended `part_of`: does it still count for membership, the single-parent check, orphans and
  `ProjectSubtree`? (`project_id` would follow.)
- which other readers hide ended edges: `find_shortest_path`, `get_context`, graph stats, the SQL
  export, Explore;
- the SQL exchange script format version, bumped by the migration.

## R3. Discovery by traversal (idea 5), each rule behind a measured approval rate

Candidates, review-only:

- co-mention: two entities named together in facts of a third, several times;
- a class, file or path name of an entity that appears in another entity's facts with no edge between them;
- embedding-near entities of *different* types (same-type nearness already drives merges);
- a two-hop path that implies a missing direct edge.

A rule ships disabled, runs in a "shadow" mode that only counts what it would propose, and is
turned on only when a sample of its proposals is judged right often enough (bar to be set; the
current rules sit near 25%).

## R4. Ranking and noise (ideas 6, 7), each behind a before/after measurement

- Maintain `weight` and `confidence` on relations: set on creation by source (operator, agent,
  policy, discovery), decayed when nothing uses the edge, and raised when sessions did. "Used" is
  computed **in the nightly job from the tool-invocation log**, never as a write on a read path
  (`traverse_graph`, `get_context` stay read-only).
- Let search prefer the newest fact among siblings on one keyword path.
- Propose summaries for entities with long fact lists (max is 116 active facts); flag entities with
  no facts, no edges but `part_of` and no recent hits as GC candidates.
- Needs a fixed set of queries on a synthetic graph, scored before and after.

## What stays out

- No relation is deleted automatically in any release above, except R1a's merge of a variant row
  into its canonical twin (same endpoints, same meaning) and R1b's swap of a `part_of` for its
  `depends_on`; both are audited and listed in the run report.
- Nothing here weakens the `/mcp` lockdown, the anonymizer or the cloud gate.
- No LLM call is required for R1; an LLM judge for retype evidence can be discussed for R3.

## Answers (Steve, 2026-11-20)

1. **Scope of a retyped library.** First answer: keep its project scope, never root level. Revised
   after the review showed scope follows `part_of` alone: the aim is that a project's search and
   traversal results don't carry an outdated library, so **if "just used by" means the library
   moves to global scope, do that**. A library used by two projects is one node both depend on.
2. Canonicalize relation types on every write path, and give the operator a way to run it over the
   whole graph (the rake task and the Background jobs button).
3. The dependency-like type list starts from the types in the graph and is editable in Settings.
4. R1 is one piece of work, shipped as separate PRs: the vocabulary part first, right after mcp
   1.11.0; the retyping after the SQL exchange train.
5. Docs under `docs/` are kept up to date with each PR.
