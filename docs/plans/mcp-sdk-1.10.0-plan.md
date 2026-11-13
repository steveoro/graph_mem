# MCP SDK 1.10.0 → graph_mem 1.86.1 (gem bump, invalid-UTF-8 method case, compat baseline on reference servers v2.4.0)

**Status (2026-11-13): PLAN, approved order, kickoff ready.** Steve confirmed the train on 2026-11-13: **1.86.1** = this
plan (`mcp` 1.9.0 → 1.10.0 plus the reference-server baseline v2.4.0), then 1.86.2 and 1.86.3 (other fixes), then the
MCP Apps train 1.87.0–1.89.0 (`docs/plans/mcp-apps-plan.md`).

**Written 2026-11-13 (Europe/Rome)** for Claude, from `main` at `466bab8` (graph_mem 1.86.0, `mcp` 1.9.0). Every
file:line below was checked against `466bab8`. If a line has moved, find it by the quoted text. If the code no longer
matches the description, **stop and ask Steve** instead of improvising.
Upstream: `modelcontextprotocol/ruby-sdk` v1.9.0..v1.10.0 (2026-11-11) and `modelcontextprotocol/servers` v2.4.0
(2026-11-11); both are still the newest releases on 2026-11-13. `mcp.gemspec` is unchanged between the tags (still
`json_schemer >= 2.4`), so the lock diff should be the two `mcp` lines only.

**Context.** The 1.9.0 plan (`docs/plans/done/mcp-sdk-1.9.0-plan.md`) shipped in #156 as **1.72.0** (2026-11-05):
`Gemfile:36` `gem "mcp", "1.9.0"`, `Gemfile.lock:228` `mcp (1.9.0)`, `:527` `mcp (= 1.9.0)`. Its non-object `_meta`
cases are in `stdio.json` and `http.json` as documented divergences. This plan is the next "one PR per upgrade" (D14).

**What was pre-checked, and what wasn't.** The pre-check ran on a scratch machine without a database, so **graph_mem
itself was not run**: no rspec, no graph_mem column in `compare.rb`, no `clients.sh` against graph_mem. What did run, on
Node 24.22.1 and Ruby 3.4.12, used the harness and fixtures from `main`:
- `compare.rb` with the **reference** and **ruby_sdk** targets (`rsdk_server.rb` on `mcp` 1.9.0 and 1.10.0), against
  four reference sets: the current pin (Memory 2.0.0, Everything 2.0.1, SDK 2.3.1 override), the v2.4.0 packages as
  published (Memory 2.1.1, Everything 2.3.0, SDK resolves to 2.4.0), v2.4.0 with the 2.3.1 override, and the exact B6
  `package.json` (overrides pinned to 2.4.0).
- A **proxy run** with `rsdk_server.rb` in the graph_mem slot, to get the same/divergence verdicts.
- Direct JSON-RPC probes for the non-object `_meta` case (all `_meta` shapes, both lifecycles) and for #672 (an invalid
  UTF-8 method name).
- `clients.sh` with `rsdk_server.rb` standing in for graph_mem (TS 2.3.1, Ruby SDK 1.9.0 and 1.10.0), plus TS client 2.4.0.

## Brief

| | |
|---|---|
| **Status** | PLAN, approved order, kickoff ready (1.86.1, first in the train). |
| **Branch / PR** | **One PR**, `claude/mcp-1.10.0`, off `main`, title `mcp 1.10.0 (1.86.1)`: steps B1–B7 + release RB. Steve merges and tags. Never merge, tag, push tags or run `rake release`. |
| **Commits** | **B1** gem bump, **B2** invalid-UTF-8 method spec, **B3** compat case, **B4** harness versions, **B6** reference servers v2.4.0 + TS client 2.4.0 (required), **B5** version text + re-recorded results (after B6, so it records the new baseline), **B7** MCP Apps plan references, **RB** release. Review fixes go in new commits. No force-push after review starts. |
| **Scope** | No tool, prompt, resource or `/api/v1` changes, and **no new MCP params or outputs**. The only npm changes are the B6 pins in `script/mcp_compat/` (approved); no other package. No Skills, no MCP Apps, no `Mcp-Param-*` (`x-mcp-header`) declarations, no OAuth `issuer:`. `spec/fixtures/mcp/snapshots/` stays byte-identical: `/mcp` 12 tools, readonly 9, maintenance 22. |
| **Data** | Synthetic fixtures only (`SynthClient`, `synth-*` names). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `script/mcp_compat/README.md`, `docs/protocol_compat.md`, `docs/plans/done/mcp-sdk-1.9.0-plan.md`. |

## Upstream changes (verified at `v1.10.0`) and what they mean for graph_mem

| PR | Change | For graph_mem |
|---|---|---|
| #665 | **Stdio client** passes the server process only `HOME LOGNAME PATH SHELL TERM USER GEM_HOME GEM_PATH` plus `env:`, with `unsetenv_others` unless `inherit_env: true` (`lib/mcp/client/stdio.rb`). | **Server side: none** (graph_mem serves stdio, it doesn't use the client). **Harness:** `rsdk_client.rb:31` passes `env: ENV.to_h`, so the child still gets `RAILS_ENV=test` and `OLLAMA_URL` (checked: 1.10.0 stdio rows OK). Keep that argument; without it the 1.10.0 client would start `bin/mcp_stdio_runner.rb` **without** `RAILS_ENV`/`OLLAMA_URL`, i.e. against the development DB and a real Ollama. B4 adds a comment saying so. |
| #669 | `ServerSession` validates an `elicitation/create` reply against `requestedSchema` and raises `Server::ValidationError` on a mismatch. | **None.** graph_mem never elicits (no `elicit`/`create_elicitation` anywhere in `app/` or `lib/`). |
| #676 | Streamable HTTP: a server-pushed SSE write (notification, server→client request, listen ack, keepalive) gets `stream_write_timeout:` (default **10 s**); a stalled stream is closed and dropped. | **Hardening, no behaviour change expected.** graph_mem builds the transport with `enable_json_response: true` (`lib/graph_mem/official_mcp/transports.rb:37-45`) and sends no list_changed/resources/logging notifications (`server_factory.rb:10-12`), so only GET-stream keepalives are affected. Keep the default; don't add the option (it would be a new knob). |
| #672 | `valid_method_name?` also requires `method.valid_encoding?` (`lib/json_rpc_handler.rb:229-231`); the HTTP transport echoes only encodable ids (`echoable_id`). | **Wire change.** A request whose `method` holds invalid UTF-8 was **−32603 "Internal error"** with the id on 1.9.0 and is **−32600 "Invalid Request"** with the id on 1.10.0, on stdio and HTTP (HTTP 200). Probed on `rsdk_server.rb`; graph_mem runs the same handler, so expect the same. No existing spec or compat case covers it (B2, B3). |
| #671 | Header and body values echoed into transport error responses are scrubbed (`printable_value`). | Low: those refusals no longer turn into a 500 on invalid bytes. The #629 trigger (`"Tool not found: #{tool_name}"`, `server.rb:1416`) is **not** scrubbed and still answers −32603 with the id on 1.10.0 (compare outline unchanged). |
| #654 | `Mcp-Param-*` headers of a 2026-07-28 `tools/call` are validated against the body (SEP-2243), only for tools whose `inputSchema` declares `x-mcp-header`. | **None today**: no graph_mem schema declares `x-mcp-header`. Declaring one would be a new MCP surface (hard stop). |
| #667, #668 | Logging level per session (`logging_sessions` hook on both transports); instrumentation data per request (`add_instrumentation_data` deprecated; `call_tool`/`get_prompt`/`read_resource` now take a required `instrumentation_data:` keyword). | **None.** graph_mem declares no `logging` capability, never calls `notify_log_message`, `add_instrumentation_data`, `around_request` or `instrumentation_callback`, and doesn't override the private dispatch methods. `GraphMem::OfficialMcp::StdioTransport` (`lib/graph_mem/official_mcp/stdio_transport.rb:7`) inherits the new `logging_sessions` unchanged. |
| #656, #664, #666, #673, #674, #678 | `MCP::ServerContext` autoload; HTTP client keeps handler exception details local; JWT algorithm vs key check; `max_message_bytes` on more HTTP client responses; OAuth `issuer:`; no `base64` require. | None (graph_mem uses no JWT verifier or OAuth client; `OAuth::AccessToken`, used by `request_context.rb:55`, is unchanged). |

**Unchanged between the tags** (checked by diff): `lib/mcp/apps.rb` (the `MCP::Apps` helpers the MCP Apps plan relies
on), `lib/mcp/tool.rb` (`Tool.meta` still `:113`), `lib/mcp/resource*`, capabilities handling (`capabilities=` still
`server.rb:202`; `normalize_capabilities` moves from `:1679` to **`:1691`**), `refuse_non_object_meta!` (now
`server.rb:947`, called at `:809`), `Transports::StdioTransport#initialize`/`send_response`, `Tool::InputSchema`,
`ResourceNotFoundError`. A custom `resources_read_handler` (graph_mem's, `server_factory.rb:35`) still goes through
`dispatch_optional_context_handler`; only the default read path changed.

**For the MCP Apps train (`docs/plans/mcp-apps-plan.md`, 1.87.0–1.89.0).** Nothing in 1.10.0 touches Apps or resources,
so that plan's "What 1.9.0 already has" section holds on 1.10.0 too. Its gem section names 1.9.0 as the pin and
1.10.0 as a future bump, and one of its line references moves: `lib/mcp/server.rb:1679-1685` → `:1691-1697`
(`lib/mcp/tool.rb:113` stays). This PR updates that text (step B7), so the Apps train starts on a correct plan.

## Compat results: reference servers v2.4.0, Node 24 (before → after per documented difference)

"A3" is the 1.9.0 plan's non-object `_meta` compat case. "Before" is what `docs/protocol_compat.md` records at 1.72.0 (Node 24.11.1, Memory 2.0.0, Everything 2.0.1, SDK 2.3.1).
"After" is the 2026-11-13 pre-check on Node 24.22.1. Servers v2.4.0 publishes **Everything 2.3.0** and **Memory 2.1.1**
(and filesystem 2.3.0, git/fetch/time 2026.11.11, which the harness doesn't use).

**Summary: no documented difference changes.** On every reference set, `compare.rb` run 1 is "0 failed expectations,
0 unexpected differences" (18 stdio, 31 HTTP cases), and the outlines are **byte-identical** across all runs
(current pin vs v2.4.0, SDK 2.3.1 vs 2.4.0 and the exact B6 pins, `mcp` 1.9.0 vs 1.10.0). The proxy run (rsdk_server in the graph_mem slot)
gives the same verdicts as the 1.72.0 tables, apart from the expected `graph_mem only` failure of the capabilities and
instructions case (rsdk_server has no instructions).

| Case (A3 first) | Before (1.72.0 record) | After: Memory 2.1.1 / Everything 2.3.0 | graph_mem side on 1.10.0 (rsdk proxy) | Verdict |
|---|---|---|---|---|
| **A3 stdio** tools/list with `_meta: "x"`, then a ping | Memory 2.0.0: ZodError on stderr, **no reply** to id 2; ping answered | **Unchanged**: `Transport error: ZodError` on stderr, no reply to id 2, ping answered (`[[1,result],[3,result]]`) | `[[1,result],[2,-32602],[3,result]]` | documented divergence (unchanged) |
| **A3 HTTP** tools/list with `_meta: "x"` in a session | Everything 2.0.1: **HTTP 400 −32700** "Parse error: Invalid JSON-RPC message", `id: null` | **Unchanged**: HTTP 400, −32700, same message, `id: null` | HTTP 200, −32602, id 45 | documented divergence (unchanged) |
| A3 extra shapes (not fixture cases) | not recorded | `[1]` and `1`: same as `"x"`. **`_meta: null` is refused too** (HTTP 400 −32700 / stdio no reply) on both the old and the new servers | `null` reads as absent (normal result), `[1]`/`1` → −32602 | pre-existing, undocumented; optional note in B5 |
| A3 on the 2026-07-28 lifecycle (not a fixture case) | not recorded | HTTP 400 **−32600** "Bad Request: the request body is not a valid JSON-RPC message", id echoed (old and new) | HTTP 400 **−32602**, id echoed (1.9.0 and 1.10.0) | pre-existing, undocumented; optional |
| Every other stdio case (8 same, 8 divergences, 2 graph_mem only) | as in `docs/protocol_compat.md` § stdio | identical outlines | identical to 1.9.0 | unchanged |
| Every other HTTP case (incl. #629 invalid UTF-8 tool name −32603, invalid UTF-8 key −32700, batch, 4 MiB, sessions, Origin) | as in § HTTP | identical outlines | identical to 1.9.0 | unchanged |
| **New:** invalid UTF-8 **method** name (`"tools/\xFFlist"`), then a ping | not a case | Memory and Everything (old and new): **−32601 "Method not found"** with the id (Node decodes the byte as U+FFFD) | 1.9.0: **−32603** with the id; **1.10.0: −32600** "Invalid Request" with the id (stdio; HTTP 200) | new documented divergence (B3) |

**Client matrix (stand-in, not graph_mem):** `clients.sh` against `rsdk_server.rb` on 1.9.0 and on 1.10.0, with
`RSDK_VERSIONS="1.9.0 1.10.0"`: 12 of 12 OK both times; every `auto` row 2026-07-28, every `legacy` row 2025-11-25.
TS client 2.4.0 (newest): 4 of 4 OK against 1.10.0. The legacy-HTTP Ruby rows against `rsdk_server.rb` need the
`event_stream_parser` gem (it answers over SSE); graph_mem answers JSON, so the README install line is fine for graph_mem.

**Harness side effects seen in the pre-check:**
- Everything **2.3.0 binds 127.0.0.1 by default** (`HOST` widens it); 2.0.1 ignores `HOST` and listens on all interfaces.
  `script/mcp_compat/README.md:73` ("Everything listens on all interfaces (it has no host option)") is rewritten in B6.
- The published Everything 2.3.0 / Memory 2.1.1 declare `@modelcontextprotocol/server ^2.3.1` and resolve to 2.4.0; with
  or without the 2.3.1 override the answers are identical.
- None of the six v2.4.0 security fixes touches a package the harness runs (they are in filesystem, git and fetch).
  `mcp-server-git` was **not** run.

## What the code looks like today (verified at `466bab8`)

- `lib/graph_mem/version.rb`: `VERSION = "1.86.0"`. `skills/graph-mem-mcp-toolset/SKILL.md:18`: `graph-mem-version: "1.86.0"`
  (`.agents/skills/` and `.claude/skills/` are symlinks to it). `README.md:7`: the version badge `version-1.86.0`.
- `Gemfile:35-36`: comment "Exact pin: one PR per upgrade (D14)", `gem "mcp", "1.9.0"`. `Gemfile.lock:228` `mcp (1.9.0)`, `:527` `mcp (= 1.9.0)`.
- `spec/requests/mcp_non_object_meta_spec.rb` (the 1.9.0 A2 specs; comments name 1.9.0 at `:5,36,58,71`);
  `spec/integration/mcp_structured_output_stdio_spec.rb:115`; `spec/requests/mcp_official_spec.rb:439` (#629, "unchanged on 1.9.0").
- Fixture divergence texts naming the SDK version: `stdio.json:160,198,212,226`, `http.json:218,228,333`.
- Harness: `rsdk_server.rb:4,15`; `rsdk_client.rb:4,5,12,17,31,43`; `clients.sh:2,12,22` (default `"1.8.2 1.9.0"`);
  `script/mcp_compat/README.md:10,19,20,22,23,33,37-38,73-74,78-87`; `refservers/package.json` (Memory 2.0.0, Everything 2.0.1, override 2.3.1).
- Version text: `README.md:73`; `AGENTS.md:44`; `docs/architecture.md:61,70,74,78`; `docs/development.md:83`;
  `docs/protocol_compat.md:5,27-45,63-70,76,101,158-165,185-190,204,206`.

## PR → 1.86.1: `mcp` 1.10.0

### B1. Gem bump
`gem "mcp", "1.10.0"` (keep the exact pin and the D14 comment), then `bundle lock --update mcp --conservative`.
The lock diff must be exactly the two `mcp` lines (`:228`, `:527`). Anything else: stop and ask.

### B2. Invalid UTF-8 method name spec
In `spec/requests/mcp_official_spec.rb`, next to the #629 block (same byte-built body pattern, `.b`):
- `{"jsonrpc":"2.0","id":8,"method":"tools/\xFFlist"}` on `/mcp` and `/mcp/readonly` → HTTP 200, `error.code == -32600`, id 8,
  with a "before 1.10.0: −32603 (#672)" note. Unlike the #629 block, expect **no**
  `Rails.error` report (the gem should refuse the method before dispatch; not checked on graph_mem, so assert what it does).
- One stdio case in `spec/integration/mcp_structured_output_stdio_spec.rb`, followed by a ping that is still answered.
Check once with the lock reverted that the HTTP case fails on 1.9.0 (expected −32603), then restore.

### B3. Compat case: a **documented divergence**
Add "a method name that is not valid UTF-8, then a ping" to `stdio.json` and "a method name that is not valid UTF-8"
to `http.json`: `graph_mem` expects −32600 with the id; `reference` expects −32601 with the id (Memory and Everything,
both versions). The divergence text: graph_mem refuses the method as an invalid request (Ruby SDK 1.10.0, #672); Node
decodes the byte as U+FFFD and answers Method not found. Check `handshake_cases.rb` can send the raw byte in a
`method` (the existing invalid-key and invalid-tool-name cases show how); if it needs code changes, stop and ask.

### B4. Harness versions
- `RSDK_VERSION` default 1.9.0 → 1.10.0 in `rsdk_server.rb:4,15` and `rsdk_client.rb:4,17` (keep the 1.9.0 `title` note at `:5,43`).
- `rsdk_client.rb:31`: keep `env: ENV.to_h` and add one comment line: since 1.10.0 (#665) the stdio client passes only a
  minimal environment unless `env:` is given, and the stdio runner needs `RAILS_ENV`/`OLLAMA_URL`.
- `clients.sh:2,12,22` `RSDK_VERSIONS` `"1.8.2 1.9.0"` → `"1.9.0 1.10.0"` (still 12 rows).
- `script/mcp_compat/README.md:19,20,23,33`: the install line becomes `gem install mcp -v 1.9.0 && gem install mcp -v 1.10.0 && …`.

### B5. Version text and re-recorded results
- `README.md:73`, `AGENTS.md:44`, `docs/architecture.md:61,70` ("pinned to 1.10.0"), plus a `docs/architecture.md` row
  after `:78`: "Invalid UTF-8 method name → −32600 (1.10.0, #672)". `docs/development.md:83`.
- `docs/protocol_compat.md:5,27-45` (the 1.8.2 rows drop when the matrix moves to 1.9.0 + 1.10.0), `:63-70`, and the new rows.
- Fixture texts naming "Ruby SDK 1.9.0" (list above): add 1.10.0 only where `compare.rb` still labels them correctly.
  Leave the #651 `_meta` texts as "(Ruby SDK 1.9.0, #651)": that's where the behaviour started.
- `mcp_official_spec.rb:439`: "unchanged on 1.9.0 and 1.10.0".
- Optional (Steve): one sentence in `docs/protocol_compat.md` that the reference servers also refuse `_meta: null`
  (graph_mem reads it as absent), and that on the 2026-07-28 lifecycle the reference answers −32600 where graph_mem answers −32602.
  Notes only, no new cases.
- Re-run `compare.rb` and `clients.sh` on Node 24 (README "Run" section) **after B6**, against the new baseline, and record the
  counts (now 19 stdio + 32 HTTP cases) in `docs/protocol_compat.md` and in the README's "Expected results", which should then
  read 1.86.1 (B6 lists those lines).

### B6. Reference servers v2.4.0 and TS client 2.4.0 (required)
The compat baseline moves from Memory 2.0.0 / Everything 2.0.1 / SDK 2.3.1 to the **servers v2.4.0** release: Everything
**2.3.0**, Memory **2.1.1**, TS SDK (`server`, `core`, `client`) **2.4.0**. Commit it before B5, so B5 records results on it.

**Override decision: the 2.3.1 override goes; the `overrides` block stays, pinned to 2.4.0.** The published servers
declare `@modelcontextprotocol/server ^2.3.1` and already resolve to 2.4.0, and the pre-check gave identical answers with
and without a 2.3.1 override. Keeping `overrides` at exactly 2.4.0 makes the SDK version explicit in `package.json`
(not only in the lock) and keeps a later `npm install` from moving it to a 2.5.x. Resolved tree (checked):
`server` 2.4.0, `core` 2.4.0, `server-legacy` 2.4.0, `node` 2.1.2, one copy each.
Pre-checked with exactly this `package.json` (overrides 2.4.0), Node 24.22.1: `compare.rb` reference run 0 failed /
0 unexpected, outlines identical to the current baseline; TS client 2.4.0 4 of 4 OK against the Ruby SDK 1.10.0 server.
graph_mem itself was not run (no database in the pre-check).

**Bind address: no harness change needed.** Everything 2.3.0 binds 127.0.0.1 by default (`HOST` widens it). Every
harness URL is already loopback: README "Run" uses `PORT=3998 node …/server-everything/dist/index.js streamableHttp` and
`--http-reference http://127.0.0.1:3998/mcp`; `compare.rb` takes the URL as given; `claude_client_check.rb` doesn't start
Everything. No `HOST` is needed in the commands; never set it to anything wider than 127.0.0.1.

Files (all paths checked on `main` at `466bab8`):

| File | Change |
|---|---|
| `script/mcp_compat/refservers/package.json` | `:4` description → "Memory 2.1.1, Everything 2.3.0 (servers v2.4.0)"; `:6` Everything `2.0.1` → `2.3.0`; `:7` Memory `2.0.0` → `2.1.1`; `:10-11` overrides `2.3.1` → `2.4.0`. |
| `script/mcp_compat/refservers/package-lock.json` | Regenerate with `(cd script/mcp_compat/refservers && npm install --ignore-scripts --no-audit --no-fund)` on Node 24. Expected about +38/−128 lines (the pre-check; jszip goes, express moves). |
| `script/mcp_compat/tsclient/package.json` | `@modelcontextprotocol/client` `2.3.1` → `2.4.0`. |
| `script/mcp_compat/tsclient/package-lock.json` | Regenerate the same way; expected about +11/−11 (`client` and `core` 2.4.0). |
| `script/mcp_compat/tsclient/tsclient.mjs:1` | "client 2.3.1" → "client 2.4.0". |
| `script/mcp_compat/clients.sh:2` | "TS client 2.3.1" → "TS client 2.4.0" (B4 changes the Ruby half of the same line). |
| `script/mcp_compat/compare.rb:4,37,39` | "the v2.0.0 reference servers" → "the v2.4.0 reference servers"; help texts "Memory 2.0.0 stdio command" → "Memory 2.1.1 …", "Everything 2.0.0 MCP URL" → "Everything 2.3.0 …". Text only, no logic. |
| `spec/requests/mcp_protocol_compat_spec.rb:10` | "the v2.0.0 reference servers" → "the v2.4.0 reference servers" (comment). |
| `spec/fixtures/mcp/handshakes/stdio.json:7,12-13` | `_comment`: reference is Memory 2.1.1; add "re-confirmed against server-memory 2.1.1 with server/core 2.4.0 (servers v2.4.0) on <run date>" after the 2026-10-24 line. **No expectation changes.** |
| `spec/fixtures/mcp/handshakes/http.json:10,14-15,310,323` | `_comment` likewise for Everything 2.3.0; divergence texts `:310` and `:323` "Everything 2.0.1" → "Everything 2.3.0". **No expectation changes.** |
| `script/mcp_compat/README.md` | `:10` "Memory 2.1.1 over stdio, Everything 2.3.0 over HTTP"; `:21` client 2.4.0; `:22` "(Memory 2.1.1, Everything 2.3.0, SDK 2.4.0)"; `:23` "TS 2.4.0"; `:37-40` rewrite: pins Memory 2.1.1 and Everything 2.3.0 (servers v2.4.0), with `server` and `core` pinned to 2.4.0 through `overrides` (`node` 2.1.2, `server-legacy` 2.4.0), lock pins the rest; **`:73-74` becomes:** "Everything 2.3.0 and later listen only on 127.0.0.1 by default (`HOST` widens the bind; the harness never sets it). Keep Everything at 2.3.0 or later: 2.0.x listened on all interfaces, and 2.0.0 also had open CORS (GHSA-mvf5-2qqv-rg3c)."; `:78-87` Expected results: 1.86.1, `mcp` 1.10.0, Memory 2.1.1, Everything 2.3.0, SDK 2.4.0, the Node version used, 19 stdio + 32 HTTP cases, clients rows "TS 2.4.0, Ruby SDK 1.9.0 and 1.10.0". |
| `docs/protocol_compat.md` | `:34-37` "TS client 2.4.0"; `:63-64` run line (date, 1.86.1, `mcp` 1.10.0, Memory 2.1.1, Everything 2.3.0, SDK 2.4.0, Node version); `:76` column "Memory 2.1.1"; `:101` column "Everything 2.3.0"; `:204,206` "Everything 2.3.0"; one line under the HTTP list that Everything now binds loopback by default. Outlines in the tables stay as they are (they were identical in the pre-check). |

Leave alone: `docs/plans/**` (history), CHANGELOG entries of earlier releases, `script/mcp_compat/README.md:34`
(`# Node >= 20` still holds: client 2.4.0 declares `engines.node >=20`) and `:36` (`Node >= 24` still holds for both servers).

B6 checks (on top of the general acceptance criteria):
- `npm ci --ignore-scripts` works from the committed locks in both folders on Node 24; `npm ls @modelcontextprotocol/server`
  in `refservers/` shows one 2.4.0 copy.
- `compare.rb` against the new servers: 0 failed expectations, 0 unexpected differences, and the reference outlines are the
  same as at 1.72.0 for every existing case (the A3 rows included). If any reference outline changes, stop and ask before
  editing an expectation.
- `clients.sh`: 12 of 12 OK with TS 2.4.0.
- `rg -n "2\.0\.1|Memory 2\.0\.0|client 2\.3\.1|all interfaces" script/mcp_compat spec/fixtures/mcp spec/requests/mcp_protocol_compat_spec.rb docs/protocol_compat.md`
  finds nothing (the rewritten README sentence names only `2.0.x` and `2.0.0`; `node_modules` isn't committed).
- The lock diffs touch only `@modelcontextprotocol/*`, `express`'s tree and `jszip`'s removal; anything else (a new top-level
  package, an install script): stop and ask.

### B7. MCP Apps plan references (`docs/plans/mcp-apps-plan.md`)
Docs only; no Apps code. At `466bab8`:
- `:175-177`: "graph_mem pins `gem "mcp", "1.9.0"` … The newest release is **1.10.0** … No bump is needed for this train;
  a bump stays its own … hard stop." → graph_mem pins `"1.10.0"` since 1.86.1 (this plan); nothing in 1.10.0 is for Apps
  or resources; a further bump stays its own PR and a hard stop.
- `:179` "What **1.9.0 already has**" → "What **1.9.0 and 1.10.0 have**" (`lib/mcp/apps.rb` is identical in both tags).
- `:190` `lib/mcp/server.rb:1679-1685` → `lib/mcp/server.rb:1691-1697` (`normalize_capabilities`, same code).
- `:82` the hard-stop example "(including `mcp` 1.9.0 → 1.10.0)" → "(such as an `mcp` bump past 1.10.0)".
- `:205` "Also in 1.9.0, not used here: the Skills extension" → "Also in 1.9.0 and later, …".
- Leave the status lines (`:3-10`, the review history at `9df8556`/`cb44409`) as they are.

### RB. Release 1.86.1
- `lib/graph_mem/version.rb` → `1.86.1`, then `bin/rails graph_mem:sync_skill_version` (sets `SKILL.md:18` and the
  `README.md:7` badge; `spec/docs/agent_text_sync_spec.rb` compares them). Don't edit `version.rb` or SKILL.md while the
  full suite is running.
- CHANGELOG `## [1.86.1] - <date>` at the top:
  - Changed: "An MCP request whose method name is not valid UTF-8 is refused as an invalid request (-32600) instead of an internal error (mcp 1.10.0)."
  - Changed: "The compat harness's reference baseline is the MCP servers release v2.4.0 (Everything 2.3.0, Memory 2.1.1, TS SDK 2.4.0); Everything now listens only on loopback by default."
  - Dependencies: `mcp` 1.9.0 → 1.10.0.

## Version and train

- **1.86.1, a patch release**, as 1.58.1 and the 1.9.0 plan's default: a dependency bump plus one wire-behaviour change
  on malformed input, no surface change.
- **Train (Steve, 2026-11-13):** 1.86.1 this plan → 1.86.2 and 1.86.3 (other fixes; 1.86.3 may fold into 1.86.2) →
  MCP Apps 1.87.0 / 1.88.0 / 1.89.0. If another PR lands on `main` first, this one takes the next free patch number and
  renumbers its CHANGELOG heading and `version.rb`. Never bundle the bump into an Apps PR (a hard stop there).
- **Dependabot / bundle.** `dependabot.yml` watches bundler and Actions daily, **not** the npm lockfiles under
  `script/mcp_compat/`. If Dependabot opens "Bump mcp from 1.9.0 to 1.10.0", don't base work on it; this PR is the D14
  path, and Steve closes Dependabot's PR once this merges. A pending generic `bundle update` goes in its own commit on
  `main` first (json stays on 3.x), so B1's lock diff stays `mcp`-only.

## Size

About 3 hours: B1 10 min, B2 30 min, B3 30 min, B4 15 min, **B6 45 min** (two lock regenerations, text edits, one compare and clients run on the new baseline), B5 30 min (re-record on the new baseline), B7 10 min, RB 10 min. Expected diff: about 500 lines, about 200 of them lockfiles.

## Decisions (defaults; Steve may change any)

1. **Exact pin** `"1.10.0"` (D14).
2. **Patch release 1.86.1** (first in the approved train).
3. **Client matrix becomes 1.9.0 + 1.10.0** (12 rows). Keeping 1.8.2 (16 rows) is the alternative.
4. **Invalid UTF-8 method name is a documented divergence** (B3).
5. **Reference baseline is servers v2.4.0** (Everything 2.3.0, Memory 2.1.1, TS SDK 2.4.0), with `overrides` pinned to 2.4.0 instead of 2.3.1 (approved 2026-11-13).
6. **No `stream_write_timeout:` option**: the gem default (10 s) applies.

## Acceptance criteria

- The lock diff is `mcp` only. The full suite is green on CI (CircleCI rspec, rubocop, brakeman; Actions lint, scan_ruby, scan_js).
- The #629 and non-object `_meta` specs still pass unchanged. The new −32600 specs pass on 1.10.0 and the HTTP one fails on 1.9.0.
- The tools/list snapshots are byte-identical. Tool counts are unchanged (12 / 9 / 22).
- `compare.rb` on the **v2.4.0 baseline** (Everything 2.3.0, Memory 2.1.1, SDK 2.4.0): 0 failed expectations, 0 unexpected
  differences, the A3 rows still documented divergences with the same outlines as 1.72.0, plus the new case. `clients.sh`
  (TS 2.4.0, Ruby SDK 1.9.0 and 1.10.0): 12 of 12 OK.
- The B6 checks pass (locks install with `npm ci`, one SDK copy, no stale version text, README bind sentence rewritten).
- No expectation in `spec/fixtures/mcp/handshakes/` changes; only `_comment` and divergence texts do.
- `docs/plans/mcp-apps-plan.md` names 1.10.0 as the pin and `server.rb:1691-1697` (B7); `spec/docs` passes.
- No real hostnames, IPs, usernames or home paths in docs. Synthetic data only.

## Stop and ask Steve if

- the lock diff touches anything other than `mcp`;
- any existing spec, fixture expectation or snapshot changes (other than the version text listed above);
- **any MCP param or output would change** (input/output schema, `structuredContent` keys, result text, a new tool,
  an `x-mcp-header` declaration, a new capability). New MCP params or outputs need Steve's direct approval;
- **any profile's tool count changes.** Default `/mcp` is 12 today; Steve's budget is about 20 hard, under 15 preferred,
  and this PR adds none;
- a new gem, migration or non-stdlib package is needed (B6's pin changes are approved; any other npm package, or a lock change outside the B6 list, is not);
- a reference outline changes on the v2.4.0 servers, or a fixture expectation would have to change;
- the diff goes past ~3,000 lines;
- anything would weaken the `/mcp` `AccessGate`, the lockdown, or the anonymizer/cloud gate;
- `handshake_cases.rb` / `compare.rb` can't express the new case without code changes;
- a newer `mcp` release has appeared by the time of the PR (re-plan rather than skip a version);
- another PR has merged first (renumber to the next patch);
- newer reference servers or TS SDK than v2.4.0 / 2.4.0 have been released by then (re-plan, don't silently take them).
