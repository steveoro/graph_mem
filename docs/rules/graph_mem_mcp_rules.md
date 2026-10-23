## graph_mem memory (MCP)

This project uses the graph_mem MCP server: a shared knowledge graph of what
earlier sessions learned (conventions, preferences, where things live, verified fixes).
Use the `graph-mem-mcp-toolset` skill:
- at the start of a task, to load the project's conventions and the user's preferences;
- before deciding a convention (version bump, changelog or docs style, tests, naming,
  config location, release steps) or first editing a file or component;
- before the final reply, to save corrections, preferences, locations and verified fixes.
Without the skill: call `search` before deciding, and `graph_write` before the final reply.
