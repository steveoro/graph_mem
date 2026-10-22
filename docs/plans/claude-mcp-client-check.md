# PR-3 step 5: Claude Code as the MCP client against a local graph_mem

For Steve. Run it once PR-3 (graph_mem 1.54.1) is checked out locally (re-run it after MG-4, 1.56.0, when the official `mcp` gem becomes the engine). Part A is shell commands you run yourself. Part B is the prompt you paste into Claude Code. Part C is the table you paste back to the reviewer.
The `claude mcp add` syntax below was checked against the current Claude Code MCP docs (code.claude.com/docs/en/mcp) on 2026-10-21. Flags used: `--transport http|stdio`, `--header`/`-H`, `--env`/`-e`, `--scope local`, the `--` separator for stdio, and `claude mcp add-json` for an HTTP entry with several headers.

## A. Setup (shell)

```bash
claude --version                          # record it; ≥ 2.1.296 expected
cd ~/Projects/graph_mem && git log --oneline -1   # record the commit
export GRAPH_MEM_MCP_TOKEN=$(openssl rand -hex 32)
# Start graph_mem over HTTP on :3030 with this token, in the same shell (bin/mcp, or docker compose up with the env passed through).
# Leave GRAPH_MEM_SCAN_ROOTS unset and the scan subfolder filter at its default `Projects` (Settings › Project scans);
# then native and Docker (home mounted :ro at the same path) give the same scan answers.
# Synthetic scan fixtures (inside the default `Projects` filter, plus one folder outside it):
mkdir -p ~/Projects/mcp-check-synth/lib ~/McpCheckOutside
printf 'class SynthWidget\n  def ping = :pong\nend\n' > ~/Projects/mcp-check-synth/lib/synth_widget.rb
printf '# mcp-check-synth\nSynthetic fixture for the MCP client check.\n' > ~/Projects/mcp-check-synth/README.md

# Work from an empty scratch folder so these local-scope entries don't touch any project config:
mkdir -p /tmp/gm-mcp-check && cd /tmp/gm-mcp-check
G=~/Projects/graph_mem

# HTTP, default profile (/mcp), with a bearer token and a distinct client id. add-json because it sets two headers:
claude mcp add-json gm-http "{\"type\":\"http\",\"url\":\"http://localhost:3030/mcp\",\"headers\":{\"Authorization\":\"Bearer $GRAPH_MEM_MCP_TOKEN\",\"X-MCP-Client\":\"claude-check-http\"}}"
# HTTP, readonly and maintenance profiles: the plain `claude mcp add` form with one header:
claude mcp add --transport http gm-ro http://localhost:3030/mcp/readonly --header "Authorization: Bearer $GRAPH_MEM_MCP_TOKEN"
claude mcp add --transport http gm-maint http://localhost:3030/mcp/maintenance --header "Authorization: Bearer $GRAPH_MEM_MCP_TOKEN"
# HTTP with a wrong token (negative check):
claude mcp add --transport http gm-badtoken http://localhost:3030/mcp --header "Authorization: Bearer wrong-token"
# stdio, maintenance profile. Keep --transport between the --env flags and the name; everything after -- goes to the server:
claude mcp add --env RAILS_ENV=development --env GRAPH_MEM_MCP_PROFILE=maintenance --transport stdio gm-stdio -- /bin/bash "$G/bin/mcp_graph_mem_runner.sh"

claude mcp list   # expected: gm-http, gm-ro, gm-maint, gm-stdio ✔ Connected; gm-badtoken ✘ Failed to connect (401 in the detail)
claude mcp get gm-badtoken   # expected: an Issue: line with HTTP 401
```

Negative checks outside Claude Code:
```bash
# N1 bad token → 401 + WWW-Authenticate
curl -si -X POST http://localhost:3030/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer wrong-token' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  | sed -n '1p;/^[Ww][Ww][Ww]-[Aa]uthenticate/p'
# expected: "HTTP/1.1 401 …" and "WWW-Authenticate: Bearer realm="graph_mem""

# N2 no stdout noise on stdio: every stdout line must be JSON-RPC
cd "$G" && printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | GRAPH_MEM_MCP_PROFILE=maintenance RAILS_ENV=development timeout 90 /bin/bash bin/mcp_graph_mem_runner.sh 2>/dev/null \
  | ruby -rjson -e 'n=0;r=0;STDIN.each_line{|l| next if l.strip.empty?; begin; JSON.parse(l); r+=1; rescue JSON::ParserError; n+=1; puts "NOISE: #{l[0,120]}"; end}; puts "json=#{r} noise=#{n}"'
# expected: json=2 noise=0

# N3 explicit "id": null must be refused and NOT executed (MCP Ruby SDK 1.8.1 #612)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
SID=$(curl -s -D - -o /dev/null -X POST http://localhost:3030/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $GRAPH_MEM_MCP_TOKEN" -d "$INIT" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $GRAPH_MEM_MCP_TOKEN" -H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18')
curl -s -X POST http://localhost:3030/mcp "${H[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' -o /dev/null
W='"method":"tools/call","params":{"name":"graph_write","arguments":{"operations":[{"type":"create_entity","name":"McpCheck NullId","entity_type":"Component"}]}}'
curl -s -w ' HTTP %{http_code}\n' -X POST http://localhost:3030/mcp "${H[@]}" -d "{\"jsonrpc\":\"2.0\",\"id\":null,$W}"
# expected: error -32600 "Invalid Request", data "Request ID must not be null", NO "id" member (D-17), HTTP 400
curl -s -w ' HTTP %{http_code}\n' -X POST http://localhost:3030/mcp "${H[@]}" -d "{\"jsonrpc\":\"2.0\",$W}"
# expected: empty body, HTTP 202. Then in Part B step 5, `search "McpCheck NullId"` must find NOTHING (neither call ran)

# N4 invalid UTF-8 object key → 400 -32700, not 500 (SDK 1.8.1 #624)
printf '{"jsonrpc":"2.0","id":7,"method":"tools/list","\xff":1}' | curl -s -w ' HTTP %{http_code}\n' -X POST http://localhost:3030/mcp "${H[@]}" --data-binary @-
# expected: error -32700, no "id" member, HTTP 400

# N5 initialize no longer promises notifications graph_mem never sends (SDK 1.8.1 #620 principle)
curl -s -X POST http://localhost:3030/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Bearer $GRAPH_MEM_MCP_TOKEN" -d "$INIT" \
  | ruby -rjson -e 'b=STDIN.read; j=JSON.parse(b[/\{.*\}/m]); p j.dig("result","capabilities"); p j.dig("result").key?("instructions")'
# expected (1.54.x and later): resources subscribe/listChanged false, tools listChanged false; instructions key present (true) — the per-profile text, wired in 1.54.0
cd /tmp/gm-mcp-check
```

Then run Part B twice: once with `claude` (default negotiation) and once with `MCP_PROTOCOL_NEGOTIATION=legacy claude`, both from `/tmp/gm-mcp-check`. For each run, note the protocol version graph_mem logged for the connection: `grep -i protocolversion $G/log/development.log | tail -3` (HTTP) and `$G/log/graph_mem_ruby_stderr.log` (stdio). Write `n/a` if it isn't logged.

## B. Prompt to paste into Claude Code

> You are checking the graph_mem MCP servers `gm-http`, `gm-ro`, `gm-maint` and `gm-stdio`. Use only MCP tools, resources and prompts; don't read or edit any files and don't run shell commands. Create only entities whose names start with `McpCheck`, and delete them at the end. For each step, report PASS or FAIL, plus a one-line reason with the key values (ids, counts, error text). At the end, print the results as a Markdown table with the columns `step | server | expected | actual | PASS/FAIL`.
>
> **gm-http (default profile)**
> 1. List this server's tools. Expected: exactly 12, namely `set_context, get_context, search, get_entities, summarize, rank_observations, traverse_graph, find_shortest_path, get_current_time, graph_write, graph_edit, graph_delete`.
> 2. `get_current_time`. Expected: an ISO-8601 time and a `version` field.
> 3. `graph_write`: create a `Project` entity `McpCheck Synth Project` and an entity `McpCheck SynthWidget` (type `Component`) with the observation "McpCheck probe observation 1", plus a relation SynthWidget `part_of` Project. Expected: both ids, the observation id and the relation id returned; a second identical write is rejected as a duplicate (not a silent second copy).
> 4. `set_context` with the project id, then `get_context`. Expected: the active project is `McpCheck Synth Project`.
> 5. `search` "McpCheck SynthWidget". Expected: SynthWidget is the first hit, with no error even if vector search is unavailable. Also `search` "McpCheck NullId": expected **no** hit (shell check N3 must not have written anything).
> 6. `get_entities` for the SynthWidget id, with observations. Expected: the observation from step 3.
> 7. `traverse_graph` from the project, depth 1. Expected: SynthWidget is reached via `part_of`.
> 8. `find_shortest_path` SynthWidget → Project. Expected: a path of length 1.
> 9. `rank_observations` for SynthWidget. Expected: a ranked list containing the step-3 observation.
> 10. `summarize` SynthWidget. Expected: a summary, or a clear "summaries disabled/unavailable" message. Not a crash or `isError` with a stack trace.
> 11. `graph_edit`: change the observation text to "McpCheck probe observation 1 (edited)". Expected: success; `get_entities` shows the new text.
> 12. Resources: list gm-http's resources and read `memory_entities?name=McpCheck SynthWidget`, `memory_graph?entity_id=<project id>&depth=1`, `memory_observations?memory_entity_id=<widget id>` and `memory_relations?from_entity_id=<widget id>`. Expected: 4 resource templates (MemoryEntities, MemoryGraph, MemoryObservations, MemoryRelations), and each read returns JSON containing the McpCheck data.
> 13. Prompts: tell me to run `/mcp__gm-http__orient`, `/mcp__gm-http__recall McpCheck` and `/mcp__gm-http__persist` myself (you can't invoke slash commands), then wait for me to say "done" and check the three answers. Expected: all three exist and return guidance text; `recall` refuses to run without a topic.
>
> **gm-ro (readonly profile)**
> 14. List the tools. Expected: exactly 9 (the step-1 list without `graph_write`, `graph_edit` and `graph_delete`).
> 15. Try to call `graph_write` on gm-ro (if your client hides it, say so). Expected: it isn't offered, or "Tool not found".
> 16. Tell me to type `/` and confirm that gm-ro offers `orient` and `recall` but **not** `persist`.
>
> **gm-maint (maintenance profile)**
> 17. List the tools. Expected: 22 = the 12 above plus `get_graph_stats, dream_state_status, get_maintenance_reports, list_maintenance_review, apply_maintenance_review, dismiss_maintenance_review, suggest_merges, detect_contradictions, scan_project, scan_project_status`.
> 18. `get_graph_stats` and `list_maintenance_review` (read only; don't apply or dismiss anything). Expected: numbers and a list, no error.
> 19. `scan_project` `project_root: "/etc"`, `dry_run: true`. Expected: refused, code `not_mounted` (only the home folder is visible).
> 20. `scan_project` `project_root: "~/.ssh"` written as an absolute path under my home, `dry_run: true`. Expected: refused, code `denied`.
> 21. `scan_project` `project_root: "<home>/McpCheckOutside"`, `dry_run: true`. Expected: refused, code `outside_filter`, with the "add it in Settings › Project scans" hint.
> 22. `scan_project` `project_root: "<home>/Projects/mcp-check-synth"`, `dry_run: true`, `file_globs: ["../*"]`. Expected: refused (no `..` / absolute globs).
> 23. `scan_project` `project_root: "<home>/Projects/mcp-check-synth"`, `dry_run: true`. Expected: accepted, with a `scan_id`; then `scan_project_status` with that id: a status and no graph writes (dry run).
>
> **gm-stdio (maintenance profile over stdio)**
> 24. Repeat steps 1–2 (expect 22 tools here), step 5, and step 19. Expected: the same results as over HTTP.
>
> **gm-badtoken**
> 25. Report how this server shows up for you. Expected: not connected, failed with 401; no tools available.
>
> **Cleanup (gm-http)**
> 26. `graph_delete` SynthWidget and `McpCheck Synth Project` (by id), then `set_context` null, then `search` "McpCheck". Expected: deletes confirmed; context cleared; no McpCheck hits.

## C. Results table (fill in and paste back to the reviewer)

Claude Code version: ____ · graph_mem commit: ____ · date/time (Europe/Rome): ____

| Check | Default negotiation | `MCP_PROTOCOL_NEGOTIATION=legacy` | Notes |
|---|---|---|---|
| `claude mcp list`: 4 ✔, gm-badtoken ✘ 401 | | | |
| Negotiated protocol, HTTP (from the log) | | | |
| Negotiated protocol, stdio (from the log) | | | |
| N1 curl wrong token → 401 + WWW-Authenticate | (run once) | n/a | |
| N2 stdio stdout `json=2 noise=0` | (run once) | n/a | |
| N3 `id: null` → 400 -32600; id-less → 202; neither wrote `McpCheck NullId` | (run once) | n/a | |
| N4 invalid UTF-8 key → 400 -32700 | (run once) | n/a | |
| N5 capabilities: subscribe/listChanged false; `instructions` present (1.54.x+) | (run once) | n/a | |
| B 1–13 gm-http (count PASS / 13) | | | |
| B 14–16 gm-ro | | | |
| B 17–23 gm-maint (incl. scan refusals 19–22) | | | |
| B 24 gm-stdio | | | |
| B 25 gm-badtoken | | | |
| B 26 cleanup, no McpCheck left | | | |
| First stdio connect time (rough, seconds) | | | |
| Anything odd (stderr in the Claude Code UI, timeouts, warnings) | | | |

Paste Claude's per-step table from Part B under this one for any FAIL.

## D. Teardown
```bash
cd /tmp/gm-mcp-check && for s in gm-http gm-ro gm-maint gm-badtoken gm-stdio; do claude mcp remove "$s"; done
rm -rf ~/Projects/mcp-check-synth ~/McpCheckOutside /tmp/gm-mcp-check
unset GRAPH_MEM_MCP_TOKEN   # the token was stored in ~/.claude.json until the remove above
```
