# Plan: Dream State as knowledge traversal (relations first)

> Status: draft for Steve's review, 2026-11-20, written on `main` at 1.92.0. Not started.
> No code in this PR. Each release below gets its own kickoff once the plan is approved.

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

Not measured: how many `part_of` edges phase 1 created. Relation audit rows carry no dream-state
actor to tell (87 creations in the audit window have an empty actor). Release 1 fixes that first.

## Releases

### R1. Relations: vocabulary and retyping (no migration, no MCP change)

1. **Canonical types for existing relations** (new idea 0, from the measurements).
   - A dream-state step runs every relation's type through `RelationTypeMapping.canonicalize`.
   - A row whose canonical type differs is retyped in place; when the canonical twin already exists
     (the unique index on from, to, type), the variant row is merged into it.
   - A type with no mapping and no vocabulary entry is counted in the run's stats and listed once in
     a report for the operator, who adds a mapping or accepts the type. Nothing is guessed.
   - Open point for Steve: canonicalize the same way on **every** write path (`graph_write`
     included). That changes what a write stores for a variant type, so it may count as MCP
     behaviour; the stored type would still be what `GraphVocabulary` documents.
2. **Retype `part_of` on dependency-like children** (ideas 1, 3).
   - Candidate: a `part_of` edge whose child has a dependency-like entity type (a configurable
     list, starting with the framework, library, gem, tool and external-service types) and whose
     parent is a Project.
   - Proposal: a new review row kind `relation_retype` (`part_of` → `depends_on`), with the
     evidence shown: the child's type, and any fact that says the project uses or used it.
   - **Project scoping is kept**: `part_of` is the ownership edge and sets `project_id`. Two ways,
     for Steve to pick:
     (a) the retyped entity keeps its `project_id` (scoped to the project it was learned in) and
     only the edge changes; or
     (b) it becomes global (`project_id` NULL), since a library isn't owned by one project.
     The plan recommends (a): nothing moves in search scoping, and (b) can follow per entity.
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

## Questions for Steve before the R1 kickoff

1. Retyped libraries: keep their `project_id` (recommended) or become global?
2. Canonicalize relation types on every write path, `graph_write` included?
3. The dependency-like type list: start from the types seen in the graph, editable in Settings?
4. Is R1's scope right for one release, or should the vocabulary sweep (item 1) ship alone first?
