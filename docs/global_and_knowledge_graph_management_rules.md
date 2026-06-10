---
description: General coding rules and graph_mem MCP usage (Knowledge Graph)
globs:
alwaysApply: true
---
### Core Rules

- **Schema first**: DB schema is the primary source of truth for data structure.
- **Know your context**: Verify project folder and development environment, runtime target, and containers before running commands.
  Example: most workspaces include more than one project root, each with its own dev stack and languages. Focus on the target project, look for relevant files in the project root that might include target versions of the dev stack in use. (E.g: `.versions.conf`, `.ruby-version`, `docker-compose.yml`, `Gemfile`, `package.json`, `.rvmrc`, ...)
- **Keep it simple**: Prefer straightforward solutions and small, testable units.
- **Test like production**: Real instances over doubles; randomize factories; no fake data in dev/prod.
- **Don't sprawl**: Touch only code relevant to the task; avoid architecture shifts unless asked.
- **Refactor early**: Split files >500 lines or functions >60 lines.
- **Evolve, don't fork**: Fix within current patterns before introducing new tech; remove old impls if replaced.
- **Document**: Record critical changes; remove one-off helpers once used.

---

### Graph Memory — 4-Phase Session Workflow

Use the `graph_mem` MCP tools every session. "Knowledge graph", "graph mem", "memory graph" all refer to the same toolset.

**Phase 1 — Orient** (start of every conversation)
1. Say "Remembering..." then call `get_context` to check for an active project. Context is per-agent and persisted, so you may already have one from a prior session.
2. If no context: `search_entities` for the relevant project name → `set_context(<ID or entity name from search result>)`.
3. If no project entity exists yet: `create_entity` (type `Project`) → `set_context(<new entity ID or name>)`.
4. Optionally call `dream_state_status` for a cheap health check (whether background compaction is running/paused).

**Phase 2 — Recall** (before doing work)
- `search_entities` or `search_subgraph` with keywords from the user's request.
- Drill into hits: `get_entity` for details, `get_subgraph_by_ids` for a cluster of related entities.
- Look for prior `Issue`/`PossibleSolution` pairs, `BestPractice`, and `Preference` entities.

**Phase 3 — Work**
- Execute the user's request using recalled context.
- Consult the graph mid-task if you encounter related issues or need prior solutions.

**Phase 4 — Persist** (before ending)
- `create_observation` for new facts on existing entities. Write dedupe-aware: search/get the entity first and append only new facts rather than re-stating existing ones.
- `create_entity` + `create_relation` for new concepts discovered.
- Use `bulk_update` to batch multiple writes in one call (max 50 ops).
- `clear_context` if the project scope is no longer relevant (safe: affects only your own client bucket).
- Routine duplicate compaction is handled by the background dream-state job. When you *spot* duplicates during work, confirm with `suggest_merges`, then execute with `merge_entities(source_entity_id, target_entity_id)`.

---

### Tool Quick-Reference

| Phase | Tools |
|-------|-------|
| Orient | `get_context`, `set_context`, `clear_context`, `search_entities` |
| Recall | `search_entities`, `search_subgraph`, `get_entity`, `get_subgraph_by_ids`, `list_entities` |
| Persist | `create_entity`, `update_entity`, `delete_entity`, `create_observation`, `delete_observation`, `create_relation`, `find_relations`, `delete_relation`, `bulk_update` |
| Maintain | `suggest_merges`, `merge_entities`, `dream_state_status`, `get_maintenance_reports`, `get_graph_stats`, `get_version`, `get_current_time` |

### Multi-Agent Context Scoping

- Context is **per-agent**, keyed by the `X-MCP-Client` header, and persisted in the DB (survives restarts).
- `set_context` / `clear_context` affect ONLY your own client bucket — they never disturb other agents sharing the graph.
- Agents without the header share the `"default"` bucket. Set a stable `X-MCP-Client` in your MCP config when multiple agents use one instance.
- Because context persists, on Orient you may already have an active context from a prior session — always `get_context` first before assuming none.

### Dream-State Compaction Awareness

- A background "dream-state" job periodically compacts the graph: it auto-parents orphans, auto-merges near-identical entities (cosine distance < 0.10), and deletes byte-identical duplicate observations. Lower-confidence cases are queued for review.
- Call `dream_state_status` to see whether compaction is `running`/`paused` plus its progress/stats.
- Call `get_maintenance_reports(report_type: "compaction_review")` to read the queue of merge/orphan suggestions the job flagged for review, then action good ones with `merge_entities`.
- Mutating tools cooperatively pause compaction automatically — no action needed, but search results may shift slightly while a run is in progress.
- Implication for writes: don't rely on the job to clean up sloppiness. Prefer `create_observation` on an existing entity or `update_entity` over creating near-duplicates.

### Standard Compatibility

graph_mem accepts both its native snake_case/ID-based parameters and the
`@modelcontextprotocol/server-memory` camelCase/name-based conventions:
- Entity references accept either `entity_id` (integer) or entity name (string).
- Field names accept camelCase (e.g. `entityType`) or snake_case (`entity_type`).
- `bulk_update` accepts either three arrays (`entities`, `observations`, `relations`) or a single `operations` array with `type`-discriminated items.
- Observation text accepts `text_content`, `content`, or `contents` (array).
- Relation endpoints accept `from_entity_id`/`to_entity_id` (int), `from`/`to` (name), or `from_entity`/`to_entity` (name).

### Query Strategy
- **Search before create** to avoid duplicates (vector dedup catches some, not all).
- **Start broad, then narrow** using entity IDs from search results.
- **Prioritize root nodes**: find the `Project` first, then traverse its relations.
- **Navigate via relations** (`find_relations`, `get_entity`) instead of repeated searches.

### Entity Types
`Project`, `Framework`, `ApplicationStack`, `Workflow`, `BestPractice`, `Task`, `Step`, `Issue`, `Error`, `PossibleSolution`, `Model`, `DatabaseTable`, `Class`, `APIEndpoint`, `Route`, `Component`, `Service`, `Configuration`, `Migration`, `TestCase`, `Permission`, `User`, `Preference`.

### Relation Types (use the most specific)
`depends_on`, `part_of`, `relates_to`, `implements`, `extends`, `solves`, `configured_by`, `tested_by`, `migrated_by`, `authorizes`, `integrates_with`, `replaces`.

### Observations
- Keep observations **crisp and factual**; include timestamps and code paths where relevant.
- For longform content, write to `/docs` and store the file path as an observation.

### Conflict Handling
1. Note the conflict as an observation on the relevant entity.
2. Research (graph history / web / user) to resolve.
3. Update the graph: new observations, mark outdated ones, edit entity if needed.
4. Record the resolution; inform the user if open questions remain.
