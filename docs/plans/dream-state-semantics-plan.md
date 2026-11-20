# Plan: Dream State as knowledge traversal (relations first)

> Status: draft, 2026-11-20, written on `main` at 1.92.0. Not started. Steve answered the four
> questions on 2026-11-20 (see "Answers" at the end); R1 is ready for a kickoff once this is merged.
> No code in this PR. Each release below gets its own kickoff.

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

Steve's example: "jQuery is a part of the Goggles framework". It *was* a library the project used,
never a part of it, and the dependency is gone. The node itself is worth keeping (it holds the
debugging history of its use); it needs the right edges.

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
  canonicalizes on some write paths, but existing rows were never swept and unmapped variants pass
  through. A traversal filtered by `relation_types` misses 28% of the edges.
- **Libraries sit under `part_of`.** About 20 of 21 library-like entities are "part of" a project
  and one is a `depends_on` target: the jQuery case is the rule, not the exception.
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

- `graph_write`, the REST API and the importers do canonicalize through `RelationTypeMapping`, but
  the table they read was never seeded in production, so there it does almost nothing.
- There is no task, job or UI that sweeps the relations already stored.
- Even fully seeded, the mapping covers a quarter of the drift. The rest are one-off verbs an
  operator has to map or accept, which is the case for a UI.

Not measured: how many `part_of` edges phase 1 created. Relation audit rows carry no dream-state
actor to tell (87 creations in the audit window have an empty actor). Release 1 fixes that first.

## Releases

### R1. Relations: vocabulary and retyping (no migration, no MCP change)

1. **Canonical types for existing relations** (new idea 0, from the measurements).
   - **Seed first:** the mapping table is filled from `GraphVocabulary::RELATION_TYPE_MAPPINGS` at
     boot or deploy when rows are missing (idempotent), so production stops running on 4 rows.
   - **Normalize on every write path** (Steve: yes): case, spaces and hyphens are folded before the
     lookup, in one place (`MemoryRelation.canonical_relation_type`), so `graph_write`, the REST
     API and the importers store the same type for "USES", "uses" and "Uses". A type that maps to
     nothing is still stored as written (normalized): novel types stay allowed.
   - **Sweep the stored relations:** one service object (`RelationTypeSweep`) used by a dream-state
     step, a rake task (`graph_mem:canonicalize_relations`, with a dry run) and a button on
     **System › Maintenance** ("Canonicalize relation types", with the counts it would change).
     A row whose canonical type differs is retyped in place; when the canonical twin already exists
     (the unique index on from, to, type), the variant row is merged into it. One undoable change
     set per run.
   - **The unmapped rest goes to the operator:** a page (Maintenance or Review) lists each type
     that is neither canonical nor mapped, with its use count and two example edges, and lets the
     operator map it to a canonical type (then the sweep retypes its rows), or accept it as is.
     Nothing is guessed. 98 types today, 69 of them used once.
2. **Retype `part_of` on dependency-like children** (ideas 1, 3).
   - Candidate: a `part_of` edge whose child has a dependency-like entity type and whose parent is
     a Project. The list of dependency-like types is a setting (Steve: yes), editable in Settings,
     seeded from the types seen in the graph (the framework, library, gem and tool types).
   - Proposal: a new review row kind `relation_retype` (`part_of` → `depends_on`), with the
     evidence shown: the child's type, and any fact that says the project uses or used it.
   - **Project scoping is kept** (Steve): the retyped entity keeps its `project_id` and only the
     edge changes, so nothing moves in search scoping and it never lands at root level. A library
     two projects use gets a `depends_on` edge from each (an entity can have one `part_of` parent
     but any number of dependents); the row for the second project proposes that edge.
   - A policy `auto_apply_relation_retype`, **off by default**, applies the rows whose child type is
     on the list and whose project has no fact claiming to *own* the entity. Undoable change sets.
3. **Stop creating the problem** (idea 4). Phase 1 auto-parents only when the orphan's type is
   not dependency-like; otherwise it queues the suggestion with `depends_on` proposed. Every edge
   dream state creates gets `actor` "job:dream_state" in its audit row, so the next measurement can
   count them.
4. **Removal-style evidence** (idea 1, second half). When a fact on any entity of the project says a
   named entity was removed, replaced or dropped, and that entity still has a live `part_of` or
   `depends_on` edge to the project, queue a `relation_review` row with the fact as evidence. No
   auto-apply in R1: R2 gives these edges somewhere to go.

Expected size: comparable to 1.92.0 (a row kind, a policy, one compactor step, specs).

### R2. A lifecycle for relations (migration; MCP output change, needs Steve's approval)

- `memory_relations` gains `status` (active / ended), `ended_at`, `ended_reason`, and optionally
  `valid_from` / `valid_until`, mirroring observations.
- An ended relation is kept and audited, hidden from default traversal and search, and shown on
  request (`include_ended` on `traverse_graph` / `get_entities`): "jQuery: used by Goggles until …".
- R1's `relation_review` rows get their apply: end the relation, with the removal fact as the reason.
- Deleting stays available by hand only.
- This is the release with the surface questions: the new parameter, the extra keys on relation
  payloads, and whether `graph_edit` may end a relation. Each needs a yes before a kickoff.

### R3. Discovery by traversal (idea 5), each rule behind a measured approval rate

Candidates, review-only:

- co-mention: two entities named together in facts of a third, several times;
- a class, file or path name of an entity that appears in another entity's facts with no edge between them;
- embedding-near entities of *different* types (same-type nearness already drives merges);
- a two-hop path that implies a missing direct edge.

A rule ships disabled, runs in a "shadow" mode that only counts what it would propose, and is
turned on only when a sample of its proposals is judged right often enough (bar to be set; the
current rules sit near 25%).

### R4. Ranking and noise (ideas 6, 7), each behind a before/after measurement

- Maintain `weight` and `confidence` on relations: set on creation by source (operator, agent,
  policy, discovery), raised when a session used the edge, decayed when nothing does.
- Let search prefer the newest fact among siblings on one keyword path.
- Propose summaries for entities with long fact lists (max is 116 active facts); flag entities with
  no facts, no edges but `part_of` and no recent hits as GC candidates.
- Needs a fixed set of queries on a synthetic graph, scored before and after.

## What stays out

- No relation is deleted automatically in any release above.
- Nothing here weakens the `/mcp` lockdown, the anonymizer or the cloud gate.
- No LLM call is required for R1; an LLM judge for retype evidence can be discussed for R3.

## Answers (Steve, 2026-11-20)

1. A retyped library keeps its project scope, never root level; one used by two projects is a
   dependency of both.
2. Canonicalize relation types on every write path, and give the operator a way to run it over the
   whole graph (the rake task and the Maintenance button above).
3. The dependency-like type list starts from the types in the graph and is editable in Settings.
4. R1 ships as one release.
