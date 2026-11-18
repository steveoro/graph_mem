## graph_mem memory (MCP), every repository
The graph_mem MCP server is connected in all my projects and holds my conventions, preferences,
file locations and verified fixes. Treat it as the first source of project knowledge, before the
codebase and before your own defaults.
- Start of every task, before reading code: load the `graph-mem-mcp-toolset` skill (or call
  graph_mem `get_context`, then `search` for this repository's Project and its Conventions).
- Before deciding a convention or first editing a file: graph_mem `search` with the paths and names.
- Before the final reply: save corrections, preferences, locations and verified fixes with `graph_write`.
- If graph_mem doesn't answer, say so once and carry on.
