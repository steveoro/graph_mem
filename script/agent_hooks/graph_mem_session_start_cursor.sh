#!/usr/bin/env sh
# graph_mem sessionStart reminder for Cursor (~/.cursor/hooks/, see bin/agent-install).
# Prints {"additional_context": "..."} with a short static reminder only when the local graph_mem
# server answers; silent and exit 0 otherwise. No graph data, paths or hostnames in the output.
#   GRAPH_MEM_URL          the server's base URL (default http://localhost:3030); the check is Rails'
#                          anonymous health check /up (/api/v1/status needs a session or the token)
#   GRAPH_MEM_HOOK_MARKER  optional: a file to touch each time the hook runs (to see it fire)
if [ -n "${GRAPH_MEM_HOOK_MARKER:-}" ]; then touch "$GRAPH_MEM_HOOK_MARKER" 2>/dev/null || :; fi
URL="${GRAPH_MEM_URL:-http://localhost:3030}"
curl -fsS --noproxy '*' -m 2 "$URL/up" >/dev/null 2>&1 || exit 0
cat <<'TXT'
{"additional_context": "graph_mem (MCP server \"graph_mem\") is connected and holds this user's conventions, preferences, file locations and verified fixes for this repository. Before reading or editing code, call graph_mem get_context, then search for this repository's Project and its Conventions (read the graph_mem MCP tool descriptions). Before the final reply, save corrections and verified fixes with graph_write."}
TXT
exit 0
