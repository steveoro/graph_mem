Read `references/hosts.md` when running in Cursor and MCP calls fail or the server reports `needsAuth`.

# Cursor invocation mechanics

- The server appears as `user-graph_mem` (the key in your `mcp.json`).
- Fetch tool schemas with `GetMcpTools` before each `CallMcpTool` invocation;
  validate required arguments against the returned schema.
- If the server reports `needsAuth`, authenticate once with its `mcp_auth`
  tool, then inspect the server again.
- Call envelope: `{"server":"user-graph_mem","toolName":"<tool>","arguments":{...}}`.
