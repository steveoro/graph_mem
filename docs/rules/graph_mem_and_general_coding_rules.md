---
description: GraphMem MCP usage (Knowledge Graph) and general coding rules
globs:
alwaysApply: true
---

### Graph Memory — 4-Phase Session Workflow

Use the `graph_mem` MCP tools every session. "Knowledge graph", "graph mem", and
"memory graph" all refer to the same toolset. Treat this workflow as session
state management, not as a substitute for inspecting the repository.

**Phase 1 — Orient** (start of every conversation)
1. Say "Remembering..." then call `get_context` to check for an active project. Context is per-agent and persisted, so you may already have one from a prior session.
2. If no context: `search_entities` for the relevant project name → `set_context(<ID or entity name from search result>)`.
3. If no project entity exists yet: `create_entity` (type `Project`) → `set_context(<new entity ID or name>)`.
4. Optionally call `dream_state_status` for a cheap health check (whether background compaction is running/paused).

**Phase 2 — Recall** (before doing work)
- `search_entities` or `search_subgraph` with keywords from the user's request.
- Drill into hits: `get_entity` for details, `get_subgraph_by_ids` for a cluster of related entities.
- After locating a root entity, use `traverse_graph` for a bounded multi-hop neighborhood or `find_shortest_path` to explain how two entities connect.
- Look for prior `Issue`/`PossibleSolution` pairs, `BestPractice`, and `Preference` entities.
- Use `summarize` when the goal is to answer “what does the graph know about
  X?”; use search and traversal directly when exact records or relationships
  are required.

**Phase 3 — Work**
- Execute the user's request using recalled context.
- Consult the graph mid-task if you encounter related issues or need prior solutions.

**Phase 4 — Persist** (before ending)
- `create_observation` for new facts on existing entities. Write dedupe-aware: search/get the entity first and append only new facts rather than re-stating existing ones.
- `update_observation` for corrections. Use `supersede: true` when preserving
  the prior fact/version matters; use `delete_observation` to mark a fact
  obsolete rather than hard-delete it.
- Treat active observations as the default truth surface. Request
  `include_obsolete: true` only when historical or superseded versions are
  relevant.
- `create_entity` + `create_relation` for new concepts discovered.
- Use `bulk_update` to batch multiple writes in one call (max 50 ops).
- `clear_context` if the project scope is no longer relevant (safe: affects only your own client bucket).
- Routine duplicate compaction is handled by the background dream-state job. When you *spot* duplicates during work, confirm with `suggest_merges`, then execute with `merge_entities(source_entity_id, target_entity_id)`.

---

### Tool Quick-Reference

| Phase | Tools |
|-------|-------|
| Orient | `get_context`, `set_context`, `clear_context`, `search_entities` |
| Recall | `search_entities`, `search_subgraph`, `get_entity`, `get_subgraph_by_ids`, `summarize`, `list_entities` |
| Traverse | `find_relations`, `traverse_graph`, `find_shortest_path` |
| Persist | `create_entity`, `update_entity`, `delete_entity`, `create_observation`, `update_observation`, `delete_observation`, `create_relation`, `delete_relation`, `bulk_update` |
| Maintain | `suggest_merges`, `merge_entities`, `dream_state_status`, `get_maintenance_reports`, `get_graph_stats`, `get_version`, `get_current_time`, `scan_project`, `scan_project_status` |

### Multi-Agent Context Scoping

- Context is **per-agent**, keyed by the `X-MCP-Client` header, and persisted in the DB (survives restarts).
- `set_context` / `clear_context` affect ONLY your own client bucket — they never disturb other agents sharing the graph.
- Agents without the header share the `"default"` bucket. Set a stable `X-MCP-Client` in your MCP config when multiple agents use one instance.
- Because context persists, on Orient you may already have an active context from a prior session — always `get_context` first before assuming none.

### Project Scan Validation

- `scan_project(project_root, project_name, aliases, mode, dry_run, file_globs)` starts an
  asynchronous source-scan of a project root. It treats the files as the source of truth,
  reconciles the graph, and then runs an automatic facts-checking pass over the existing
  project subtree.
- The final validation pass is implemented in the `ProjectScanValidator` service and
  is gated by `enable_project_scan_validation`.
- It distinguishes scan-sourced observations from manually-created ones:
  - Scan-sourced observations (`source` starts with `project_scan:` or
    `project_scan_skill:` from a prior run) can be moved or obsoleted automatically.
  - Manual/sourceless observations are never silently deleted. They are queued as
    `move_observation` or `delete_observation` `scan_review` items so the
    operator/agent can decide; the scan conclusion is preserved in the review payload.
- Skips entities, observations, and relations created during the same scan run
  (identified by the per-run source ref `project_scan:<scan_id>:<phase>` and
  `MemoryRelation#properties["scan_id"]`).
- Moves scan-sourced observations to a better-matching target entity when the target
  is unambiguous (the target name/alias appears as a whole word or phrase in the
  observation text and the text does not reference its current entity or project).
- Marks scan-sourced observations that do not reference their entity or project and
  have no clear target as `obsolete` with `confidence: 1.0`.
- Handles relation ownership semantics:
  - `part_of` is an ownership edge: a `MemoryEntity` may have only one `part_of`
    parent. A `part_of` relation to the wrong `Project` root is corrupt and is
    auto-deleted.
  - `used_by`, `depends_on`, `requires`, `configured_by`, `implements`, `extends`,
    and `integrates_with` are reference/usage edges. Stale ones are queued as
    `delete_relation` review items, not auto-deleted.
- Queues stale usage relations (`delete_relation`), entities that no longer appear
  in the source (`delete_entity`), observations that do not belong (`delete_observation`),
  and wrong-parent moves (`reparent_entity`, `move_observation`) as `scan_review`
  maintenance rows.
- Use `mode: "validate"` to run only the validation pass on an existing project
  without re-reading files.
- Agents can consume `scan_review` rows via `get_maintenance_reports(report_type:
  "scan_review")` and apply `move_observation`, `reparent_entity`, `delete_relation`,
  `delete_observation`, or `delete_entity` actions just like compaction reviews.

### Dream-State Compaction Awareness

- A background "dream-state" job periodically compacts the graph: it
  auto-parents orphans, auto-merges near-identical entities (cosine distance <
  0.10, same `entity_type` only), and deletes byte-identical duplicate
  observations. Lower-confidence cases are queued for review.
- Call `dream_state_status` to see whether compaction is `running`/`paused` plus its progress/stats.
- Call `get_maintenance_reports(report_type: "compaction_review")` to read the queue of merge/orphan suggestions the job flagged for review, then action good ones with `merge_entities`.
- Mutating tools cooperatively pause compaction automatically — no action needed, but search results may shift slightly while a run is in progress.
- Implication for writes: don't rely on the job to clean up sloppiness. Prefer
  `create_observation` on an existing entity or `update_entity` over creating
  near-duplicates. Mutating tools may pause compaction, so do not assume that
  maintenance state is unchanged during a session.

### Standard Compatibility

graph_mem accepts both its native snake_case/ID-based parameters and the
`@modelcontextprotocol/server-memory` camelCase/name-based conventions:
- Entity references accept either `entity_id` (integer) or entity name (string).
- Traversal references (`start_entity_id`, `from_entity_id`, `to_entity_id`) also accept entity IDs or names.
- Field names accept camelCase (e.g. `entityType`) or snake_case (`entity_type`).
- `bulk_update` accepts either three arrays (`entities`, `observations`, `relations`) or a single `operations` array with `type`-discriminated items.
- Observation text accepts `text_content`, `content`, or `contents` (array).
- Relation endpoints accept `from_entity_id`/`to_entity_id` (int), `from`/`to` (name), or `from_entity`/`to_entity` (name).
- Use native snake_case keys by default. Compatibility aliases are for
  interoperating clients, not a reason to mix naming styles in one request.

### Query Strategy
- **Search before create** to avoid duplicates (vector dedup catches some, not all).
- **Start broad, then narrow** using entity IDs from search results.
- **Prioritize root nodes**: find the `Project` first, then traverse its relations.
- **Use `find_relations` for one hop** when you need the immediate incoming or outgoing edges of an entity.
- **Use `traverse_graph` for bounded exploration** instead of chaining repeated
  one-hop calls. Keep `max_depth` and `max_entities` as small as the task
  permits; narrow with `direction` and canonical `relation_types`.
- **Use `find_shortest_path` for connectivity questions**. It returns the shortest unweighted path by hop count within `max_depth`; `found: false` means no matching path was found inside that bound.
- Context scoping boosts entities related to the active project; it does not
  make unrelated entities impossible to return. Do not describe a context-aware
  search as a hard project filter unless the API explicitly guarantees that.
- **Navigate by graph structure** (`find_relations`, `traverse_graph`, `find_shortest_path`, `get_entity`) instead of repeated searches after locating the relevant entities.

### Entity Types
`Project`, `Framework`, `ApplicationStack`, `Workflow`, `BestPractice`, `Task`, `Step`, `Issue`, `Error`, `PossibleSolution`, `Model`, `DatabaseTable`, `Class`, `APIEndpoint`, `Route`, `Component`, `Service`, `Configuration`, `Migration`, `TestCase`, `Permission`, `User`, `Preference`.

### Relation Types (use the most specific)
`depends_on`, `part_of`, `relates_to`, `implements`, `extends`, `solves`, `configured_by`, `tested_by`, `migrated_by`, `authorizes`, `integrates_with`, `replaces`.

### Observations
- Keep observations **crisp and factual**; include timestamps and code paths where relevant.
- For longform content, write to `/docs` and store the file path as an observation.
- Keep generated summaries ephemeral unless persistence is explicitly requested.
  `summarize` always derives evidence from the current active graph and returns
  source entity/observation IDs; never treat IDs or claims emitted by an LLM as
  authoritative.
- The deterministic evidence path is authoritative and always available.
  LLM synthesis is optional; provider failure, missing configuration, or a
  disabled feature must degrade to deterministic output without exposing
  credentials or internal exception details.

### Conflict Handling
1. Note the conflict as an observation on the relevant entity.
2. Research (graph history / web / user) to resolve.
3. Update the graph: new observations, mark outdated ones, edit entity if needed.
4. Record the resolution; inform the user if open questions remain.

---

### Core Coding Rules

- **Schema first**: DB schema is the primary source of truth for data structure.
- **Know your context**: Verify project folder and development environment, runtime target, and containers before running commands.
  Example: most workspaces include more than one project root, each with its own dev stack and languages. Focus on the target project, look for relevant files in the project root that might include target versions of the dev stack in use. (E.g: `.versions.conf`, `.ruby-version`, `docker-compose.yml`, `Gemfile`, `package.json`, `.rvmrc`, ...)
- **Keep it simple**: Prefer straightforward solutions and small, testable units.
- **Test like production**: Real instances over doubles; randomize factories; no fake data in dev/prod.
- **Don't sprawl**: Touch only code relevant to the task; avoid architecture shifts unless asked.
- **Refactor early**: Split files >500 lines or functions >60 lines.
- **Evolve, don't fork**: Fix within current patterns before introducing new tech; remove old impls if replaced.
- **Document**: Record critical changes; remove one-off helpers once used.
