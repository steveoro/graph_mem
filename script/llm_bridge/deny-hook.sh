#!/bin/sh
# PreToolUse hook for agent-CLI runs (graph_mem script/llm_bridge): record the attempt and deny it.
# Appends one line (UTC time, the run id, the tool name cut to 200 characters) to
# $AGENT_CLI_STATE/hook.log and exits 2. The hook event arrives as JSON on stdin; only its
# tool_name is kept, and nothing is printed but a fixed refusal on stderr.
state="${AGENT_CLI_STATE:-$HOME/.local/state/agent-cli}"
event=$(dd bs=1024 count=64 2>/dev/null)
tool=$(printf '%s\n' "$event" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -d '\t\r' | cut -c 1-200)
[ -n "$tool" ] || tool="unknown"
umask 077
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GM_LLM_RUN_ID:-none}" "$tool" >> "$state/hook.log"
echo "graph_mem llm bridge: tools are disabled for this run" >&2
exit 2
