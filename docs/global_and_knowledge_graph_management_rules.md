---
description: General coding rules and graph_mem MCP usage (Knowledge Graph)
globs:
alwaysApply: true
---
### Core Rules

- **Schema first**: DB schema is the primary source of truth for data structure.
- **Know your context**: Verify project folder, runtime target, and containers before running commands.
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
1. Say "Remembering..." then call `get_context` to check for an active project.
2. If no context: `search_entities` for the relevant project name → `set_context` with its ID.
3. If no project entity exists yet: `create_entity` (type `Project`) → `set_context`.

**Phase 2 — Recall** (before doing work)
- `search_entities` or `search_subgraph` with keywords from the user's request.
- Drill into hits: `get_entity` for details, `get_subgraph_by_ids` for a cluster of related entities.
- Look for prior `Issue`/`PossibleSolution` pairs, `BestPractice`, and `Preference` entities.

**Phase 3 — Work**
- Execute the user's request using recalled context.
- Consult the graph mid-task if you encounter related issues or need prior solutions.

**Phase 4 — Persist** (before ending)
- `create_observation` for new facts on existing entities.
- `create_entity` + `create_relation` for new concepts discovered.
- Use `bulk_update` to batch multiple writes in one call (max 50 ops).
- `clear_context` if the project scope is no longer relevant.
- Periodically run `suggest_merges` to find and flag duplicate entities.

---

### Tool Quick-Reference

| Phase | Tools |
|-------|-------|
| Orient | `get_context`, `set_context`, `clear_context`, `search_entities` |
| Recall | `search_entities`, `search_subgraph`, `get_entity`, `get_subgraph_by_ids`, `list_entities` |
| Persist | `create_entity`, `update_entity`, `delete_entity`, `create_observation`, `delete_observation`, `create_relation`, `find_relations`, `delete_relation`, `bulk_update` |
| Maintain | `suggest_merges`, `get_graph_stats`, `get_version`, `get_current_time` |

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
