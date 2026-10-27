# MCP compat harness

Wire-level checks of graph_mem's MCP transports (mcp-update-plan PR-3). Every check looks at what
goes over the wire (HTTP status, headers, JSON-RPC bodies, stdout lines), never at server
classes, so the same cases kept working through the migration to the official `mcp` gem. All traffic
is synthetic and read-only. Run it against a local dev or test instance, never production.

The cases live in `spec/fixtures/mcp/handshakes/` (`stdio.json`, `http.json`). Each case gives the
messages and headers and the expected answer per target: `graph_mem`, and `reference` (the v2.0.0
reference servers: Memory over stdio, Everything over HTTP). A `divergence` explains every place
where graph_mem answers differently, and an optional `changes_in` names the plan step that will
change it (no case carries one since 1.55.0).

| File | What it does |
|---|---|
| `spec/requests/mcp_protocol_compat_spec.rb` | Runs in the normal suite and asserts graph_mem's expectations: HTTP through the Rails app, stdio through `bin/mcp_stdio_runner.rb` subprocesses. Needs no Node. |
| `compare.rb` | Replays the cases against running servers, checks each target's expectations, and compares graph_mem with the reference by shape and code: "same", "documented divergence", "graph_mem only" or "unexpected" (exit 1); a "same" row that still carries a `divergence` note is labelled stale. Plain Ruby. |
| `handshake_cases.rb` | Loads and checks the cases; shared by the spec and `compare.rb`. |
| `rsdk_server.rb <stdio\|http PORT>` | A one-tool server on the official Ruby SDK (`mcp` 1.8.2), for `compare.rb`'s informational `ruby_sdk` column. |
| `rsdk_client.rb <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the Ruby SDK client (`RSDK_VERSION`, default 1.8.2) and lists tools. |
| `tsclient/tsclient.mjs <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the TS client (`@modelcontextprotocol/client` 2.3.1) and lists tools. |
| `refservers/` | `package.json` + `package-lock.json` for the reference servers (Memory 2.0.0, Everything 2.0.1, SDK 2.3.1). |
| `clients.sh <url>` | The client matrix: TS 2.3.1 and Ruby SDK 1.8.1 and 1.8.2, × auto and legacy, × stdio and HTTP (12 rows). |
| `claude_client_check.rb` | Claude Code as the client: the automated `docs/plans/claude-mcp-client-check.md` (below). |

## Setup (once)

The SDK clients and servers run outside graph_mem's bundle:

```bash
source "$HOME/.rvm/scripts/rvm"
rvm gemset create mcp_compat && rvm use ruby-3.4.1@mcp_compat
gem install mcp -v 1.8.1 && gem install mcp -v 1.8.2 && gem install faraday rack rackup webrick
(cd script/mcp_compat/tsclient && npm ci)   # Node >= 20
```

Reference servers (Node >= 24, the `engines` of both servers). `refservers/`
pins Memory 2.0.0 and Everything 2.0.1, with the SDK's `server` and `core` packages overridden to 2.3.1
(`node` 2.1.2 and `server-legacy` 2.4.0 declare newer `server`/`core` ranges but run against the
overrides), and its committed `package-lock.json` pins every transitive dependency:

```bash
(cd script/mcp_compat/refservers && npm ci --ignore-scripts)
```

## Run (from the graph_mem checkout)

```bash
export RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9   # no real Ollama, ever
W="$HOME/.rvm/wrappers/ruby-3.4.1@graph_mem"
C="$HOME/.rvm/wrappers/ruby-3.4.1@mcp_compat"
R=script/mcp_compat/refservers/node_modules/@modelcontextprotocol

# HTTP servers on loopback: graph_mem, Everything, and (optionally) the Ruby SDK
"$W/bundle" exec rails server -b 127.0.0.1 -p 3999 &
PORT=3998 node $R/server-everything/dist/index.js streamableHttp &
"$C/ruby" script/mcp_compat/rsdk_server.rb http 3997 &

MEMORY_FILE_PATH=$(mktemp) "$W/ruby" script/mcp_compat/compare.rb \
  --stdio-graph-mem "$W/bundle exec ruby bin/mcp_stdio_runner.rb" \
  --stdio-reference "node $R/server-memory/dist/index.js" \
  --stdio-ruby-sdk "$C/ruby script/mcp_compat/rsdk_server.rb stdio" \
  --http-graph-mem http://127.0.0.1:3999/mcp \
  --http-reference http://127.0.0.1:3998/mcp \
  --http-ruby-sdk http://127.0.0.1:3997/mcp

script/mcp_compat/clients.sh http://127.0.0.1:3999/mcp
```

Any subset of the `--…` targets works: graph_mem alone just checks graph_mem. Stop the servers
afterwards. No case runs a tool, so the test DB stays empty.

Everything listens on all interfaces (it has no host option), so run the harness only on a trusted
machine, and keep Everything at 2.0.1 or later (2.0.0 has open CORS, GHSA-mvf5-2qqv-rg3c).

## Expected results

At 1.55.1 (2026-10-25; reference servers at 2.0.0 with SDK 2.3.1, on Node 22):

- `compare.rb`: 0 failed expectations, 0 unexpected differences (16 stdio and 27 HTTP cases). The
  `ruby_sdk` column (`mcp` 1.8.1, informational) answers every case exactly like graph_mem, which
  runs on the same gem since 1.55.0.
- `clients.sh`: 12 of 12 OK. Every `auto` row negotiates 2026-07-28, every `legacy` row 2025-11-25.
  The TS stdio `auto` row takes about 1.3 s longer than `legacy` (the `server/discover` probe runs in
  a sibling process); the Ruby SDK's `auto` costs nothing extra.

Results, tables and the remaining divergences from the reference: [`docs/protocol_compat.md`](../../docs/protocol_compat.md).

## Claude Code client check

`claude_client_check.rb` automates `docs/plans/claude-mcp-client-check.md`. Run it from the graph_mem
checkout with the graph_mem Ruby, and the `claude` CLI (2.1.296 or later) logged in:

```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem
bundle exec ruby script/mcp_compat/claude_client_check.rb                 # both negotiation modes
bundle exec ruby script/mcp_compat/claude_client_check.rb --only legacy --model haiku --budget 1
```

It boots graph_mem in-process on `127.0.0.1:3995` (`--port` to change it; test environment, a throwaway
bearer token, synthetic scan folders in a temp dir) and refuses any database but graph_mem's test one.
**Don't run it alongside rspec:** both use the test database, and the script's cleanup removes the rows
created while it runs. It:

1. **Part A:** checks a wrong token (401 + `WWW-Authenticate`), stdio stdout hygiene, `"id": null` and
   id-less calls (nothing runs), an invalid UTF-8 key, the `initialize` capabilities and instructions,
   and the three prompts (rendering, `recall` without a topic, no `persist` on readonly) directly over
   HTTP and stdio.
2. **Part B:** runs `claude -p` with the checklist's prompt (`claude_client_check/prompt.md`) against five
   servers (`gm-http`, `gm-ro`, `gm-maint`, `gm-stdio`, `gm-badtoken`), once with the default negotiation
   and once with `MCP_PROTOCOL_NEGOTIATION=legacy`. The servers come from `--mcp-config` with
   `--strict-mcp-config`, settings from the empty scratch folder only, and no built-in tools but the MCP
   resource tools, so your own Claude Code configuration is neither used nor changed. The agent returns its
   step table as JSON (`claude_client_check/schema.json`).
3. **Part C, checked on graph_mem's side:** the connection status of each server (Claude Code's `init`
   event), the prompts each profile offered, the protocol version each client negotiated (recorded by a
   Rack tap for HTTP and a pipe tap for stdio), the tools each client really called (`tool_invocations`),
   that the readonly profile wrote nothing, and that no `McpCheck` entity is left. A check fails if either
   the agent or graph_mem's side says so. The protocol check reads the version each client actually used
   for its tool calls (the `MCP-Protocol-Version` header over HTTP, the request's `_meta` version or the
   `initialize` result over stdio): 2026-07-28 with the default negotiation, 2025-11-25 with `legacy`.

It prints the results table, exits 1 on any failure, and removes what it created (entities, telemetry
rows, contexts, the scratch folder). Cost: one Claude Code session per mode, capped by `--budget`
(default 3 USD each) and `--timeout` (default 900 s each); a session that exits non-zero or times out is
a failed check with its last stderr lines (the token redacted). On 2026-10-25 a run cost about 0.36 USD
with Sonnet and 0.02 USD with Haiku. gm-stdio runs with the script's own Ruby, Bundler and gem paths.

Results on 2026-10-25 (graph_mem 1.55.0, Claude Code 2.1.310): all checks pass in both modes; Claude Code
negotiates 2026-07-28 over HTTP and stdio by default, and 2025-11-25 with `MCP_PROTOCOL_NEGOTIATION=legacy`.

## Provenance

The 2026-10-20 originals stayed in a local harness that was never committed. These scripts and
cases were rebuilt on 2026-10-24 from the plan's §0b and §3.0 and the SDK sources, then checked
against the reference servers named above.
