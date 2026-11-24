# Plan: every `part_of` writer keeps membership in step

> Status: **PR 1 shipped in 1.93.1** (items 1, 2 and 3, the guard, and the scan, import and backfill
> rules added along the way: see "As built" below). **PR 2 is not started** (1.93.2; its scope is under
> "Order and size"). Steve answered questions 1, 2 and 5 on 2026-11-20 and the rest on 2026-11-24 (see
> "Answers" at the end). Written against `claude/part-of-membership-followup` at
> 9c02208 (1.93.0 plus PR #189). Every gap below was read in the code on that commit; the ones marked
> *probed* were also reproduced on a synthetic graph in the test database. The gap sections below
> describe the code before PR 1, not as it is now.

## Context

`memory_entities.project_id` is derived, not chosen: an entity belongs to the Project its single
`part_of` parent chain reaches, or to none (global). `ProjectMembership` computes it (`sync!`,
`reassign!`, `member_ids`), and names are unique per project scope, so a move can collide.

So any writer that creates, retypes or removes an edge that reads as `part_of` in SQL
(`MemoryRelation.reads_as_part_of?`: `part_of`, `Part_Of`, not `Part Of`), or deletes an entity that
has `part_of` children, must:

1. take the membership lock (`ProjectMembership.with_membership_lock`) **before** its transaction
   (the advisory-first rule in `ProjectMembership::LOCK_NAME_PREFIX`'s comment);
2. for a new or retyped parent edge, pass the create-time rules (`RelationSemantics.validate_create!`:
   one parent, no cycle);
3. sync each affected child (`ProjectMembership.sync!`) in the same transaction, so a
   `ProjectMembership::Collision` rolls the write back.

Already done: `graph_write` and `graph_delete` (lock, rules, sync); `NodeOperationsStrategy`
`move_to_parent` and `delete_node`; the review applies (`create_relation`, `delete_relation`,
`relation_retype`, orphan and reparent moves, and since PR #189 `relation_integrity`); change-set
undo; the import (`ImportExecutionStrategy`, whole run under the lock). 1.93.0 fixed `POST
/api/v1/bulk` and `POST`/`PATCH /api/v1/memory_relations`; PR #189 fixed `DELETE
/api/v1/memory_relations/:id`, the data-exchange retype, delete and duplicate cleanup, and the case
of a stored `Part_Of` in `graph_delete` and the `delete_relation` row. The REST and data-exchange
paths share `RelationMembershipWrite` (`update!`, `destroy!`, `with_lock_if`).

**The symptom** of a missed sync is drift: an entity that keeps a `project_id` although no `part_of`
path leads to that project (it shows in that project's search and scope, and its name blocks the
same name there), or the reverse, an entity under a project's tree that is still global or in
another project. An entity can also end up with two `part_of` parents, which the single-parent rule
forbids and `sync!` then resolves arbitrarily (it picks one edge).

**What repairs drift today.** `ProjectIdBackfill`, run by `bin/rails graph_mem:backfill_project_ids`
(and once by the scope migration), takes the membership lock, walks every Project's tree with
`ProjectMembership.member_ids` (stopping at `reference_stub` edges and nested Projects), stamps every
reachable entity with that Project, and clears `project_id` on every non-Project entity no tree
reaches, all in one transaction. It does **not**:

- remove a second `part_of` parent (an entity two roots reach is reported under "conflicts" and
  stamped with the lower Project id);
- touch edges at all, or delete anything;
- run on a schedule (by hand only);
- resolve a name collision: the first `RecordNotUnique` rolls the whole run back and is reported
  with a hint, one conflict per run;
- count drift in its dry run (`[dry_run]` prints members per project, unrooted and conflicts, and
  "no rows written"; the drift query under Verification gives the counts).

So the backfill is a repair after the fact, not a guarantee; the gaps below should not need it.

## The gaps

Ranked by reach and by how often they can fire.

### 1. Deleting an entity leaves its children's project behind (verified, *probed*; fixed in 1.93.1)

`MemoryEntity has_many :relations_to, dependent: :destroy`, so destroying an entity deletes its
children's `part_of` edges, and nothing syncs the children: each keeps the deleted entity's project
while no path reaches it. (A Project root with members can't be deleted at all:
`has_many :members, dependent: :restrict_with_error`, so the case is a non-Project middle entity.)

| Path | How it is reached | Lock | Sync |
|---|---|---|---|
| `Api::V1::MemoryEntitiesController#destroy` | REST `DELETE /api/v1/memory_entities/:id` | no | no |
| `GraphDeleteService#delete_entity` | MCP `graph_delete` | yes (`call` / `execute_one`) | no |
| `CompactionReviewApplier#delete_entity` | a `delete_entity` review row (Review & Fix, `apply_maintenance_review`) | yes (`CompactionReviewService.apply`) | no |
| `NodeOperationsStrategy#delete_node` | data exchange `DELETE /data_exchange/delete_node` | yes | **yes** (the model) |

`delete_node` (non-cascade) collects the children of its `part_of` edges, destroys those edges,
syncs each child, then destroys the node, all inside the lock and one transaction. The comment in
`compaction_review_service/queries.rb` (`delete_children_info`) says a `delete_entity` row leaves
children parentless on purpose; it is silent about `project_id`, and the intent there is "not
deleted", not "kept in the project".

**Intended behaviour (Steve, 2026-11-20):** the children move **one level up, under the deleted
entity's own parent**, with their subtrees. They stay in the same project, so no name can collide.
Only when the deleted entity had no parent do they become global, and then a name already taken
at global scope refuses the delete with nothing changed. This changes `delete_node` too: today it
makes the children global even when the deleted entity had a parent.

**Fix:** one helper used by all four, e.g. `RelationMembershipWrite.destroy_entity!(entity, reason:)`
(lock if the entity has `part_of` children; in one transaction: note the children and the
entity's parent, destroy the entity, then give each child a `part_of` edge to that parent through
the validating create path, or none when there was no parent, and sync each child), and
`delete_node`'s non-cascade branch moved onto it. The new edges and the deleted ones are in the
same change set, so undo puts the entity back between them. The previews (`graph_delete` dry run,
the review row, the data-exchange dialog) say where the children go. The REST destroy
gains the lock; `graph_delete` and the review apply are already under it (the lock is reentrant).
A collision answers each path's existing error: REST 422 (DELETE on `memory_entities` documents
`204` and `404` only, so this adds a documented `422`, like PR #189 did for relations),
`graph_delete` its validation `OperationFailed` (`GraphDeleteService.membership_collision_error`
exists), the review row its failure reason. **Size:** about 90 lines of code, 160 of specs.

**Spec:** Project ← mid ← leaf (leaf under mid, mid under the Project); delete mid through each of
the four paths; leaf is then `part_of` the Project and keeps its `project_id`; undo restores mid
between them. A second case with mid parentless: leaf's `project_id` becomes NULL, and with a
global entity named like the leaf each path refuses and nothing is deleted.

### 2. Entity merge can leave the target with two parents (changed: a real gap, but not the one described; fixed in 1.93.1)

The suspected case is fine. When the target was `part_of` the source, `merge_locked!` first
re-points the source's own outgoing edges to the target (`reassign_outgoing_relations!`, so the
target gains the source's parent), then deletes the edges running directly between the two; the
target ends with the source's parent, which reaches the project it already had. *Probed*: no drift.

The real gap is in `reassign_outgoing_relations!`: it re-points every outgoing edge of the source
with `update!(from_entity_id: target_id)` (no create-time rules, no sync), including the source's
`part_of`. *Probed:* merging a source under project P1 into a target under P2 leaves the target
with **two** `part_of` parents (P1 and P2) and its project still P2. When the target had no parent,
it gains the source's and is not synced (its project stays NULL while its path reaches P1; by
reading, not probed). Reached from MCP `graph_delete` `merge_entities`, Explore's merge, REST
`POST /api/v1/memory_entities/:id/merge_into/:target_id`, data exchange `merge_node`, a review
`entity_merge` row, the redo of an undone merge, and dream-state auto-merge (nightly, unattended).

**The rule (Steve, 2026-11-20), for operator and agent merges alike:** the target keeps its own
relationships, and everything that hung on the source moves to the target, all of it. That is
already what the code does for the source's children (`reassign_incoming_relations!` re-points
each `part_of` child to the target and syncs it; checked on 2026-11-20) and for the target's own
edges. The one place it breaks is the source's own parent edge, below. PR 1 adds a spec that pins
the whole rule: every child of the source ends under the target, in the target's project, and no
relation of the target is lost.

**Fix:** in `reassign_outgoing_relations!`, a source edge that reads as `part_of` is dropped when the
target already has a parent (the target keeps its own; the dropped edge is in the merge snapshot,
so undo restores it), and re-pointed then synced when it has none; the merge preview says which.
**Size:** about 30 lines, 60 of specs. **Spec:** the two probed cases above, and a merge undo that
restores both edges.

### 3. "Repair relation duplicates" deletes parents without a sync (changed: not the nightly path; fixed in 1.93.1)

`RelationIntegrityRepairer#delete_relation_ids` destroys relations with no lock and no sync. The
unattended callers (`GraphIntegrityService`, run as the dream-state pre-flight and by the nightly
garbage collection) use `review_ambiguous: true`: they delete only same-direction duplicates, which
the unique key `(from_entity_id, to_entity_id, relation_type)` (compared by the column's collation)
makes impossible, and queue reverse pairs and merge collisions as `relation_integrity` review rows,
whose apply syncs since PR #189. So the nightly path deletes no `part_of` today.

The operator's **Repair relation duplicates** button on System › Background jobs
(`System::JobsController#repair_relations`, shown when a compaction run failed) calls it with
`review_ambiguous: false`: it deletes the extra parents of every merge collision and the newer edge
of every reverse pair, `part_of` ones included, without the lock or a sync, so each child keeps the
project of the parent that was removed.

**Fix:** `RelationIntegrityRepairer#call` takes the membership lock before its writes when anything
it will delete reads as `part_of`, deletes in one transaction, and syncs the children of deleted
`part_of` edges (a collision rolls the repair back and the notice says so). **Size:** about 40
lines, 60 of specs. **Rank:** second, after item 1: an operator action, rare, but it fires on
exactly the graphs that are already inconsistent.

**Spec:** a child with two `part_of` parents (the second written with `update_column`) and the
child's project on the second; the button's call keeps the first, deletes the second and the child
moves to the first parent's project; with a name taken there, nothing is deleted.

### 4. Project scan validation deletes a wrong-root `part_of` without a sync (verified; PR 2)

`ProjectScanValidator#validate_entity_relations` deletes a `part_of` from an entity of the scanned
project to another Project root (`wrong_part_of_to_project_root?`) through `#delete_relation`: no
lock, no sync, outside any transaction, one relation at a time. Reached by every project scan with
validation on (`ProjectScanJob`, the UI scan, `scan_project`), batched across jobs.

The child keeps the wrong Project's `project_id` while no path leads there any more; nothing in the
validator syncs it afterwards.

**Fix:** delete through `RelationMembershipWrite.destroy!` (lock, delete, sync; a collision is
recorded in the validator's `@errors`, as other failures are). **Size:** about 10 lines, 40 of specs.
**Spec:** an entity of the scanned project that is `part_of` another Project root; after validation
it no longer has that edge and its `project_id` is not that Project's.

### 5. The code-map skeleton's containment edges (verified safe)

`ProjectScanner::SkeletonWriter#ensure_parent` creates `part_of` the scan root through
`#create_relation`, with no sync, inside the reconcile transaction. It is safe: every entity it
handles is found or created with `project_id: @root.id` (`find_by(name:, project_id: @root.id)` or
`create!(… project_id: @root.id)`), the root is the Project itself, and the edge is created only
when the entity has no parent yet, so the new edge's derived project equals the stored one. No fix;
a comment in `ensure_parent` should say why no sync is needed.

### 6. Rake tasks (PR 2; verified; namespaces corrected: `data:` in `lib/tasks/memory_data.rake`, `tools:` in `lib/tasks/memory_graph_utilities.rake`)

- `data:migrate_json` and `data:append_json` create relations with
  `MemoryRelation.new(...).save` (validated, no lock, no sync). The JSON Lines files they read carry
  `part_of` edges.
- `data:merge_entity` re-points every relation of the source with
  `update_all(from_entity_id:)` / `update_all(to_entity_id:)` (no validation, no audit, no sync,
  duplicates fail the transaction), then destroys the source: the same two-parent and stale-project
  results as item 2, without an audit trail or undo.
- `tools:create_relation` (`lib/tasks/memory_graph_utilities.rake`) creates one relation with `create!` (validated, no lock, no sync).

They are run by hand only. **Fix:** `merge_entity` calls `NodeOperationsStrategy#merge_into` (so it
gets the snapshot, the audit and undo, and item 2's fix); `create_relation` calls
`GraphWriteService.execute_one("create_relation", …)`; the two JSON tasks run under the lock and
call `ProjectIdBackfill` at the end (simpler than a sync per edge, and they already rewrite the
graph in bulk). **Size:** about 40 lines, 60 of specs.

### 7. Scan writers sync inside a transaction (changed: one of the two is a real ordering problem; PR 2)

- `ProjectScanner#reconcile_relation` creates a `part_of` and calls `ProjectMembership.sync!` inside
  `#reconcile`'s `ActiveRecord::Base.transaction`, with no lock taken first. `sync!` → `reassign!`
  then takes the advisory lock **inside** the transaction, the order the lock comment says deadlocks
  against the backfill. Also, a `Collision` is rescued inside the transaction and recorded, so the
  edge stays and the child keeps its old project.
- `ProjectScanSkill#ensure_part_of` runs outside any transaction (the guided scan has none), so its
  `sync!` taking the lock itself is in the right order. Its create and its sync are separate
  statements: a `Collision` is recorded and the edge stays, with the stale project.

**Fix:** `ProjectScanner` takes the membership lock around `#reconcile` (before its transaction),
like the import does; on a `Collision` both scanners delete the edge they just created (or create
it in a savepoint that the collision rolls back) and record the conflict. **Size:** about 30 lines,
60 of specs. The hoist holds the lock for the whole reconcile, which includes its inline LLM word
batches, so other membership writers (graph_write, merges, imports) wait that long: measure the hold
time on a scan profile run before deciding, and fall back to a per-relation savepoint plus one
`sync!` per child after the transaction if it is too long.

## A guard so this stops recurring

Three options, none built:

1. **A static spec** that greps `app/` and `lib/` for `MemoryRelation` writers (`create`, `save`,
   `update`, `destroy`, `delete`, `update_all`, `insert_all`, `relation_type` assignments) and fails
   on any file not in an allow-list of known-correct writers. Cheap and fast, but it can't see
   indirect writers (`dependent: :destroy` on `MemoryEntity`, which is gap 1), a grep has false
   positives, and the allow-list rots into "add the file to make it pass".
2. **A model callback in the test environment** that records every `part_of` create, destroy or
   retype (by `reads_as_part_of?`) and an `after` hook that fails the example unless the child was
   synced in the same transaction. Catches indirect writers, but it needs to tell "synced" from
   "nothing to change" (a sync that changes no row) and couples the spec suite to the
   implementation of `sync!`.
3. **An invariant check after each example**: the drift query below (no entity whose `project_id`
   differs from what its `part_of` chain gives, no entity with two `part_of` parents), run in an
   `after` hook for request, service, strategy, job and integration specs, with an opt-out tag for
   the few examples that build drift on purpose (`update_column`). It catches every writer, direct
   or not, and checks the outcome rather than the mechanism. Cost: a handful of queries per example
   on a small test graph (to be measured; the suite runs about 4,900 examples).

**Recommendation: option 3**, with option 1's grep kept as a report (not a failure) in the plan's
verification. The invariant is what matters to an agent's search; how a writer gets there doesn't.

## Order and size

| PR | Scope | Version | State |
|---|---|---|---|
| PR 1 | Items 1, 2 and 3, the guard (option 3), plus the scan, import and backfill rules ("As built") | 1.93.1 | shipped |
| PR 2 | Items 4, 6 and 7, the comment for item 5, and the notes under "PR 2 scope" | 1.93.2 | not started |

The mcp 1.11.0 bump (`mcp-sdk-1.11.0-plan.md`) is now 1.93.3 and the vector search steps 0 and 1
(`mariadb-vector-search-plan.md`) 1.93.4; the minors (1.94.0 and later) are unchanged.

### As built (PR 1, 1.93.1)

What differs from the plan above:

- **Entity deletes were never undoable.** The plan said the new edges and the deleted ones are in
  the same change set, so undo puts the entity back between them. That line was wrong: an entity
  delete is `hard_delete` (`ChangeSet` strategy `none`), before and after. The review preview still
  says "Can't be undone".
- **The helper is `RelationMembershipWrite.destroy_entity!`** (`RelationMembershipWrite::EntityDelete`),
  as proposed, with a read-only `plan` the previews use. A `reference_stub` park edge is not
  ownership: a parked stub child is not moved. `graph_delete`'s `summary.relations_deleted` is a row
  count delta, so it is net of the re-parent edges the delete creates. The REST destroy documents a
  `422` (name collision, busy lock, and a Project root that still has members, which was a `500`).
- **Merge** (item 2): `target_takes_parent?` decides between dropping the source's parent edge and
  re-pointing it (a cycle also drops it). Explore's dialog and the review preview say which
  (`parent_edge`), including the target's own project move; undo syncs the target too. A collision is
  a `422` on REST `merge_into` and in Explore, and a failure reason on a review row (applied in a
  savepoint).
- **Relation repair** (item 3): the button takes the lock, finds the issues under it and syncs each
  child; a collision rolls everything back ("Relation repair refused, nothing was deleted"). The
  nightly path is pinned by a spec: it deletes no `part_of`.
- **Scan rule, added after the guard exposed it.** Every entity a scan reconciles was stamped into
  the project but got a `part_of` only when the model emitted one, so scans left entities in a
  project's scope with no path to its root. `ProjectScanner::Containment` now gives each reconciled
  entity still without a parent a `part_of` to the root (marked, counted in `relations_created`, no
  lock: the stamp is already the root). The rescan's validation reaches those entities too. The scan
  profile's `isolated_entities` and `root_only_entities` read the model's relations only.
- **Import rule, added after the guard exposed it.** The import stamped every declared node of the
  tree into the import's project whatever its tree edge, so a `depends_on` child (which exports put
  in the tree) sat in the project with no `part_of` path. Now only a node a child-to-parent `part_of`
  chain links to the import's root Project is created and matched in the project; every other
  declared node is global, like a reference node (`ImportEntityResolver.contained_child?`, shared
  by the executor and `ImportMatchingStrategy`).
- **The backfill repairs toward the stamp, added after the guard exposed it.** `ProjectIdBackfill`
  cleared every stamp no path backs. Now a stamp whose owned `part_of` chain is stamped consistently
  gets its chain's top attached to that project's root (one change set, `maintenance.membership_repair`,
  undoable), and only the rest are cleared. `ProjectIdBackfill.drift` is the one drift report: the
  backfill prints it, the migration logs it and the guard uses it.
- **A data migration was added** (`20261124120000_repair_memory_entity_project_ids.rb`): approved by
  Steve (answer 6). It runs the repair once at `db:prepare`, logs the drift before and after, never
  fails the deploy (a collision or a busy lock skips with a hint) and its `down` does nothing. The
  plan had said "no migration"; it is data only, with no schema change.
- **The guard's scope and cost.** Option 3, on every example except system specs, as a group-level
  `around` hook inside the fixture transaction (it records the failure instead of raising, so the
  rollback still happens), opt-out `membership_drift: :allowed`. Measured overhead: about 2% of the
  suite. About 100 spec files changed, most of them rebuilt on `fs_member!` to build consistent data.
- **Release.** A patch release of its own, 1.93.1, carrying PR #189's entries (answer 3).

### PR 2 scope (1.93.2)

Items 4 and 7 as written, item 6 (the rake tasks), the comment for item 5, plus two notes found
while building PR 1:

- **Dream-state auto-merge takes the membership lock inside a transaction.**
  `DreamStateCompactor` runs each entity in `ActiveRecord::Base.transaction(requires_new: true)`, and
  the merge inside it takes the lock, the order the lock comment says deadlocks against the backfill.
  Take the lock around the per-entity work, before its transaction (or around the merge phase), and
  measure the hold time.
- **`GraphIntegrityService#repair_dangling_relations` could delete a `part_of` without a sync** when
  foreign key checks are off: it deletes relations whose endpoint is gone, so the surviving child of
  such an edge keeps its project. Route it through `RelationMembershipWrite.destroy!`, or sync the
  child, and add a spec.

About 120 lines of code and 200 of specs for items 4, 6 and 7, plus a scan-profile run to measure
the reconcile lock hold time.

MCP surface unchanged in PR 1: no tool, parameter, schema or description changes; `graph_delete`'s
result for an entity delete keeps its keys (the children's new scope is not reported). REST:
`DELETE /api/v1/memory_entities/:id` gained a documented `422` (swagger edited by hand, as in PR #189).

## Verification

Synthetic scenarios (each in the specs, and once on a development copy):

- Project ← mid ← leaf, delete mid through REST, `graph_delete`, a `delete_entity` review row and
  data exchange `delete_node`: leaf is `part_of` the Project afterwards and keeps its project. With
  mid parentless instead, leaf is global; with a global entity named like leaf, every path refuses
  and nothing is deleted.
- Two entities under different Projects, merged (MCP, Explore, review row, dream-state auto-merge):
  the target keeps one parent, its own; undo restores the source and both edges.
- A child with two `part_of` parents repaired by the **Repair relation duplicates** button: one
  parent left, the child in that parent's project.
- A scan that removes a wrong-root `part_of`: the child leaves the other Project.

Read-only drift count, to run before and after (counts only; it reads with the same walk the
backfill uses and writes nothing):

```bash
bin/rails runner '
expected = {}
MemoryEntity.where(entity_type: "Project").order(:id).pluck(:id).each do |project_id|
  ProjectMembership.member_ids(project_id).each { |id| expected[id] ||= project_id }
end
stored = MemoryEntity.where.not(entity_type: "Project").pluck(:id, :project_id)
puts({
  entities: stored.size,
  wrong_project: stored.count { |id, project_id| project_id && expected[id] && project_id != expected[id] },
  stamped_without_path: stored.count { |id, project_id| project_id && !expected.key?(id) },
  path_without_stamp: stored.count { |id, project_id| project_id.nil? && expected.key?(id) },
  several_parents: MemoryRelation.where(relation_type: "part_of").group(:from_entity_id).having("COUNT(*) > 1").count.size
}.inspect)
'
```

`expected` keeps the lower Project id when two roots reach an entity, as the backfill does, so
`wrong_project` matches what the backfill would change; `several_parents` counts entities with more
than one `part_of` edge (the relation type is compared by the column's collation, so `Part_Of`
counts). Checked on a synthetic graph with one case of each kind: it reported 1, 1 and 1 for
`stamped_without_path`, `path_without_stamp` and `several_parents`, and issued no write.

## Open questions for Steve

None open for PR 1: questions 3, 4 and 6 were answered on 2026-11-24 (see "Answers"). PR 2's kickoff
may add its own.

## Answers

### Steve, 2026-11-20

1. **Children of a deleted entity** move under the deleted entity's parent (item 1).
2. **Merging:** the target keeps its relationships and all of the source's children move to the
   target, for agent-initiated merges too (item 2). The current code was checked against this.
5. **Existing drift:** the backfill runs automatically after PR 1. PR 1 records the drift count
   before and after in its run output.

### Steve, 2026-11-24

3. **Release:** "bump version as needed, we can retarget subsequent releases accordingly". The
   numbers were then chosen in the session: PR 1 ships with PR #189's entries as 1.93.1, PR 2 as
   1.93.2, and the mcp 1.11.0 bump and the vector search steps move to 1.93.3 and 1.93.4.
4. **The guard:** Steve left its scope to the implementer. Decided in the session: the invariant
   check runs after every example except system specs, to be narrowed to request, service,
   strategy, job and tool specs only if it cost more than 5% of suite time (measured: about 2%).
6. **How the backfill runs by itself:** a data migration, approved.
Answers 7 to 9 are the options Steve chose when the guard exposed the scan and import writers:

7. **Scans:** every entity a scan reconciles that the model left without a parent gets a containment
   `part_of` to the project root.
8. **Imports:** an import follows the `part_of` edges to decide scope. Only nodes linked to the
   import's root Project by a child-to-parent `part_of` chain are created in, and matched by name in,
   the import's project. Every other declared node is treated like a reference node: global,
   matched by name globally, and created global when absent. That covers a `depends_on` child
   (which exports place in the tree), anything below it, and any root node after the first. Such a
   node now merges into an existing same-named global entity instead of getting a project-scoped
   copy, and the preview (`ImportMatchingStrategy`) matches what the import writes.
9. **The backfill repairs toward the stamp** when a consistently stamped chain's top has no parent,
   and clears the stamp otherwise.
