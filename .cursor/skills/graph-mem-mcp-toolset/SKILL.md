---
name: graph-mem-mcp-toolset
description: Use the graph_mem MCP toolset with a repeatable 4-phase workflow (orient, recall, work, persist), schema-first tool invocation, and dedup-safe entity management. Use when the user mentions graph_mem, memory graph, knowledge graph, MCP memory tools, or asks to store/retrieve project context.
---

# Graph Mem MCP Toolset

Use this skill to operate `graph_mem` reliably and consistently.

## Quick Start

1. **Schema first**
   - Read the tool descriptor JSON before each MCP tool call.
   - Path pattern: `mcps/user-graph_mem/tools/<tool-name>.json`.
   - Validate required params from schema, then call the tool.

2. **Follow the 4-phase workflow**
   - Orient -> Recall -> Work -> Persist.

3. **Search before create**
   - Always run `search_entities` before `create_entity` to avoid duplicates.

## Tool Discovery And Schema Rule

Before calling `CallMcpTool` for any `user-graph_mem` tool:

1. List available descriptors under `mcps/user-graph_mem/tools/`.
2. Read descriptor(s) for the exact tool(s) you will invoke.
3. If a descriptor named `mcp_auth` exists, run `mcp_auth` first (one server at a time).
4. Only then call `CallMcpTool`.

## 4-Phase Session Workflow

## Phase 1 - Orient (start of session)

1. Say `Remembering...`.
2. Call `get_context`.
3. If no context:
   - Run `search_entities` for the project name.
   - If found, call `set_context(entity_id: <id>)`.
   - If not found, call `create_entity(name:, entity_type: "Project")`, then `set_context`.

## Phase 2 - Recall (before implementation)

1. Run `search_entities` or `search_subgraph` with task keywords.
2. Inspect top matches with `get_entity`.
3. For related clusters, run `get_subgraph_by_ids`.
4. Prioritize `Issue` + `PossibleSolution`, `BestPractice`, and `Preference` entities.

## Phase 3 - Work

1. Execute the requested task using recalled knowledge.
2. If blocked or uncertain, query graph_mem again mid-task:
   - `search_entities` for new clues.
   - `find_relations` to traverse linked nodes.

## Phase 4 - Persist (before final response)

1. Write newly learned facts with `create_observation` on existing entities.
2. For new concepts:
   - `create_entity`
   - `create_relation` with a specific relation type.
3. For batch updates, prefer `bulk_update` (max 50 operations).
4. Run `suggest_merges` periodically to detect duplicates.
5. Call `clear_context` only when project scope is no longer relevant.

## Parameter Compatibility

graph_mem accepts both native and MCP-memory-style forms:

- `entity_type` and `entityType`
- ID or name references for entities
- `text_content`, `content`, or `contents` for observations
- `bulk_update` via:
  - native arrays (`entities`, `observations`, `relations`), or
  - `operations` array (type-discriminated items)

Default recommendation: use native snake_case keys unless compatibility with external payloads is needed.

## Query Strategy

1. Start broad (`search_entities`) then narrow by IDs.
2. Find the root `Project`, then traverse relations.
3. Prefer relation traversal (`find_relations`, `get_entity`) over repeated fuzzy searches.
4. Keep observations factual and timestamped when possible.

## Preferred Entity And Relation Types

Common entity types:
`Project`, `Task`, `Issue`, `PossibleSolution`, `BestPractice`, `Preference`, `Workflow`, `Configuration`, `Model`, `Service`, `APIEndpoint`, `TestCase`.

Common relation types:
`part_of`, `relates_to`, `depends_on`, `implements`, `solves`, `tested_by`, `configured_by`, `integrates_with`, `replaces`.

Use the most specific valid relation type available.

## Execution Templates

### Orient template

```json
{"server":"user-graph_mem","toolName":"get_context","arguments":{}}
```

If no context:

```json
{"server":"user-graph_mem","toolName":"search_entities","arguments":{"query":"<project name>"}}
```

```json
{"server":"user-graph_mem","toolName":"set_context","arguments":{"entity_id":123}}
```

### Recall template

```json
{"server":"user-graph_mem","toolName":"search_entities","arguments":{"query":"<task keywords>"}}
```

```json
{"server":"user-graph_mem","toolName":"get_entity","arguments":{"entity_id":456}}
```

### Persist template

```json
{"server":"user-graph_mem","toolName":"create_observation","arguments":{"entity_id":456,"text_content":"[YYYY-MM-DD] <fact>"}} 
```

```json
{"server":"user-graph_mem","toolName":"bulk_update","arguments":{"operations":[{"type":"observation","entity_id":456,"text_content":"<fact>"}]}}
```

## Quality Guardrails

- Never skip schema checks before tool calls.
- Never create duplicate project entities without searching first.
- Keep entries concise, factual, and reusable.
- Prefer updating existing entities over creating near-duplicates.
- Record blockers as `Issue` and link confirmed fixes as `PossibleSolution`.
