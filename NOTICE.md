# Third-party code

## lib/graph_mem/mcp_schema/

The tool `arguments` DSL (dry-schema extensions, metadata context and JSON Schema processor) and the
prompt and resource class APIs are vendored from **fast-mcp 1.8.0**:

- upstream: https://github.com/yjacquin/fast-mcp
- the fork graph_mem used: https://github.com/steveoro/fast-mcp, tag `1.8.0` (commit `84c98dd`)
- licence: MIT, Copyright (c) 2025 Yorick Jacquin; the full text is in `lib/graph_mem/mcp_schema/LICENSE`.

graph_mem moved from fast-mcp to the official MCP Ruby SDK (`mcp` gem) in 1.55.0 and dropped the
fast-mcp dependency in 1.55.1; only this part was kept, namespaced under `GraphMem::McpSchema`.
