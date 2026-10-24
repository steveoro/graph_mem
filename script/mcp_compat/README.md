# MCP compat harness

Wire-level checks of graph_mem's MCP transports (mcp-update-plan PR-3 §3.0–3.1). Every check looks
at what goes over the wire (HTTP status, headers, JSON-RPC bodies, stdout lines), never at
fast-mcp classes, so the same scripts keep working after the migration to the official `mcp` gem.
All traffic is synthetic and read-only. Run it against a local dev or test instance, never
production.

| Script | What it checks |
|---|---|
| `http_probe.sh <url>` | Streamable HTTP: version negotiation, `MCP-Protocol-Version`, 2026-07-28 fallback, session errors, body shape, 413, 409, capabilities. Needs `curl` and `jq`. |
| `drive.rb [--report] -- <cmd…>` | stdio: replays `scenarios.json`, one fresh server process per scenario. Checks replies by id, the reply count, and that every stdout line is JSON-RPC. Plain Ruby. |
| `rsdk_client.rb <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the Ruby SDK client (`mcp` 1.8.0) and lists tools. |
| `tsclient/tsclient.mjs <stdio\|http> <auto\|legacy> <url \| -- cmd…>` | Connects the TS client (`@modelcontextprotocol/client` 2.3.1) and lists tools. |
| `clients.sh <url>` | The eight-row client matrix: TS + Ruby × auto + legacy × stdio + HTTP. |

Each prints `PASS`/`FAIL` (or `OK`/`FAIL`) per row and exits 1 on a failure. `--reference`
(`http_probe.sh`) and `--report` (`drive.rb`) only print the answers, for the v2.0.0 reference
servers, whose expected answers differ.

## Setup (once)

The SDK clients run outside graph_mem's bundle:

```bash
source "$HOME/.rvm/scripts/rvm"
rvm gemset create mcp_compat && rvm use ruby-3.4.1@mcp_compat
gem install mcp -v 1.8.0 && gem install faraday
(cd script/mcp_compat/tsclient && npm ci)   # Node >= 20
```

## Run (from the graph_mem checkout)

```bash
export RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9   # no real Ollama, ever
W="$HOME/.rvm/wrappers/ruby-3.4.1@graph_mem"

# HTTP: start a throwaway server on loopback, then probe it
"$W/bundle" exec rails server -b 127.0.0.1 -p 3999 &
script/mcp_compat/http_probe.sh http://127.0.0.1:3999/mcp

# stdio
"$W/ruby" script/mcp_compat/drive.rb -- "$W/bundle" exec ruby bin/mcp_stdio_runner.rb

# SDK clients (HTTP rows need the server above)
script/mcp_compat/clients.sh http://127.0.0.1:3999/mcp
```

Stop the server afterwards. Initialize and ping write nothing, so the test DB stays empty.

## Expected results

The expectations are the "graph_mem after PR-2" column of mcp-update-plan §3.0, plus the Oct 22
additions in §3.1. Rows marked MG-5 in the plan change when graph_mem answers 2026-07-28 natively.
At 1.54.0 (2026-10-24):

- `http_probe.sh`: 27 PASS
- `drive.rb`: 13 of 13 PASS
- `clients.sh`: 8 of 8 OK, all on 2025-11-25 in the legacy era. The TS stdio `auto` row takes about
  1 s longer than `legacy`, which is the `server/discover` probe process.

## Provenance

The originals were written on 2026-10-20 in a local harness that was never committed. These
scripts were rebuilt on 2026-10-24 from the §3.0 tables and the SDK sources (TS client 2.3.1,
`mcp` gem 1.8.0), so their output format may differ from the recorded baseline. The reference-server
columns (Memory 2.0.0 over stdio, Everything 2.0.0 over HTTP) weren't re-run: they need Node ≥ 24
and the `v2.0.0` tag. PR-3 turns these cases into fixtures (`spec/fixtures/mcp/handshakes/`),
an in-suite spec, and `compare.rb`.
