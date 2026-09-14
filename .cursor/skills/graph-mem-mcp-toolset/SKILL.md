---
name: graph-mem-mcp-toolset
description: Use the graph_mem MCP toolset with a repeatable 4-phase workflow (orient, recall, work, persist), schema-first tool invocation, and dedup-safe entity management. Use when the user mentions graph_mem, memory graph, knowledge graph, MCP memory tools, or asks to store/retrieve project context.
---

# Graph Mem MCP Toolset (Cursor adapter)

The canonical, vendor-neutral skill lives at
[`skills/graph-mem-mcp-toolset/SKILL.md`](../../../skills/graph-mem-mcp-toolset/SKILL.md).
Read and follow that file first — this shim only adds the Cursor-specific
invocation mechanics.

## Cursor invocation mechanics

- The server appears as `user-graph_mem` (the key in your `mcp.json`).
- Fetch tool schemas with `GetMcpTools` before each `CallMcpTool` invocation;
  validate required arguments against the returned schema.
- If the server reports `needsAuth`, authenticate once with its `mcp_auth`
  tool, then inspect the server again.
- Call envelope: `{"server":"user-graph_mem","toolName":"<tool>","arguments":{...}}`
  — the `<tool>` names and `arguments` payloads are exactly the ones used in
  the canonical skill's execution templates.

## Workflow summary

Orient → Recall → Work → Persist; always `search_entities` before
`create_entity`. Full details in the canonical skill file.
