# MCP compat harness

Wire-level checks of graph_mem's MCP transports (mcp-update-plan PR-3). Every check looks at what
goes over the wire (HTTP status, headers, JSON-RPC bodies, stdout lines), never at fast-mcp
classes, so the same cases keep working after the migration to the official `mcp` gem. All traffic
is synthetic and read-only. Run it against a local dev or test instance, never production.

The cases live in `spec/fixtures/mcp/handshakes/` (`stdio.json`, `http.json`). Each case gives the
messages and headers and the expected answer per target: `graph_mem`, and `reference` (the v2.0.0
reference servers: Memory over stdio, Everything over HTTP). A `divergence` explains every place
where graph_mem answers differently, and `changes_in` names the plan step that changes it (MG-5
for the 2026-07-28 rows).

| File | What it does |
|---|---|
| `spec/requests/mcp_protocol_compat_spec.rb` | Runs in the normal suite and asserts graph_mem's expectations: HTTP through the Rails app, stdio through `bin/mcp_stdio_runner.rb` subprocesses. Needs no Node. |
| `compare.rb` | Replays the cases against running servers, checks each target's expectations, and compares graph_mem with the reference by shape and code: "same", "documented divergence", "graph_mem only" or "unexpected" (exit 1); a "same" row that still carries a `divergence` note is labelled stale. Plain Ruby. |
| `handshake_cases.rb` | Loads and checks the cases; shared by the spec and `compare.rb`. |
| `rsdk_server.rb <stdio\|http PORT>` | A one-tool server on the official Ruby SDK (`mcp` 1.8.1), for `compare.rb`'s informational `ruby_sdk` column. |
| `rsdk_client.rb <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the Ruby SDK client (`RSDK_VERSION`, default 1.8.1) and lists tools. |
| `tsclient/tsclient.mjs <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the TS client (`@modelcontextprotocol/client` 2.3.1) and lists tools. |
| `refservers/` | `package.json` + `package-lock.json` for the reference servers (Memory and Everything 2.0.0, SDK 2.3.1). |
| `clients.sh <url>` | The client matrix: TS 2.3.1 and Ruby SDK 1.8.0 and 1.8.1, × auto and legacy, × stdio and HTTP (12 rows). |

## Setup (once)

The SDK clients and servers run outside graph_mem's bundle:

```bash
source "$HOME/.rvm/scripts/rvm"
rvm gemset create mcp_compat && rvm use ruby-3.4.1@mcp_compat
gem install mcp -v 1.8.0 && gem install mcp -v 1.8.1 && gem install faraday rack rackup webrick
(cd script/mcp_compat/tsclient && npm ci)   # Node >= 20
```

Reference servers (Node; `engines` says >= 24, but they also ran on Node 22). `refservers/`
pins Memory and Everything 2.0.0, with the SDK's `server` and `core` packages overridden to 2.3.1,
and its committed `package-lock.json` pins every transitive dependency:

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

## Expected results

At 1.54.1 (2026-10-24; reference servers at 2.0.0 with SDK 2.3.1, on Node 22):

- `compare.rb`: 0 failed expectations, 0 unexpected differences (16 stdio and 27 HTTP cases).
- `clients.sh`: 12 of 12 OK, all on 2025-11-25 in the legacy era. The TS stdio `auto` row takes
  about 1.2 s longer than `legacy` (the `server/discover` probe runs in a sibling process); the
  Ruby SDK's `auto` costs nothing extra.

The `ruby_sdk` column (official `mcp` 1.8.1, informational, for MG-0) answers like graph_mem on the
handshake, the id rules, invalid UTF-8, batches and the 4 MiB cap. It differs where it already speaks
2026-07-28 (it answers `server/discover` like the reference) and in a few error details: it
accepts a 2026-07-28 `MCP-Protocol-Version` on a 2025 session, answers 1999-01-01 with `-32022`,
and uses `-32600` without the id for an unknown or missing session. One difference matters for
MG-5: on stdio, after a `server/discover` it refuses the legacy `initialize` that follows (`-32601`),
while Memory falls back in-process. The TS client probes in a sibling process, so it isn't affected.

## Provenance

The 2026-10-20 originals stayed in a local harness that was never committed. These scripts and
cases were rebuilt on 2026-10-24 from the plan's §0b and §3.0 and the SDK sources, then checked
against the reference servers named above.
