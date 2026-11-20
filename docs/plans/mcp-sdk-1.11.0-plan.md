# MCP SDK 1.11.0 → graph_mem 1.91.1 (gem bump, two malformed-input wire changes, compat baseline on reference servers v2.5.0)

**Status (2026-11-19): PLAN, approved, kickoff ready.** Steve approved 1.91.1 on 2026-11-19 and answered the four open
questions (see Decisions): patch release 1.91.1; SDK 1.9.0 dropped from the client matrix (12 rows); both new compat cases
added as documented differences; sub-dependency bumps in the reference servers' lockfile are fine.

**Written 2026-11-19 (Europe/Rome)** from `main` at `ef3c900` (merge of #180, tagged **v1.91.0**; `mcp` 1.10.0). Every
file:line below was checked at `ef3c900`. If a line has moved, find it by the quoted text. If the code no longer matches
the description, **stop and ask Steve** instead of improvising.
Upstream: `modelcontextprotocol/ruby-sdk` v1.10.0..v1.11.0 (22 commits, released 2026-11-19 05:56 Rome; rubygems `latest`
is 1.11.0) and `modelcontextprotocol/servers` v2.5.0 (2026-11-18 10:13 Rome). `mcp.gemspec` is **unchanged** between the
tags (still `json_schemer >= 2.4`), so the gem lock diff should be the two `mcp` lines only. The TS SDK
(`@modelcontextprotocol/server`/`core`/`client`) has no release after 2.4.0, so the TS pins don't move.

**Context.** The 1.10.0 plan (`docs/plans/done/mcp-sdk-1.10.0-plan.md`) shipped as **1.86.1**: `Gemfile:39`
`gem "mcp", "1.10.0"`, `Gemfile.lock:228` `mcp (1.10.0)`, `:529` `mcp (= 1.10.0)`. Since then: MCP Apps (1.87.0–1.89.0),
auto-adoption A (1.90.0) and B, Skills over MCP behind `mcp_skills_enabled` (1.91.0, #180). This plan is the next
"one PR per upgrade" (D14).

**What was pre-checked, and what wasn't.** The pre-check ran on a scratch checkout **without a database, so graph_mem
itself was not run** on 1.11.0: no rspec, no graph_mem column in `compare.rb`, no `clients.sh` against graph_mem. What did
run (Node 24.22.1, Ruby 3.4.12, harness and fixtures from `ef3c900`):
- `compare.rb` (reference + ruby_sdk targets, then a proxy run with `rsdk_server.rb` in the graph_mem slot) on four sets:
  {servers v2.4.0 pins, v2.5.0 pins} × {`mcp` 1.10.0, 1.11.0}.
- A synthetic probe server built like graph_mem's (custom `resources_read_handler` doing `params[:uri].to_s`, skills from a
  directory, a `ui://` resource, `enable_json_response: true`, stateful, an `allowed_origins` Array) on 1.10.0 and 1.11.0,
  over the Rack interface and `JsonRpcHandler` (stdio path). No graph_mem code.
- Direct probes of Memory 2.2.1 (stdio) and Everything 2.3.1 (HTTP) for the two new cases.
- `clients.sh` with `rsdk_server.rb` (1.11.0) standing in for graph_mem: TS 2.4.0, Ruby SDK 1.10.0 and 1.11.0.

## Brief

| | |
|---|---|
| **Status** | PLAN, approved 2026-11-19, kickoff ready. |
| **Branch / PR** | **One PR**, `claude/mcp-1.11.0`, off `main`, title `mcp 1.11.0 (1.91.1)`: B0–B6 + release RB. Steve merges and tags. Never merge, tag, push tags or run `rake release`. |
| **Commits** | **B0** generic `bundle update` (own commit, only if it changes something), **B1** gem bump, **B2** specs for the two wire changes, **B3** compat cases, **B4** harness versions, **B6** reference servers v2.5.0, **B5** version text + re-recorded results (after B6), **RB** release. Review fixes go in new commits. No force-push after review starts. |
| **Scope** | No tool, prompt, resource, skill or `/api/v1` changes, and **no new MCP params or outputs**. The only wire changes are the two gem-side error answers (#687, #688), pre-approved. No `event_store:`, `retry_interval:`, `allowed_origins: :any` or `close_sse_stream`. npm changes only in `script/mcp_compat/refservers/` (B6). `spec/fixtures/mcp/snapshots/` stays byte-identical: `/mcp` 12 tools, readonly 9, maintenance 22. `mcp_skills_enabled` and `mcp_apps_enabled` defaults unchanged. |
| **Data** | Synthetic fixtures only (`SynthClient`, `synth-*` names). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md` (imports `@AGENTS.md`), `AGENTS.md`, `script/mcp_compat/README.md`, `docs/protocol_compat.md`, `docs/plans/done/mcp-sdk-1.10.0-plan.md`, this plan. All exist on `main` at `ef3c900`. |

## Upstream changes in `mcp` 1.11.0 and what they mean for graph_mem

The 1.11.0 CHANGELOG has **no "Changed" section** (only Added and Fixed), so upstream does not call any of it a default
change under VERSIONING.md. Two Fixed entries still change graph_mem's answers to **malformed input** (#687, #688).

| PR | Change | Breaking / behaviour change? | Touches graph_mem? |
|---|---|---|---|
| #681 | Streamable HTTP resumes SSE streams (SEP-1699) **only when given `event_store:`** (optional `retry_interval:`); priming events, `Last-Event-ID` replay, `server_context.close_sse_stream` / `close_standalone_sse_stream`. `event_store:` raises in stateless mode. Without a store, `Last-Event-ID` on a GET is ignored and a plain stream opens. The notification and server→client request writers were refactored onto one `store_and_write` path for both cases. | Opt-in. Without a store: no intended change. | **No (code read + probe).** `Transports.options` (`lib/graph_mem/official_mcp/transports.rb:37-45`) passes `enable_json_response: true`, `max_sessions`, `max_request_bytes`, `allowed_hosts`, `allowed_origins`; no `event_store`, no `stateless` (so stateful). POST replies are JSON, and graph_mem sends no notifications (`server_factory.rb:10-12`) or server→client requests, so only the GET-stream keepalive uses SSE. Probe on 1.11.0: GET with `Last-Event-ID` and no store → HTTP 200 `text/event-stream`, as on 1.10.0. Adopting a store would buy nothing (nothing to replay) and is a new knob: **don't**. |
| #685 | `allowed_origins: :any` accepts every `Origin` (Host check kept); any other Symbol raises `ArgumentError`. | Opt-in. | **No.** graph_mem passes an Array of strings from `McpAccessLists` (a settings value is a String, never a Symbol). Probe: listed origin 200, other origin 403 −32600, same on both versions. `:any` would weaken the lockdown: **hard stop**, not proposed. |
| #680, #682, #683 | OAuth client: issuer selection, M2M issuer URL validation; Protected Resource Metadata accepts `*.localhost`. | Client / OAuth server only. | **No.** graph_mem has no OAuth: `/mcp` is guarded by `OfficialMcp::AccessGate` (`access_gate.rb`: `McpAccessPolicy` IP allowlist + optional static bearer `GRAPH_MEM_MCP_TOKEN`, 401 with `WWW-Authenticate: Bearer realm="graph_mem"`). No `MCP::Client`, `ProtectedResourceMetadata`, `JwtVerifier` or `IntrospectionVerifier` in `app/`, `lib/`, `config/`. |
| #686 | `JwtVerifier` answers 401 to a JWT whose header is not an object. | Server OAuth only. | **No.** `request_context.rb:55` builds an `MCP::Server::OAuth::AccessToken` only as a carrier for the request context (`lib/mcp/server/oauth/access_token.rb` unchanged); no JWT is verified. |
| #687 | `resources/read` validates `params` (a Hash with a String `uri`) **before** the read path, so before a custom `resources_read_handler`: −32602 "Invalid params", data "Missing or invalid uri". | **Wire change on malformed input.** | **Yes.** graph_mem's handler (`server_factory.rb:61,75-83`) is now reached only with a String `uri`. Probe (same handler shape), 1.10.0 → 1.11.0: no `params` **−32603 "Internal error" → −32602** (on graph_mem the 1.10.0 case would also reach `EXCEPTION_REPORTER`/`Rails.error` with a `NoMethodError`; inferred, not run); `params: {}`, `uri: null` "Resource not found: " (−32602, data `{uri: ""}`) → −32602 "Missing or invalid uri"; `uri: 123` "Resource not found: 123" → "Missing or invalid uri". Unchanged: `uri: ""`, unknown URI ("Resource not found", −32602), `ui://` reads, `skill://` reads. Same on all three profiles and stdio (shared server path). |
| #688 | Integer request ids beyond **128 bits** are refused: HTTP (both lifecycles, `handle_modern` and `handle_post`) **HTTP 400 −32600** "Invalid Request: id must be an integer of at most 128 bits", **no id**; stdio/`JsonRpcHandler` −32600 "Invalid Request" (data names the limit), no id. Stdio `internal_error_response` now echoes only ids `valid_id?` accepts. Ruby clients drop server pings/requests with such ids. | **Wire change on malformed input** (and a DoS fix: writing a multi-million-digit id costs CPU). | **Yes, at the transport, before graph_mem code.** graph_mem has no id handling of its own (`StdioTransport` subclass only overrides `initialize`/`send_response`). Probe: `2**128` and `10**400` HTTP 200 echo → HTTP 400 −32600 without id; `2**128-1` and `-2**128` (bit_length 128) still answered. Behind `AccessGate`, so only allowlisted/authenticated callers can send one. |
| #675, #689 | Test-only; upstream's dev bundle avoids `regexp_parser` 2.13.2. | None. | Consistent with our `Gemfile` pin `regexp_parser < 2.13.2`; keep the pin (the gemspec does not add it). |

**Unchanged between the tags** (checked by diff): `lib/mcp/skill.rb` and `lib/mcp/skill/` (**Skills API: `MCP::Skill.from_directory`,
`.read_file`, `.capability` untouched**), `lib/mcp/apps.rb`, `lib/mcp/resource*`, `lib/mcp/tool*`, `lib/mcp/server/oauth/access_token.rb`,
`mcp.gemspec`. `lib/mcp/server.rb` gains only `validate_resource_read_params!` (the call at `:827`, the method at `:1290-1294`).
No graph_mem doc cites a `server.rb`/transport line number outside `docs/plans/done/`, so no line references need moving.

**Skills over MCP (1.91.0).** Not affected in behaviour: the skills code path and the gem's Skill API are identical.
With `mcp_skills_enabled` **off** (default) `skills:` stays `nil` and the wire is still byte-identical to 1.90.0 for every
well-formed request; the only differences vs 1.10.0 are the two malformed-input cases above, which apply with the toggle
on or off. With it on, `skill://` routing in `ServerFactory.read` runs after the gem's new uri check, so its
`params[:uri].to_s` now always sees a String (harmless; leave it). "Skill file not found" (−32602) is unchanged.

**MCP Apps.** `lib/mcp/apps.rb` unchanged; `ui://` reads unchanged (probe).

## Reference servers v2.5.0 and what they mean for the harness

v2.5.0 fixes eight vulnerabilities: six in `mcp-server-git` (≤ 2026.11.11 → 2026.11.18; repo config/drivers/index/submodule
can make it run commands or read outside the tree), one in `server-filesystem` (→ 2.4.0, symlink swap during listings), and
one in **`server-everything` (≤ 2.3.0 → 2.3.1, GHSA-38j4-j742-j7r3: the `gzip-file-as-resource` tool's private-address guard
treated NAT64 `64:ff9b::/96` as public, an SSRF on a NAT64 network)**. It also publishes Memory 2.2.1 (lock-file cleanup,
opt-in write limits, optional `--transport=streamable-http`; stdio stays the default), sequential-thinking 2.2.0, fetch/time.

- **What the harness runs:** Memory (stdio) and Everything (HTTP) only, via `script/mcp_compat/refservers/package.json`
  (Everything 2.3.0, Memory 2.1.1, overrides `server`/`core` 2.4.0) and the TS client 2.4.0 in `tsclient/`.
  **`mcp-server-git`, filesystem and fetch are not used anywhere** (no Python servers, no `uvx`/`pip` in `script/mcp_compat/`).
- **Do the fixes matter for us?** git/filesystem: no (not installed). Everything: the pinned 2.3.0 **is** an affected version,
  but the harness never calls `gzip-file-as-resource` (the only `tools/call` cases name `get_current_time`), Everything binds
  127.0.0.1 by default (`HOST` is never set), and it runs only during local compat runs. Real exposure is negligible; moving
  anyway keeps a known-vulnerable pin out of the repo and keeps the baseline on the newest release.
- **Recommendation: move the baseline to v2.5.0** (Everything 2.3.1, Memory 2.2.1; overrides and TS client stay 2.4.0).

## Compat results (pre-check, 2026-11-19, Node 24.22.1, Ruby 3.4.12)

**Summary: no documented difference changes.** On all four sets, `compare.rb` run 1 is "0 failed expectations, 0 unexpected
differences" (20 stdio, 33 HTTP cases), and the outlines are **byte-identical** across all four runs (v2.4.0 vs v2.5.0,
`mcp` 1.10.0 vs 1.11.0) apart from the label line. The v2.4.0/1.10.0 run also matches the 1.86.1 record plus the cases added
since (MCP Apps extension, invalid-UTF-8 method). The proxy run gives the recorded verdicts; its 4 failures are the expected
`graph_mem only` ones (capabilities/instructions and MCP Apps, per transport), which `rsdk_server.rb` can't satisfy.
`clients.sh` against `rsdk_server.rb` on 1.11.0 with `RSDK_VERSIONS="1.10.0 1.11.0"`: **12 of 12 OK** (every `auto` row
2026-07-28, every `legacy` row 2025-11-25).

New cases (not in the fixtures yet; probed directly):

| Case | Reference (Memory 2.2.1 stdio / Everything 2.3.1 HTTP) | graph_mem side on 1.11.0 (synthetic probe / rsdk proxy) | Verdict |
|---|---|---|---|
| `resources/read` with no `params` | stdio −32603 (Zod "expected object") with the id; HTTP 200 SSE, −32603 with the id | −32602 "Invalid params", data "Missing or invalid uri", with the id (1.10.0: −32603 "Internal error") | new documented divergence |
| `resources/read` with `uri: 123` | −32603 (Zod "expected string") with the id, both | −32602 "Missing or invalid uri" with the id (1.10.0: −32602 "Resource not found: 123") | covered by the B2 specs only (not a compat case) |
| integer id `2**128` (`ping`) | stdio: `Transport error: ZodError` (ids above 2^53 refused) on stderr, **no reply**; HTTP **400 −32700** "Parse error: Invalid JSON-RPC message", `id: null` | stdio −32600, no id; HTTP **400 −32600** "…at most 128 bits", no id (1.10.0: answered with the id echoed) | new documented divergence |

Pre-existing and unchanged: ids between 2^53 and 2^128 are answered by graph_mem and refused by the TS servers (not a fixture case).

## What the code looks like today (verified at `ef3c900`)

- `lib/graph_mem/version.rb`: `VERSION = "1.91.0"`. `skills/graph-mem-mcp-toolset/SKILL.md:16` `graph-mem-version: "1.91.0"`; `README.md:7` badge `version-1.91.0`.
- `Gemfile:38-39` (D14 comment, `gem "mcp", "1.10.0"`); `Gemfile.lock:228`, `:529`. `Gemfile:6` the `regexp_parser` note; the `prism < 2` pin stays.
- Specs naming the SDK version: `spec/requests/mcp_official_spec.rb:449` (#629), `:469-470` (#672 block, the pattern to copy); `spec/integration/mcp_structured_output_stdio_spec.rb:133`; skills reads in `spec/requests/mcp_skills_http_spec.rb:44`.
- Fixture divergence texts naming the SDK version: `stdio.json:172,210,224,238`; `http.json:229,239,249`. Reference versions: `stdio.json:7,14`; `http.json:10,16,331,344`; `spec/requests/mcp_protocol_compat_spec.rb:10`.
- Harness: `rsdk_server.rb:4,15`; `rsdk_client.rb:4,12,17`; `clients.sh:2,12,22` (default `"1.9.0 1.10.0"`); `compare.rb:4,37,39`;
  `script/mcp_compat/README.md:10,19,20,22,23,33,38,73-74,79-87`
  (`:59` runs `compare.rb` with `MEMORY_FILE_PATH=$(mktemp)`; Memory 2.2.1 keeps a lock file next to that path, so keep it a temp file); `refservers/package.json` (Everything 2.3.0, Memory 2.1.1, overrides 2.4.0).
- Version text: `README.md:73`; `docs/development.md:83`; `docs/architecture.md:61,70` (+ the feature table ending `:79`);
  `docs/protocol_compat.md:5,30-48,66-75,81,108,147,168-176,202-207,224,226`; `docs/plans/done/auto-adoption-plan.md:31,284,292` (historical, leave).

## Steps

### B0. Green `main`, then the generic bundle update (own commit)
Confirm CI is green on `main` first; if not, stop. Run a generic `bundle update` keeping `prism < 2` and
`regexp_parser < 2.13.2`, `json` on 3.x, and **`mcp` still at 1.10.0**. Commit it alone ("bundle update"), push, wait for green.
If it changes nothing, skip the commit and say so in the PR. If CI goes red, stop and ask.

### B1. Gem bump
`gem "mcp", "1.11.0"` (keep the exact pin and the D14 comment), then `bundle lock --update mcp --conservative`.
The lock diff must be exactly the two `mcp` lines (`:228`, `:529`). Anything else: stop and ask.

### B2. Specs for the two wire changes
In `spec/requests/mcp_official_spec.rb`, next to the #672 block, same pattern:
- **`resources/read` without a uri** on `/mcp` and `/mcp/readonly`: body `{"jsonrpc":"2.0","id":9,"method":"resources/read"}` and
  `params: {"uri": 123}` → HTTP 200, `error.code == -32602`, id 9, and **no** `Rails.error` report; note "before 1.11.0: −32603
  without params (#687)". One more case in `spec/requests/mcp_skills_http_spec.rb` with `mcp_skills_enabled` on (same answer).
- **Integer id beyond 128 bits** on `/mcp`: id `2**128` (write the body as a string; `340282366920938463463374607431768211456`)
  → **HTTP 400**, `error.code == -32600`, no `id` key; and `2**128 - 1` still answered with the id.
- One stdio case in `spec/integration/mcp_structured_output_stdio_spec.rb` for each, each followed by a ping that is still answered.
Check once with the lock reverted that these fail on 1.10.0, then restore.

### B3. Compat cases (`spec/fixtures/mcp/handshakes/stdio.json`, `http.json`)
Add exactly two cases to both files, as documented divergences (approved) with the reference answers from the table
above: "resources/read without params" and "an integer id beyond 128 bits" (`2**128`, followed by a ping). `uri: 123` stays
a B2 spec, not a compat case. If `handshake_cases.rb`/`compare.rb` can't express a 39-digit id or the "no reply"
outline without code changes, stop and ask (don't change the harness to fit).

### B4. Harness versions
`rsdk_server.rb`, `rsdk_client.rb` default `1.11.0`; `clients.sh` default `"1.10.0 1.11.0"` (12 rows); README install line
`gem install mcp -v 1.10.0 && gem install mcp -v 1.11.0 && …`. Keep `env: ENV.to_h` in `rsdk_client.rb` and its comment.

### B6. Reference servers v2.5.0 (`script/mcp_compat/refservers/`)
`package.json`: Everything **2.3.1**, Memory **2.2.1**, description "(Memory 2.2.1, Everything 2.3.1 (servers v2.5.0))";
overrides `server`/`core` stay **2.4.0**. `tsclient/` unchanged (no TS SDK release after 2.4.0). Regenerate
`package-lock.json` with `npm install --ignore-scripts --no-audit --no-fund` on Node 24, starting from the committed lock.
Expected lock diff: the two packages, plus **sub-dependency bumps, which are approved**; a fresh resolve on 2026-11-19
moved `hono` 4.13.19, `@hono/node-server` 2.1.9, `express-rate-limit` 8.7.5, `object-inspect` 1.14.0, `router` 2.3.0 (all
already in the tree). A new top-level package, a package that wasn't in the tree before, or an install script: stop and ask. Text: `script/mcp_compat/README.md:10,22,38,74` ("Keep Everything at **2.3.1** or later":
2.3.0 and earlier have GHSA-38j4-j742-j7r3), `compare.rb:4,37,39`, fixture `_comment`s and the two Everything divergence
texts (`http.json:331,344`), `mcp_protocol_compat_spec.rb:10`, `docs/protocol_compat.md:67,81,108,147,224,226`.
Check: `npm ci` installs; `rg -n "2\.3\.0|Memory 2\.1\.1|v2\.4\.0" script/mcp_compat spec/fixtures/mcp spec/requests/mcp_protocol_compat_spec.rb docs/protocol_compat.md`
finds only the deliberate "2.3.0 and earlier" note.

### B5. Version text and re-recorded results (after B6)
`mcp` 1.11.0 in `README.md:73`, `docs/development.md:83`, `docs/architecture.md:61,70`; add two rows to the
`docs/architecture.md` feature table (`resources/read` uri check −32602 before the handler, #687; ids beyond 128 bits −32600, #688).
Re-run `compare.rb` and `clients.sh` against graph_mem on the new baseline and record them in `docs/protocol_compat.md`
(`:5,30-48,66-75` and the new cases) and `script/mcp_compat/README.md:79-87`. Leave the 1.10.0-era divergence texts true
("Ruby SDK 1.10.0 and 1.11.0" where they still hold).

### RB. Release 1.91.1
`lib/graph_mem/version.rb` → `1.91.1`, then `bin/rails graph_mem:sync_skill_version` (SKILL.md and the README badge). Don't
edit `version.rb` or SKILL.md while the full suite is running. CHANGELOG `## [1.91.1] - <date>`:
- Changed: "`resources/read` without a string `uri` is refused as invalid params (-32602) before any resource is looked up; without params it was an internal error (-32603) (mcp 1.11.0)."
- Changed: "A request whose integer id is beyond 128 bits is refused as an invalid request (-32600, HTTP 400 on /mcp) instead of answered (mcp 1.11.0)."
- Changed: "The compat harness's reference baseline is the MCP servers release v2.5.0 (Everything 2.3.1, Memory 2.2.1; TS SDK still 2.4.0)."
- Dependencies: `mcp` 1.10.0 → 1.11.0 (plus the B0 line, or "bundle update changed nothing").

## Version and train
- **1.91.1, a patch release**, as 1.86.1 was: a dependency bump plus wire changes on malformed input only, no surface change.
  If another PR lands first, take the next free patch number.
- **Dependabot** watches bundler daily, not the npm locks. If it opens "Bump mcp from 1.10.0 to 1.11.0", don't base work on it;
  Steve closes it once this merges.

## Decisions (Steve, 2026-11-19)
1. Exact pin `"1.11.0"` (D14).
2. **Patch release 1.91.1** (approved).
3. **Client matrix is TS 2.4.0 + Ruby SDK 1.10.0 and 1.11.0, 12 rows**; 1.9.0 is dropped (approved).
4. **Both new answers are documented divergences** with one compat case each, on stdio and HTTP (approved, B3). The two
   gem-side error-answer changes (#687, #688) are the only wire changes this PR may carry.
5. **Reference baseline is servers v2.5.0** (Everything 2.3.1, Memory 2.2.1), overrides and TS client stay 2.4.0;
   sub-dependency bumps in `refservers/package-lock.json` are approved.
6. **No `event_store:`/`retry_interval:`/`allowed_origins: :any`/`close_sse_stream`.**

## Acceptance criteria
- Gem lock diff `mcp` only (after B0). Suite green on CI (CircleCI rspec, rubocop, brakeman; Actions lint, scan_ruby, scan_js).
- The #629, #672 and non-object `_meta` specs pass unchanged; the B2 specs pass on 1.11.0 and fail on 1.10.0.
- tools/list snapshots byte-identical; tool counts 12 / 9 / 22; `mcp_skills_enabled` off ⇒ `skills: nil`, no `extensions.io.modelcontextprotocol/skills`.
- `compare.rb` on v2.5.0: 0 failed, 0 unexpected, recorded outlines unchanged plus the new cases; `clients.sh` 12 of 12 OK.
- `npm ci` works for `refservers/`; no stale version text. No real hostnames, IPs other than loopback, usernames or home paths.

## Stop and ask Steve if
- the gem lock diff touches anything other than `mcp`, or B0 turns CI red;
- any schema, `structuredContent` key, result text, tool, capability or `x-mcp-header` change; any profile's tool count changes;
- **any MCP param or output change other than the two approved error answers** (#687 missing/invalid `uri`, #688 ids beyond 128 bits);
- a new migration, gem or non-stdlib package is needed (B6's two npm pins and their sub-dependency bumps are the only approved package change);
- any script or command would write under `~/` (the harness writes to temp files and the checkout only);
- a recorded reference outline changes on v2.5.0, or an existing fixture expectation would have to change;
- the diff goes past ~3,000 lines (expected about 400, about 150 of them lockfiles);
- anything would weaken `AccessGate`, the lockdown, the Origin/Host checks, or the anonymizer/cloud gate;
- `handshake_cases.rb`/`compare.rb` can't express a new case (in particular a 39-digit id, or the "no reply" outline) without code changes;
- a newer `mcp`, servers or TS SDK release has appeared by PR time (re-plan, don't skip or silently take it).

## Size
About 2.5 hours: B0 15 min, B1 10 min, B2 40 min, B3 30 min, B4 10 min, B6 30 min, B5 30 min, RB 10 min.
