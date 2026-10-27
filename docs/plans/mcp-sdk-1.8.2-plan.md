# MCP SDK 1.8.2 + reference servers v2.1.0 → graph_mem 1.58.1 / 1.58.2 (gem bump, encoding regression spec, CORS from the allowlist, scan hardening)

**Written 2026-10-27 (Europe/Rome)** for Claude, from the 1.58.0 code (`75136ad`, #129 merged, tagged `v1.58.0`).
Every file:line in "What the code looks like today" was checked against `75136ad`. If a line has moved, find the code
by the quoted text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.
The investigation only read code (graph_mem, `modelcontextprotocol/ruby-sdk` v1.8.1..v1.8.2, `modelcontextprotocol/servers`
v2.1.0, `rack-cors` 3.0.0, the published npm packages). **No spec, `compare.rb` or `clients.sh` was run** while
writing it: the PRs are checked by running the suite locally and by CI (CircleCI: rspec, rubocop, brakeman; Actions:
lint, scan_ruby, scan_js).

Context: `docs/plans/mcp-update-plan.md` (DONE; its D-nn decisions still apply), `docs/guides/migrating-fast-mcp-to-mcp-gem.md`
(D1–D14, notably **D4** allowed origins, **D5** CORS left to `rack-cors`, **D14** exact pin, one PR per upgrade),
`docs/protocol_compat.md`, `script/mcp_compat/README.md`, `docs/mcp_access_control.md`. This plan is self-contained.
It does **not** move the UI train: UI-2 stays **1.59.0**.

## Brief

| | |
|---|---|
| **Branches / PRs** | **Three small PRs**, each off `main` after the previous one merges. **PR-A** `claude/mcp-1.8.2`, title `mcp 1.8.2, Everything 2.0.1 harness (1.58.1)`: steps A1–A5 + release RA. **PR-B** `claude/mcp-cors-allowlist`, title `CORS for /mcp from GRAPH_MEM_MCP_ALLOWED_ORIGINS (1.58.2)`: steps B1–B3 + release RB. **PR-C** `claude/scan-symlink-hardening`, title `Project scan: don't follow symlinked children`: steps C1–C2, CHANGELOG under `## [Unreleased]`, **no bump** (see Decision 5). Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | PR-A: **A1** gem bump, **A2** encoding regression spec (+ compat cases), **A3** Everything 2.0.1, **A4** version text, **A5** re-recorded results, **RA** release. PR-B: **B1** CORS, **B2** specs + compat cases, **B3** docs, **RB** release. PR-C: **C1** code + specs, **C2** docs. Review fixes go in new commits; no force-push after review starts. |
| **Scope** | No tool, prompt, resource or `/api/v1` changes. No change to `GraphMem::OfficialMcp` behaviour beyond the gem bump. `/api/*` and `/api-docs*` CORS stay exactly as they are. `docs/guides/migrating-fast-mcp-to-mcp-gem.md` stays at 1.8.1 (it documents a finished migration; Decision 7). |
| **Data** | Synthetic fixtures only (`SynthClient`, `synth-ui.localhost`, temp dirs from `spec/support/scan_root_helpers.rb`). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (spec hygiene, test-DB truncate, done criteria), `script/mcp_compat/README.md`. |

## Upstream changes (verified)

### `mcp` gem 1.8.2 (published 2026-10-27 02:01 Rome)

`v1.8.1..v1.8.2`: 17 files, +611/−27, mostly tests. No dependency change (`json_schemer >= 2.4` only), so the lock
diff is the `mcp` lines alone. No breaking API change; one "Changed" entry (#632).

| PR | Change | graph_mem |
|---|---|---|
| #629 | `JsonRpcHandler.handle_json(…, on_generate_error:)` + `encodable_response`: a reply that can't be generated (`JSON::GeneratorError`, e.g. a string with invalid UTF-8 echoed back) is answered **−32603 "Internal error" with the request id**; in a batch only that item is replaced. `Server#handle_json` reports the error as `{ error: "Failed to generate response" }`. Over stdio a bad batch item now carries its id. On 1.8.1, JSON response mode and the 2026-07-28 path answered **HTTP 500**. | **Applies.** graph_mem runs JSON response mode (`transports.rb:30`). The JSON parser lets invalid bytes through **inside string values** (it refuses them in keys: that's the existing −32700 case, `http.json:211-218`). The gem echoes the tool name in `"Tool not found: #{tool_name}"` (`lib/mcp/server.rb:1310` in the gem), so `tools/call` with an invalid-UTF-8 name is a one-request trigger. Reporting reaches `Rails.error` through `OfficialMcp::EXCEPTION_REPORTER` (`official_mcp.rb:10-12, 18-20`). No spec covers it today. |
| #632 | `subscriptions/listen` consults `resources_subscribe_handler` per URI. | **No.** `resources: { subscribe: false }` (`server_factory.rb:12-16`), no subscribe handler; fixtures assert it (`http.json:134-139`, `:182-189`). |
| #630, #631 | Buffered notification that can't be generated is dropped; session notify rescues use the configured reporter. | **No.** graph_mem sends no notifications. |
| #627, #628 | Client: stdio frames stripped as bytes; pings with unencodable ids skipped. | Test tooling only (`rsdk_client.rb`, `clients.sh`). |
| #633 | Docs. | No. |

The gem's stdio `send_response` is **unchanged** between 1.8.1 and 1.8.2, so graph_mem's override
(`stdio_transport.rb:16-20`, same body writing to an explicit IO) needs no change. Re-check it on every bump.

### Reference servers v2.1.0 (published 2026-10-25 02:03 Rome)

Eight advisories, all published 2026-10-25, **no CVE id yet** (`cve_id: null`). Fixed: `server-filesystem` 2.0.1,
`server-everything` 2.0.1, `mcp-server-fetch` 2026.10.24. Date-versioned installs get no patched date version;
`npm` ranks 2.0.1 below the date versions. graph_mem pins exact semver, so this doesn't bite here.

| GHSA | Package | Severity | Relevance to graph_mem |
|---|---|---|---|
| GHSA-mvf5-2qqv-rg3c | everything | Moderate 6.5 | **The harness runs the vulnerable 2.0.0** (`refservers/package.json:6`). 2.0.1 adds `localhostOriginValidation()` (403 for a non-localhost `Origin`, preflights included; no `Origin` passes) and then `cors({ origin: true })`: CORS only grants an origin that passed the check. That is the model for PR-B. |
| GHSA-53mr-w429-c597 | filesystem | Low 2.2 | Write TOCTOU. graph_mem never writes into scanned trees; read-side analogue below (PR-C note). |
| GHSA-7rgq-gccq-qphx | filesystem | Moderate 4.2 | Check/use mismatch on trailing quote/space. **Not affected**: `resolver.rb:19` strips once and uses the same string for the checks and `File.realpath`. |
| GHSA-4gxg-m5jx-9j57 | filesystem | Moderate 5.3 | Case-variant symlink on case-insensitive volumes. Analogue: `contained?` is a plain prefix check on realpaths (`scan_root_policy.rb:88-90`). Linux/container: n/a. Native macOS: depends on `File.realpath` returning on-disk case (unverified). PR-C note. |
| GHSA-hhwq-wxfx-cj7g | filesystem | Low 3.1 | Metadata leak through symlinked entries. Analogue: `File.directory?` follows symlinked children at `project_scan_skill.rb:413` and `:478`. PR-C. |
| GHSA-v38p-wf49-hx2j, GHSA-66qx-2266-pmj6, GHSA-3jqg-r5pp-rmp2 | fetch | Medium / Low 3.1 / Low 3.1 | **N/A**: graph_mem has no URL-fetch tool. |

`server-everything` 2.0.1 has the same dependency ranges as 2.0.0 (`@modelcontextprotocol/node ^2.1.1`,
`server ^2.3.1`, `server-legacy ^2.3.1`). `npm install --package-lock-only` against today's lock changes **only** the
`server-everything` entry (version, resolved, integrity); the `server`/`core` 2.3.1 overrides stay. Both 2.0.0 and
2.0.1 declare `engines: node >=24` (the README's last run says Node 22). Everything's HTTP server calls
`app.listen(port)` with **no host option**, so it can't be bound to 127.0.0.1 by configuration.

## What the code looks like today (verified at `75136ad`)

- **Pin.** `Gemfile:35-36` (comment "Exact pin: one PR per upgrade (D14)", `gem "mcp", "1.8.1"`); `Gemfile.lock:228`
  `mcp (1.8.1)`, `:526` `mcp (= 1.8.1)`. `json (2.21.2)` (`Gemfile.lock:181`). `lib/graph_mem/version.rb:4`
  `VERSION = "1.58.0"`. `CHANGELOG.md` starts at `## [1.58.0] - 2026-10-26`; **there is no `## [Unreleased]`**.
- **Transport.** `lib/graph_mem/official_mcp/transports.rb:28-36` `options`: `enable_json_response: true` (30),
  `allowed_hosts` (33), `allowed_origins: list(ENV["GRAPH_MEM_MCP_ALLOWED_ORIGINS"])` (34); `list` (44-46) splits on
  commas. Built per profile (40-42); `reset!` (19-22).
- **Reporting.** `lib/graph_mem/official_mcp.rb:10-12` `EXCEPTION_REPORTER` → `Rails.error.report(…, handled: true,
  context: { mcp: … })`; server config (18-20); global `MCP.configure` (`config/initializers/mcp.rb:24`).
- **Middleware.** `config/initializers/cors.rb`: `insert_before 0, Rack::Cors` (6). Block 1 (7-29): origins
  `"localhost", "127.0.0.1", "::1"` and `/\Ahttp:\/\/localhost(:\d+)?\z/`, `/\Ahttp:\/\/127\.0\.0\.1(:\d+)?\z/` (9-11),
  resources `/api/*` (13-17), **`/mcp/*` (19-23)**, `/api-docs*` (25-28). Block 2 (36-55): `lan_192`, `lan_10`,
  `lan_172` (32-34), same three resources, **`/mcp/*` at 45-49**. Line 4: "The transport also emits headers for raw
  hijacked SSE responses." is fast-mcp text (the gem emits no CORS headers; guide D5). `config/initializers/mcp.rb`
  adds `AccessGate`, `RequestContext`, `Router` with `middleware.use` (26-28); none of them reads the body.
- **rack-cors 3.0.0 behaviour** (`Gemfile.lock:300`): every preflight (`OPTIONS` + `Access-Control-Request-Method`)
  is answered **200** by the middleware itself, with CORS headers only when the origin matches; a bare string such as
  `"localhost"` matches `<any scheme>://localhost` without a port; a `Proc` origin is called per request as
  `(source, env)`. `"/mcp/*"` compiles to `^/mcp\/?(.*?)$`, so it also covers `/mcp`.
- **The drift.** The gem accepts a browser `Origin` only when same-origin or listed in `GRAPH_MEM_MCP_ALLOWED_ORIGINS`
  (exact `scheme://host:port`, `docs/mcp_access_control.md:45, 53-59`). Rack::Cors grants `/mcp` CORS to a different
  set: any `http://localhost:*`, `http://127.0.0.1:*`, any scheme on bare `localhost`/`127.0.0.1`, and every RFC1918
  `http://` IP origin. So:
  1. an origin Rack::Cors allows but the gem doesn't (e.g. `http://localhost:5173`, `http://192.168.1.20:3000`) passes
     the preflight and then gets 403 on the POST: noisy, not a hole;
  2. **an origin the gem allows but Rack::Cors doesn't** (anything with a host name or `https`, e.g.
     `http://synth-ui.localhost:3001` from the existing spec, or `https://graphmem.lan`) gets **no
     `Access-Control-Allow-Origin` on the preflight**, so a browser client on an allow-listed origin can't connect.
     That is a real bug: the documented setting doesn't work for browsers unless the origin also happens to match
     the Rack::Cors patterns.
  `docs/mcp_access_control.md:154-155`: "CORS preflight (`OPTIONS`) is answered by `rack-cors` … before the token
  check, so browser-based clients can send credentials." `.env.example:43` shows
  `# GRAPH_MEM_MCP_ALLOWED_ORIGINS=http://localhost:3001`.
- **Specs.** `spec/requests/mcp_official_spec.rb`: `with_env` (24-32), `initialize_session(path, version:, headers:)`
  (34-40), host `localhost` (14); foreign Host/Origin → 403 (185-198); allow-listed Origin accepted (200-204);
  **"CORS preflight (rack-cors)" (286-297)** asserts a preflight from `http://localhost:3001` on each profile gets 200,
  `access-control-allow-methods` ⊇ POST and `access-control-expose-headers` ⊇ `Mcp-Session-Id`, **without** that
  origin being allow-listed. Nothing sends an invalid-UTF-8 string value; nothing checks a −32603.
- **Compat harness.** `script/mcp_compat/handshake_cases.rb:39-45` `http_body` supports `body_hex`, `body_raw`,
  `body`; cases may carry `request.headers` (e.g. `http.json:155`); expectations check `status` alone if that's all
  they give (82). `spec/requests/mcp_protocol_compat_spec.rb` runs the same fixtures in the normal suite (HTTP through
  Rails, stdio through subprocesses). **No case sends an `Origin` header.** Highest JSON-RPC id used in `http.json`
  is 41. `refservers/package.json:4` description says "The v2.0.0 MCP reference servers", `:6`
  `server-everything 2.0.0`, `:7` `server-memory 2.0.0`, overrides `server`/`core` 2.3.1 (9-12).
  `script/mcp_compat/README.md:56` runs Everything with `PORT=3998`.
- **Version text "1.8.1"** (excluding `Gemfile.lock`, CHANGELOG, plans, and the migration guide, which stays):
  `AGENTS.md:44`; `README.md:71`; `docs/architecture.md:59` and `:68` (feature-map column header "`mcp` gem 1.8.1");
  `docs/development.md:81`; `docs/protocol_compat.md:5`, client matrix `:36-43`, `:66`, divergence notes
  `:143, :145, :164`; `script/mcp_compat/README.md:19, 20, 22 ("2.0.0"), 23, 33, 75-80`; `clients.sh:2, 12, 22`;
  `rsdk_client.rb:4, 11, 16`; `rsdk_server.rb:4, 15`; fixture divergence notes `http.json:218`, `stdio.json:160, 198`.
  (`NOTICE.md:6-9` "fast-mcp 1.8.0" and `docs/garbage_collector.md:120` "v1.8.1" are unrelated; leave them.)
- **Project scans.** `app/services/project_scan_skill.rb` (553 lines): the job re-resolves the root (`initialize`,
  46-49: `ScanRootPolicy.resolve`, `ProjectScanFileFilter.new(@project_root)`). Architecture pass (180-199): checks
  each `source_dirs` entry is inside the root (185), then `Dir.children(full_dir)` → `architecture_child_name_and_type`
  (476-485), whose **`File.directory?(full_child)` (478) follows a symlinked child** to wherever it points.
  `top_level_directories` (408-417): **`File.directory?(full)` (413) follows symlinks the same way**. Files to read go
  through `@file_filter.kept_path(f) if File.file?(f)` (404); `kept_path`
  (`app/services/project_scan_file_filter.rb:44-50`) returns the checked realpath or nil. The read itself happens
  later (`File.readable?` 439, `File.binread(file, [File.size(file), max_bytes].min)` 441), so a path component
  swapped between the check and the read could redirect a read (needs local write access to the scanned tree; the
  container mount is read-only). `ScanRootPolicy#contained?` (`scan_root_policy.rb:88-90`) is a string prefix check
  on real paths.

## PR-A → 1.58.1: `mcp` 1.8.2, encoding regression spec, Everything 2.0.1

### A1. Gem bump
- `Gemfile:36` → `gem "mcp", "1.8.2"`; `bundle update mcp --conservative`. The lock diff must be the two `mcp` lines
  only; if anything else moves, stop and ask.

### A2. Invalid-UTF-8 reply → −32603 with the id (the #629 regression spec)
- `spec/requests/mcp_official_spec.rb`, new example in the transport/protocol area: open a session, then POST a raw
  body (build it as a binary string, not with `to_json`):
  `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"synth-\xFF","arguments":{}}}`. Expect **HTTP 200**,
  a JSON body with `"id": 7` and `error.code == -32603`, and **not** 500. Stub/spy `Rails.error.report` and assert one
  call received a `JSON::GeneratorError` (there will also be a report for the `Tool not found` error itself, so
  don't assert an exact count).
  Use a raw `0xFF` byte in a string value, as the gem's own tests do; don't rely on a `"\ud800"` escape (whether it
  yields invalid UTF-8 depends on the `json` gem's surrogate handling).
- Same on `/mcp/readonly` is enough as one extra `it` line; profiles share the transport code.
- Compat fixtures (they also run in `mcp_protocol_compat_spec.rb`):
  - `http.json`, new case after "an invalid UTF-8 object key": name `"tools/call with an invalid UTF-8 tool name"`,
    `"session": "new"`, `"request": {"body_hex": "7b226a736f6e727063223a22322e30222c226964223a34322c226d6574686f64223a22746f6f6c732f63616c6c222c22706172616d73223a7b226e616d65223a2273796e74682dff222c22617267756d656e7473223a7b7d7d7d"}` (the body above with id 42; `ff` is the raw byte), graph_mem expects
    `{"status": 200, "id": 42, "error_code": -32603}`. Reference: run it against Everything 2.0.1 and record what it
    does (Node decodes the byte as U+FFFD; expect a tool-not-found error or `isError` result). If it differs, add a
    `divergence` note: "graph_mem can't echo the invalid name back and answers −32603 (Ruby SDK 1.8.2, #629); Node
    decodes the byte as U+FFFD and answers <what it does>."
  - `stdio.json`: the same request as a single line (id 42) → graph_mem `{"id": 42, "error_code": -32603}` and the
    session keeps serving (follow with a ping, as `stdio.json:189-199` does).
- On 1.8.1 the HTTP example would get 500. Run it once against 1.8.1 before A1 if convenient and say so in the PR.

### A3. Harness: Everything 2.0.1
- `script/mcp_compat/refservers/package.json:6` → `"@modelcontextprotocol/server-everything": "2.0.1"`; `:4`
  description → "The MCP reference servers (Memory 2.0.0, Everything 2.0.1) that compare.rb replays the cases
  against". Memory stays 2.0.0 (unchanged upstream).
- `cd script/mcp_compat/refservers && npm install --package-lock-only --ignore-scripts --no-audit --no-fund`, then
  `npm ci --ignore-scripts`. Expected lock diff: only the `server-everything` entry (and the root `dependencies`
  line). Overrides untouched.
- `script/mcp_compat/README.md`: next to the run block (`:54-57`), one sentence: Everything listens on all interfaces
  (it has no host option), so run the harness only on a trusted machine, and keep Everything at ≥ 2.0.1
  (GHSA-mvf5-2qqv-rg3c). Use Node ≥ 24 (`engines` of both servers).

### A4. Version text
- Change "pinned to 1.8.1" → "pinned to 1.8.2" at `AGENTS.md:44`, `README.md:71`, `docs/development.md:81`,
  `docs/protocol_compat.md:5`, `docs/architecture.md:59`; `docs/architecture.md:68` column header → "`mcp` gem
  1.8.2" (check that no row of the feature map changes; #629 is the only behaviour change and the map has no row for
  it; if there's a natural "errors" row, add "an unencodable reply → −32603 with the id (1.8.2)").
- `clients.sh` matrix (Decision 1): `RSDK_VERSIONS` default `"1.8.1 1.8.2"` (`:22`), header comment (`:2`, `:12`),
  still 12 rows. `rsdk_client.rb:4, 11, 16` and `rsdk_server.rb:4, 15` default `1.8.2`; `:11` install line
  `gem install mcp -v 1.8.1; gem install mcp -v 1.8.2`. `script/mcp_compat/README.md:19-23, 33` likewise
  (Everything 2.0.1 at `:22`).
- Fixture divergence notes `http.json:218`, `stdio.json:160, 198`: re-check each still holds on 1.8.2 (they should:
  #629 changes only the generation of replies), then change "Ruby SDK 1.8.1" → "Ruby SDK 1.8.2". Same text in
  `docs/protocol_compat.md:143, 145, 164`.

### A5. Re-record the results
- Run, from the checkout (commands in `script/mcp_compat/README.md`): `compare.rb` against graph_mem, Everything 2.0.1
  and `rsdk_server.rb` (1.8.2), and `clients.sh`. Update `docs/protocol_compat.md` (client matrix `:25-43` with
  1.8.1 + 1.8.2 rows; the case counts in "Handshake comparison"; any new divergence) and the "At 1.55.1" block in
  `script/mcp_compat/README.md:75-80` → "At 1.58.1 (<date>; reference servers Memory 2.0.0, Everything 2.0.1, SDK
  2.3.1, on Node <version>)". Expected: 0 failed expectations, 0 unexpected differences, 12 of 12 clients.
- If `compare.rb` shows an unexpected difference from Everything 2.0.1 (e.g. a new header or Origin behaviour on
  Origin-less requests), stop and ask: don't paper over it with a `divergence` note.

### RA. Release 1.58.1
- `lib/graph_mem/version.rb` → `1.58.1`. CHANGELOG `## [1.58.1] - <merge date>`:
  - **Security:** "The compatibility harness runs `@modelcontextprotocol/server-everything` 2.0.1
    (GHSA-mvf5-2qqv-rg3c: open CORS on 2.0.0)."
  - **Changed:** "`mcp` gem 1.8.2."
  - **Fixed:** "A reply that can't be encoded as JSON (e.g. an invalid UTF-8 tool name echoed in its error) gets
    −32603 with the request id instead of HTTP 500 (mcp 1.8.2)."
  - **Added** (tests): the regression spec and the two compat cases.

## PR-B → 1.58.2: CORS for `/mcp` from `GRAPH_MEM_MCP_ALLOWED_ORIGINS`

### B1. One allowlist (Decision 3, option A)
- `lib/graph_mem/official_mcp/transports.rb`: extract `def allowed_origins = list(ENV["GRAPH_MEM_MCP_ALLOWED_ORIGINS"])`
  (public, documented) and use it in `options` (`:34`), so the transport and CORS read the same list.
- `config/initializers/cors.rb`:
  - Remove `resource "/mcp/*"` from both `allow` blocks (19-23, 45-49). `/api/*` and `/api-docs*` stay as they are.
  - Add a third block: `allow do; origins ->(source, _env) { GraphMem::OfficialMcp::Transports.allowed_origins.include?(source) }; resource "/mcp/*", headers: :any, methods: %i[get post delete options], expose: %w[Mcp-Session-Id], max_age: 86_400; end`.
    The Proc runs per request, so a changed env + `OfficialMcp.reset!` (specs) is picked up without reloading the
    middleware. Check the constant is loadable when the Proc first runs (it's `require_relative`d by
    `config/initializers/mcp.rb:18`; the Proc runs only at request time, after all initializers).
  - Replace the comment at `:3-4` with: "CORS for /api, /api-docs and /mcp. /mcp grants only the origins in
    GRAPH_MEM_MCP_ALLOWED_ORIGINS, the same list the MCP transport's Origin check accepts (same-origin pages need no
    CORS). The transport itself sends no CORS headers."
  - Optional, same commit: drop the `"::1"` entry at `:9` (rack-cors turns it into `<scheme>://::1`, which no browser
    sends; an IPv6 origin is `http://[::1]:port`). Only if the `/api` specs stay green.
- Same-origin browser pages and non-browser clients (no `Origin`) are unaffected. A browser on an un-listed
  localhost/LAN origin now gets no `Access-Control-Allow-Origin` on the preflight instead of a 403 on the POST:
  same outcome, earlier.

### B2. Specs and compat cases
- `spec/requests/mcp_official_spec.rb` "CORS preflight (rack-cors)" (286-297): wrap in
  `with_env("GRAPH_MEM_MCP_ALLOWED_ORIGINS" => "http://localhost:3001")` and additionally assert
  `access-control-allow-origin == "http://localhost:3001"`. New examples:
  1. an allow-listed host-name origin (`http://synth-ui.localhost:3001`) gets `access-control-allow-origin` on the
     preflight **and** a session on the POST (today it gets no CORS header: this example fails on `main`);
  2. an un-listed `http://localhost:5173` and an un-listed `http://192.168.1.20:3000` get a preflight with **no**
     `access-control-allow-origin`, and 403 on the POST;
  3. `/api/*` preflight from `http://localhost:5173` still gets its CORS headers (regression guard for the untouched
     blocks; use any existing `/api/v1` GET path).
- `http.json` (runs in `mcp_protocol_compat_spec.rb` too), `"session": "none"`, an `initialize` body, ids 43/44:
  - `"an initialize from a foreign Origin"`: `request.headers: {"Origin": "http://evil.example"}` → graph_mem
    `{"status": 403}`, reference `{"status": 403}` (Everything 2.0.1). Expected "same".
  - `"an initialize from another localhost port"`: `{"Origin": "http://localhost:5173"}` → graph_mem
    `{"status": 403}`, reference `{"status": 200, "id": 44, "result_has": ["protocolVersion"]}`, `divergence`:
    "Everything 2.0.1 accepts any localhost origin; graph_mem accepts only same-origin and
    GRAPH_MEM_MCP_ALLOWED_ORIGINS (exact scheme://host:port)."
  - Check in the request spec what `Host` the compat spec sends, so `http://localhost:5173` is not same-origin there.
- Re-run `compare.rb`; update the counts and "Known divergences" in `docs/protocol_compat.md`. Note there too that
  graph_mem answers every preflight 200 (rack-cors) and simply omits the CORS headers for an un-listed origin, where
  Everything answers 403: the browser blocks either way.

### B3. Docs
- `docs/mcp_access_control.md:45` (the `GRAPH_MEM_MCP_ALLOWED_ORIGINS` row): add "The same list is the only one
  granted CORS on /mcp." `:154-155`: "CORS preflight (`OPTIONS`) on /mcp is answered by `rack-cors` before the token
  check, with CORS headers only for an origin in `GRAPH_MEM_MCP_ALLOWED_ORIGINS`."
- `docs/troubleshooting.md:33`: a browser client blocked by CORS needs its exact origin in
  `GRAPH_MEM_MCP_ALLOWED_ORIGINS`; nothing else grants it.
- `.env.example:43`: comment line above it: "Browser-based MCP clients: exact origins, also used for CORS."

### RB. Release 1.58.2
- `version.rb` → `1.58.2`. CHANGELOG `## [1.58.2] - <merge date>`:
  - **Fixed:** "A browser client on an origin listed in `GRAPH_MEM_MCP_ALLOWED_ORIGINS` gets the CORS headers it
    needs on /mcp; before, only localhost and private-IP `http://` origins did, whether listed or not."
  - **Changed / Security:** "/mcp grants CORS only to `GRAPH_MEM_MCP_ALLOWED_ORIGINS` (the transport's Origin list),
    no longer to every localhost port and private-network origin. /api is unchanged."

## PR-C → `[Unreleased]`: project scan doesn't follow symlinked children

### C1. Code and specs
- `project_scan_skill.rb:478`: `if File.directory?(full_child)` → `if File.lstat(full_child).directory?` (a symlink
  is then named as a file-like child, never followed). Rescue `SystemCallError` around it (a child removed mid-scan)
  and skip the child (`return [ nil, nil ]`, which the caller at `:191` already skips via `name.blank?`).
- `project_scan_skill.rb:413` (`top_level_directories`): same change, `File.lstat(full).directory?`; the existing
  `rescue SystemCallError` (415) stays.
- Keep `:404` as is (`kept_path` already rejects anything resolving outside the root); add a comment at `:439-441`:
  "Reads the realpath kept_path checked. A component swapped after that check could still redirect the read; that
  needs write access to the scanned tree (scan mounts are read-only in the container)." No `O_NOFOLLOW` rewrite
  (Decision 6).
- Specs (`spec/services/project_scan_skill_spec.rb`, temp dirs from `scan_root_helpers.rb`): (1) a project with
  `lib/outside -> <tmp dir outside the root>` (a directory) records `outside` with a non-`Component` type (or not as
  a directory) and never lists the target's entries; (2) a top-level symlink to an outside directory is not in
  `top_level_directories`; (3) a real subdirectory is still a `Component`.

### C2. Docs
- `docs/container_scan_mounts.md` (it already discusses symlinks): one line on symlinked
  children, and a note: "On a case-insensitive filesystem (native macOS) the containment check compares real paths
  as strings; it relies on `File.realpath` returning the on-disk case. Containers and Linux are unaffected."
- CHANGELOG `## [Unreleased]` › **Security**: "Project scans no longer follow a symlinked child to test whether it's
  a directory."

## Later (not in these PRs)

- **AR-E** eval harness, **AR-F** (only after the eval), **AR-D4** docs follow-ups: `agent-rules-plan.md`; still
  open and unscheduled (`ui-dashboard-plan.md` §0.3 rows 1a–1c).
- **D-7** query length cap and **D-8** tool description length spec: `ui-dashboard-plan.md` §6.D, Devin-simple,
  ship any time.
- Future gem bumps: re-check the `stdio_transport.rb` override and the fixture "Ruby SDK x.y.z" notes each time. If
  resource subscriptions are ever added, put the authorization check in `resources_subscribe_handler` (#632).

## Specs (summary)

| PR | New / changed |
|---|---|
| A | `mcp_official_spec.rb`: invalid-UTF-8 tool name → 200, id, −32603, `JSON::GeneratorError` reported. `http.json` + `stdio.json`: one case each (id 42). |
| B | `mcp_official_spec.rb`: preflight block under `with_env`, allow-listed host-name origin works, un-listed localhost/LAN origins get no CORS header and 403, `/api` CORS unchanged. `http.json`: foreign Origin (same), `localhost:5173` (documented divergence). |
| C | `project_scan_skill_spec.rb`: symlinked child and top-level symlink not followed; real dirs unchanged. |

## Size and split

| PR | Version | Estimate | Diff size (guess) |
|---|---|---|---|
| A | **1.58.1** | ~1.5–2 h incl. re-recording | ~150 lines, mostly docs/fixtures |
| B | **1.58.2** | ~2–3 h | ~120 lines |
| C | `[Unreleased]` (ships with the next release) | ~1 h | ~60 lines |

## Decisions (defaults; Steve may change any)

1. **Client matrix:** `clients.sh` runs Ruby SDK **1.8.1 and 1.8.2** (drop 1.8.0), still 12 rows. 1.8.0 adds no
   signal now that graph_mem itself runs the gem.
2. **Everything 2.0.1 goes in PR-A**, so `protocol_compat.md` is re-recorded once for both bumps.
3. **CORS: option A**, build `/mcp` CORS from `GRAPH_MEM_MCP_ALLOWED_ORIGINS` (per-request Proc). Option B (drop
   `/mcp/*` from Rack::Cors) would break every allow-listed browser client; option C (leave it) keeps the bug where
   a listed host-name/`https` origin can't connect.
4. **`/api/*` CORS unchanged** in these PRs (separate surface, own consumers).
5. **PR-C has no version bump**; it rides `[Unreleased]` into the next release (1.58.x or UI-2's 1.59.0).
6. **No `O_NOFOLLOW`/fd-relative reads** in PR-C; the read race stays a documented low (read-only mounts, needs
   local write access).
7. **Migration guide stays at 1.8.1**: it records a finished migration and already tells readers to check rows
   against their pin.
8. **Patch versions 1.58.1 / 1.58.2** before UI-2; the UI train numbers don't move.

## Acceptance criteria

- PR-A: lock diff = `mcp` only; the −32603 spec passes on 1.8.2 (and would 500 on 1.8.1); refservers lock diff =
  `server-everything` only; no "pinned to 1.8.1" left outside the migration guide, CHANGELOG and plans
  (`rg -n "1\.8\.1" -g '!Gemfile.lock' -g '!CHANGELOG.md' -g '!docs/plans/**' -g '!docs/guides/**'` shows only the
  1.8.1 rows of the client matrix and `RSDK_VERSIONS`); `compare.rb` 0 failed / 0 unexpected; `clients.sh` 12/12;
  results recorded with date and Node version.
- PR-B: an allow-listed host-name origin can complete preflight + initialize; un-listed localhost/LAN origins get no
  CORS header; `/api` CORS unchanged; two new compat cases ("same", "documented divergence"); docs updated.
- PR-C: symlinked children and top-level symlinks are not followed; existing scan specs unchanged.
- All PRs: full suite green locally and on CI (rspec, rubocop, brakeman, lint, scan_ruby, scan_js); 0 rows left in
  the test DB; CHANGELOG entries; synthetic data only.

## Stop and ask Steve if

- `bundle update mcp --conservative` moves any other gem, or the refservers lock moves anything besides
  `server-everything`.
- `compare.rb` against Everything 2.0.1 shows an unexpected difference on an existing case.
- The −32603 example doesn't fail on 1.8.1 / pass on 1.8.2 as described (the trigger may be caught earlier).
- Removing `/mcp/*` from the two Rack::Cors blocks breaks anything other than the preflight spec at 286-297.
- A documented local setup depends on an un-listed localhost/LAN browser origin reaching `/mcp`.
