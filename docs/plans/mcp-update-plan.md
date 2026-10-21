# MCP update and hardening plan: steveoro/fast-mcp → steveoro/graph_mem (FINAL)

**Final version, 2026-10-21 (Europe/Rome)**, by Graphy for Steve, for **Claude** to implement locally, with simple step lists for Devin.
History: first draft 2026-10-12 (`mcp-update-plan.2026-10-12.md`); revised 2026-10-20 for MCP servers v2.0.0 / Ruby SDK v1.8.0 (`mcp-update-plan.2026-10-20.md`); 2026-10-20 evening added container scan mounts (`mcp-update-plan.2026-10-21-pre.md` is that version, with its 12 open questions). `mcp-update-plan.2026-10-21-b.md` is the Oct 21 morning version. **This version** applies all of Steve's Oct 21 answers (incl. 1:32 PM: PR-4 confirmed, the PR-3 client check run by Steve), resolves the older questions and re-orders the releases.
Investigation was read-only throughout: no repo modified, nothing pushed, no PR or comment opened. All probes used synthetic fixtures only.

Companion plan: `ui-dashboard-plan.md`. Both plans share **one release train** (§C). Its **UI-0** (security baseline) is part of graph_mem 1.53.0.

---

## A. Implementer brief (read first)

| | |
|---|---|
| **Repos** | `steveoro/fast-mcp` (`main` @ `b2a8eb8`, `VERSION = '1.7.1'`; Ruby 3.4.1, RVM gemset `ruby-3.4.1@fast_mcp`; read `CLAUDE.md` + `AGENTS.md`). `steveoro/graph_mem` (`main` @ `57d9524`, v1.52.1; Rails 8.1, MariaDB 11.8+, RVM `ruby-3.4.1@graph_mem`; read `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`). Both heads were re-checked against `origin` on 2026-10-21 and haven't moved. Line references below are from these commits. |
| **Who does what** | **[Claude]** items need design judgement (protocol negotiation, transports, ScanRootPolicy, the race fixes). Claude implements them locally. **[Devin-simple]** items (§D) are step lists with exact files and specs. Devin stops and asks instead of deciding. |
| **Branches** | One branch per item, off current `main`: `claude/pr-<n>-<slug>`, `devin/m-d<n>-<slug>`. No force-push once review has started. Agents never merge, tag, push tags or run `rake release`. **Steve merges and tags** (fast-mcp `v1.8.0`; graph_mem releases). Graphy (graphy-review[bot]) reviews every PR. Fix should-fix findings before merge. |
| **Versions** | fast-mcp: `lib/mcp/version.rb` + `CHANGELOG.md`. graph_mem: `lib/graph_mem/version.rb` + `CHANGELOG.md` (Keep a Changelog). graph_mem 1.53.0 is **three stacked PRs** (UI-0 → PR-0 → PR-2): the first two write `## [Unreleased]`, and PR-2 bumps and renames it to `## [1.53.0]`. Devin-simple PRs never bump; they add an `[Unreleased]` line. |
| **Running specs safely** | Prefix every command with `source "$HOME/.rvm/scripts/rvm" && rvm use <gemset> && bundle exec …`. graph_mem: `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`; nothing may listen on 11434; **truncate the test DB before and after** (snippet in `ui-dashboard-plan.md` §0.1); leave it with 0 rows. Run the **full suite on its own**. Never kill processes you didn't start (other agents share the box). Leave no scratch specs (`zz_*`) or temp trees. Stdio/runner specs spawn subprocesses with the same env and must reap them. |
| **Fixtures** | Synthetic only: `Dir.mktmpdir` trees, `SynthWidget`, empty Memory JSONL, the harness in `/workspace/triage/mcp-compat/`. **Never use `admin_hub` or `coach_in_a_box` (private BTS code, BTS IT policy), not even read-only, for tests, benchmarks or perf probes, and don't mention them in PRs.** For real-app probes, use open-source apps (Steve's goggles repos, Mastodon, Discourse). |
| **Schema** | graph_mem `db/structure.sql` is the source of truth. After any migration, check that no `vector(768)` / VECTOR KEY / trigger line disappeared (`StructureDumpGuard`). 1.53.0 needs **no migration** except the one `AppSettings` field, which is a settings row, not DDL. |
| **Done criteria (every PR)** | The listed specs are green. The full suite is green run alone, plus rubocop (and brakeman on graph_mem). The test DB has 0 rows. CHANGELOG and docs are updated. The PR description carries the advisory checklist (end of this file) and the manual checks with results. For fast-mcp: graph_mem's MCP specs pass against the branch via a local, uncommitted `bundle config local.fast-mcp` override. |

## B. Decisions (Oct 21, 2026)

**Steve's answers** (Oct 21):
- **S-5 Scan mount:** default = the host user's **home folder, read-only, at the same path in the container** (`${HOME}:${HOME}:ro`), so host paths paste straight in. No path map unless a non-identity host needs one; none does in 1.53.0. A **subfolder filter** setting (default `Projects`, comma list of paths relative to home) is editable at runtime with no restart, and every entry point **and** job start re-reads it. A **hard, non-overridable denylist** (dotfolders and secrets) applies on top. Existing protections stay: `..` rejection, symlink-escape check, distinct errors, writable-mount warning, the "check a path" box, and scans clearly disabled when nothing is mounted. → **PR-0**.
- **S-6 Hosts:** Linux Docker is the only tested target. My recommendation, which is also Steve's lean: document **rootless Podman as best-effort, not CI-tested**, with one compose note and one Quadlet snippet, plus the SELinux caveat (never `:z`/`:Z` on a home directory; use `:ro` + `label=disable`, or per-subfolder mounts). Docker Desktop/macOS/Windows: out of scope, marked "untested". → PR-0 §0.7.
- **S-7 Versions:** no v1.52.2. **fast-mcp 1.8.0 first**, then **graph_mem 1.53.0** = mounts/ScanRootPolicy + MCP hardening + the two high bugs (array body as a Rack response; `fast_mcp.rb:24` stdout logging). graph_mem is fast-mcp's reference implementation (PR-1 §1.12). UI-0 goes **into** 1.53.0 (reason in §C).
- From the UI answers that matter here: `/api/v1` gets auth with **no compatibility flag** (nothing uses it), and there's one operator plus a read-only guest that exists only when a guest password is set in ENV/credentials (UI plan §2.1).

**Older open questions, resolved** (old number → decision):
- **D-2 (old Q2) handshake ceiling:** advertise up to **2025-11-25**. "Keep fast-mcp up to date" argues for the newest handshake version, and both repos meet its server-side MUSTs once PR-1 §1.6 and PR-2 §2.2/§2.3a land. The §1.1 checklist still gates it.
- **D-3 (old Q3) legacy SSE:** **keep and harden** `/mcp/sse`; don't disable it. graph_mem's README still documents it for Docker clients (`README.md:291-296`, `:476`), and it's fast-mcp's only built-in HTTP transport. Mark it deprecated in graph_mem docs (HTTP+SSE is Deprecated in 2026-07-28, SEP-2596). Removal is a later major-ish change.
- **D-4 (old Q4) observation uniqueness:** the check under the write lock (PR-2 §2.7) is enough for 1.53.0. A `content_sha256` unique column is deferred (it needs a migration + backfill and isn't needed for correctness once the check is under the lock).
- **D-5 (old Q5) `on_duplicate: "skip"`:** **opt-in**. The default stays `reject`, so existing `graph_write` callers see no change (PR-2 §2.14). Revisit the default with the UI series.
- **D-6 (old Q6) limits:** 4 MiB body (same as the TS SDK / Everything), 256 sessions, 2,048-char queries, each ENV-overridable (`GRAPH_MEM_MCP_MAX_REQUEST_BYTES`, `GRAPH_MEM_MCP_MAX_SESSIONS`). Bulk imports don't go through MCP (`data_exchange#import_upload`, `rake graphify:import`), so the cap doesn't touch them.
- **D-7 (old Q7) description limit:** **2,048** (safe for older Claude Code; today's descriptions fit).
- **D-8 (old Q8) fast-mcp version/tagging:** **1.8.0** (minor: new options plus stricter SSE/JSON-RPC). **Steve tags** after merge, following fast-mcp's release policy.
- **D-9 (old Q9) OAuth:** don't implement it. Only reserve the `token_verifier:` / `required_scopes:` hook on `AuthenticatedRackTransport` and document it as "not implemented" (PR-1 §1.7).
- **D-10 (old Q10) non-TS clients:** §2.13 (clean stdout) **stays high**. As fast-mcp's reference implementation, graph_mem must work with the official Ruby SDK client, which can't connect today.
- **D-11 / D-12 (old Q11/Q12):** answered by S-5 and S-6.
- **D-1 (old Q1 / R1) 2026-07-28 dual-era: confirmed (Steve, Oct 21 1:32 PM).** PR-4 runs right after PR-3: **fast-mcp 1.9.0** first (PR-4a), then graph_mem **1.54.0** adopts it as the reference implementation (PR-4b). The UI series moves to 1.55.0–1.62.0.
- **PR-3 step 5** (the manual Claude Code client check) is run by Steve himself with `prompts/claude-mcp-client-check.md`; no longer an open item.
- Nothing is open (§E).

## C. Release train (identical in `ui-dashboard-plan.md` §0.3)

| # | Item | Repo / version | Who | Depends on |
|---|---|---|---|---|
| 1 | **PR-1** fast-mcp hardening + negotiation | fast-mcp **1.8.0** (Steve tags `v1.8.0`) | [Claude] | n/a |
| 2 | **UI-0** security baseline: `/api/v1` auth, login hardening, JS escaping, cable/api-docs auth, CSP report-only (UI plan §6) | graph_mem `[Unreleased]` → 1.53.0 | [Claude] | n/a |
| 3 | **PR-0** home mount, ScanRootPolicy, subfolder filter, denylist | graph_mem `[Unreleased]` → 1.53.0 | [Claude] | **UI-0 merged** |
| 4 | **PR-2** MCP hardening + fast-mcp 1.8.0 bump + the two high bugs; **bumps to 1.53.0** | graph_mem **1.53.0** | [Claude] | PR-1 tagged, PR-0 merged |
| 5 | **PR-3** interop specs/scripts (+ docs) | graph_mem **1.53.1** | [Claude] + [Devin-simple] | 1.53.0 |
| D | **M-D1** query cap, **M-D2** description-length spec (before PR-2), **M-D3** docs line-refs (after PR-2) | `[Unreleased]` | [Devin-simple] | as listed |
| 6 | **PR-4a** dual-era 2026-07-28, fast-mcp side | fast-mcp **1.9.0** (Steve tags `v1.9.0`) | [Claude] | PR-3 merged |
| 7 | **PR-4b** dual-era, graph_mem side + fast-mcp 1.9.0 bump | graph_mem **1.54.0** | [Claude] | fast-mcp 1.9.0 tagged |
| 8+ | UI series UI-1 … UI-7 | graph_mem 1.55.0 … 1.62.0 | [Claude] | 1.54.0 |

**Why UI-0 is inside 1.53.0:** PR-0 mounts the operator's whole home folder. With today's unauthenticated `/api/v1`, any LAN host could `POST /api/v1/scan` a folder and read the results back through `GET /api/v1/memory_entities`. Scanned text would also reach the graph UI's `innerHTML` sinks (UI plan F1/F2). So API auth and escaping are **preconditions of the mount**: PR-0 must not merge before UI-0. The scan-path checks themselves are PR-0 (one `ScanRootPolicy` for UI, API, MCP and job start). CSP is report-only in 1.53.0 and enforced in UI-1 (1.55.0).

**Why PR-4 precedes the UI series:** "keep fast-mcp up to date first, graph_mem as its reference implementation" (S-7). The UI doesn't depend on PR-4 technically; if Steve wants the UI first, only the numbering swaps. Claude doesn't swap on its own.

---

## Bugs and findings carried into this series (status 2026-10-21)
| Bug | Where | Severity | Fixed by |
|---|---|---|---|
| A JSON-array POST body is returned as the raw Rack response (caller-chosen status/headers/body) | `lib/graph_mem/mcp_streamable_http_transport.rb:225-226` | High | PR-2 §2.3a (1.53.0) |
| stdio runner writes 48 log lines to stdout; the Ruby SDK 1.8.0 client can't connect | `config/initializers/fast_mcp.rb:24-25` | High | PR-2 §2.13 (1.53.0) |
| `/api/v1` unauthenticated (incl. `POST /api/v1/scan`) | `app/controllers/api/v1/base_controller.rb:6` | High | UI-0 (1.53.0) |
| Scan paths enforced only in the two dashboard controllers; `file_globs` `..` and symlinked files escape the root | PR-0 §0.0 | High (once home is mounted) | PR-0 (1.53.0) |
| fast-mcp JSON-RPC deviations (replies to notifications, wrong codes, leaks exception text) | `lib/mcp/server.rb:245-299` | Medium | PR-1 §1.6 (fast-mcp 1.8.0) |
| `discover_files` truncates before sorting (`first(@max_files).sort`), so the surviving set depends on filesystem order | `app/services/project_scanner.rb:276` | Low | PR-0 §0.5.5 |
| `docker-compose.yml` doesn't pass `OPERATOR_USERNAME`/`OPERATOR_PASSWORD`, so compose installs run on the `operator`/`changeme` fallback unless credentials are set (new) | `docker-compose.yml` `app.environment` | Medium | UI-0 (1.53.0) |
| New on Oct 21, UI side (details in the UI plan §0): F6 cleanup job never scheduled; F7 dangling review rows; F8 merges call the embedding service inside the transaction/lock | see UI plan | Low / Medium / Medium | UI plan §6.D-2, UI-5, §6.D-3 |

---

## 0. What I checked against the code (corrections and resolved unknowns)

| Recap claim | Result | Evidence (graph_mem @ `57d9524`, fast-mcp @ `b2a8eb8`) |
|---|---|---|
| graph_mem HTTP caps at 2025-03-26 | **Confirmed (still)** | `lib/graph_mem/mcp_streamable_http_transport.rb:353-354` in `resolve_session`: `version = requested_version.to_s >= "2025-03-26" ? "2025-03-26" : "2024-11-05"`. Then `normalize_initialize_protocol_version!` (:572) rewrites the result's `protocolVersion`. It's a string compare, so garbage such as `"9"` counts as ≥ (probe: `"9"` → `2025-03-26`). |
| fast-mcp always answers 2024-11-05 | **Confirmed (still)** | `lib/mcp/server.rb:354` `PROTOCOL_VERSION = '2024-11-05'`, used by `handle_initialize` (:356, :367). Probe: 2025-03-26, 2025-11-25, 2026-07-28 and `"9"` all → `2024-11-05`. |
| **graph_mem ignores `MCP-Protocol-Version`** (new) | **Confirmed** | No reader for `HTTP_MCP_PROTOCOL_VERSION` in the transport. Probe: in-session requests with header `1999-01-01` or `2026-07-28` → 200; v2.0.0 Everything → 400 `-32000`. |
| **graph_mem HTTP reflects array bodies** (new) | **Confirmed, high** | `handle_streamable_post` :225-226: `parsed = parse_json(body); return parsed if parsed.is_a?(Array) # error response`. `parse_json` (:589-593) returns a Rack triplet on a parse error, so a *successfully parsed* JSON array is mistaken for one and returned as the response. Probe: POST `[299,{"x-synth-injected":"1"},["synthetic-body"]]` → `HTTP/1.1 299`, header `x-synth-injected: 1`, body `synthetic-body`. `[]`, `[1,2,3]`, `5`, `"x"` and `null` → 500 (`NoMethodError`). The Origin / IP / token checks still run first, so this is self-reflected header injection plus a 500, not cross-site. |
| **graph_mem stdio stdout is not clean** (new) | **Confirmed, high for non-TS clients** | `config/initializers/fast_mcp.rb:24` `fast_mcp_logger = Logger.new(STDOUT)` at DEBUG (:25) runs when `bin/mcp_stdio_runner.rb` loads `config/environment`. A synthetic run wrote **48 non-JSON lines** ("Registered tool: …", "[McpAccessPolicy] …") to stdout before the first frame. `config/environments/production.rb:38` also sends `Rails.logger` to STDOUT. **Ruby SDK 1.8.0 client: connect fails in both `auto` and `legacy` modes** ("Failed to parse server response"; that client has raised on non-JSON lines since v0.10.0, so this isn't the new #590 check). The TS client 2.3.1 skips non-JSON lines (`ReadBuffer.readMessage` drops `SyntaxError`), so Claude Code isn't affected. |
| **fast-mcp JSON-RPC conformance** (new) | **Deviations confirmed** | `server.rb#handle_request` (:245-299). Parse error → `-32600` (should be `-32700`). Batch or primitive body → `-32600 "Internal error: no implicit conversion of String into Integer"` (leaks the exception text; internal errors should be `-32603`). Unknown **notification** (e.g. `notifications/cancelled`) → gets an error *reply* with `id: null`, but JSON-RPC forbids replying to a notification. Outbound messages always carry `jsonrpc: "2.0"` (server.rb :308, :690, :703, :714, :726; rack_transport :302, :317, :552, :654; stdio_transport :51; authenticated_rack_transport :50), so Ruby SDK 1.8.0's strict check (#590) passes. |
| Claude Code fallback against graph_mem | **Verified with the TS SDK client 2.3.1, not with Claude Code itself** | `auto` mode: graph_mem HTTP → era legacy, `2025-03-26`, 116 ms. graph_mem stdio → legacy `2024-11-05`, **2.8 s vs 1.36 s** in `legacy` mode (the stdio probe runs on a throwaway sibling process, `@modelcontextprotocol/client@2.3.1 dist/index.mjs:2886-2931`, so Rails boots twice). The HTTP probe gets `400 -32600 "missing Mcp-Session-Id"` and creates no session. |
| DB adapter | Resolved (unchanged): `mysql2` / MariaDB | `config/database.yml` (untracked, from `database.example.yml`). Use `GET_LOCK` / `SELECT … FOR UPDATE`. GET_LOCK helper: `ProjectMembership.with_membership_lock` (app/services/project_membership.rb), taken *before* the transaction. |
| Context tool annotations | Resolved (unchanged): correct | `set_context_tool.rb`, `clear_context_tool.rb`, `get_context_tool.rb`: `read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false`. Context is keyed by the `X-MCP-Client` header (`application_tool.rb:7`, :110-115), not by MCP session, so it survives the session-less 2026-07-28 model. |
| Legacy SSE behaviour on bad sessions | Resolved (unchanged): worse than assumed | fast-mcp `rack_transport.rb`: `handle_message_request_with_server` / `process_json_request_with_server` (:591-627) never validate a session/client id; `extract_client_id` (:384-407) plus `handle_client_reconnection` (:430-442) let any caller take over a stream; `send_message` (:81-108) broadcasts to all SSE clients. |
| No body limit | Confirmed in both | graph_mem `handle_streamable_post` :222 `body = request.body.read`; fast-mcp `process_json_request_with_server` :606. Reference: Everything caps session-less bodies at 4 MiB → 413 `-32600` (`src/everything/transports/streamableHttp.ts:86`, :102-127). |
| No search query cap | Confirmed | `app/tools/search_tool.rb:34` `optional(:query).maybe(:string)`, blank check at **:72** (was :67). Other free-text query args: `search_entities_tool.rb:26`, `search_subgraph_tool.rb:36` (`required(:query).filled`), `get_entities_tool.rb:31`, `get_entity_tool.rb:32`, `rank_observations_tool.rb:28` (`optional(:query).filled`). |
| Subscriptions per server, never cleaned | Confirmed | `server.rb` `@resource_subscriptions = {}` (:50); subscribe stores the request id (:659-660); unsubscribe deletes by request id (:677-679); `notify_resource_updated` (:302) broadcasts. |
| Out-of-request notifications broadcast | Confirmed, lower impact | `McpStreamableHttpTransport#send_message` (:133) → `broadcast_to_streamable_sessions` (:567). No graph_mem app code calls `notify_resource_updated`. |
| Duplicate-check race | Confirmed, narrowed | `GraphWriteService#call` (:67): `duplicate = duplicate_response` (**:73**, method at **:303**) runs before `ProjectMembership.with_membership_lock` (:80) + transaction (:81). The **single-operation path repeats the pattern at :137 / :141-142**. Unique keys: `index_memory_entities_on_scope_name` (structure.sql **:173**), `index_memory_relations_uniqueness` (**:265**). `graph_mutation_batch.rb:73` rescues `RecordNotUnique`. |
| CORS `*` | Confirmed in both | graph_mem `SSE_HEADERS` (:40-50, `Access-Control-Allow-Origin` at :45; `Allow-Headers` lacks `MCP-Protocol-Version`); fast-mcp `DEFAULT_HEADERS` (:27-30), `setup_cors_headers` (:364-370). |
| README / docs drift | Still present | README.md:36-38, :67, :335; docs/development.md:75, :87, :208, :304; docs/troubleshooting.md:23-24. (`57d9524` added a Claude Code connection section to README but no protocol statements.) |
| Unknown tool → -32602 before argument validation | Confirmed done | `server.rb#handle_tools_call` :497/:500/:505. Argument errors come back as `isError` tool results (:523-525, `send_error_result` :598), which matches 2025-11-25 SEP-1303. |
| Origin rejection | 403 in both | fast-mcp `rack_transport.rb:259` `forbidden_response`; graph_mem `validate_origin` (:696) → 403 (:736). That's what 2025-11-25 requires. |
| Shutdown/reaper | Done in graph_mem only | `SESSION_TIMEOUT = 30*60` (:36), reaper, `stop`. Legacy SSE in fast-mcp is not reaped. |
| Delete counts | Strict | `GraphDeleteService#call` (:64), counts from the per-operation summary (:94-96). |
| 401 challenge | Present | graph_mem :741-745 sends `WWW-Authenticate: Bearer realm="graph_mem"`. |

**Not run by me:** Claude Code itself (≥2.1.292 stdio, HTTP) against graph_mem; only the SDK clients were run. Steve runs that check himself as PR-3 §3.1 step 5 (`prompts/claude-mcp-client-check.md`).
---

## 0b. Reference: how v2.0.0 negotiates versions (exact paths)

Everything below was read at tag `v2.0.0` (`51b6382a`) and in the SDK packages it locks (`@modelcontextprotocol/{server,core,client}@2.3.1`, unpacked from npm into `/workspace/src/mcp-ts-sdk-pkgs/`; the SDK files are bundled `dist/*.mjs`, so the line numbers are for those files). Probe results are in §3.0.

**Version lists**
- Handshake ("legacy era"): `core@2.3.1 dist/auth-BNDyLTqp.mjs:4-12`: `LATEST_PROTOCOL_VERSION = "2025-11-25"`, `DEFAULT_NEGOTIATED_PROTOCOL_VERSION = "2025-03-26"`, `SUPPORTED_PROTOCOL_VERSIONS = [2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07]` (newest first).
- Modern era: `server@2.3.1 dist/src-Cqbh3MYc.mjs:567-586`: `FIRST_MODERN_PROTOCOL_VERSION = "2026-07-28"`, `SUPPORTED_MODERN_PROTOCOL_VERSIONS = ["2026-07-28"]`, `isModernProtocolVersion(v) = v >= "2026-07-28"`, `legacyProtocolVersions()` / `modernProtocolVersions()` split one list by era.
- Ruby SDK 1.8.0 matches: `lib/mcp/configuration.rb:5-27` (`SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS = stable − modern`; the comment reads "The handshake therefore never negotiates a modern version: a client asking `initialize` for one is counter-offered `LATEST_HANDSHAKE_PROTOCOL_VERSION`, matching the TypeScript and Python SDKs").

**`initialize` (legacy era):** `server@2.3.1 dist/mcp-DIH4cS6P.mjs:1338-1352` `Server._oninitialize`:
`protocolVersion = legacyVersions.includes(requested) ? requested : legacyVersions[0]`. So a supported request is echoed, and anything else (2026-07-28, a future date, garbage) gets the **newest handshake version, 2025-11-25**. `initialize` never returns 2026-07-28. Probe (Memory stdio and Everything HTTP): 2026-07-28 → 2025-11-25, `"9"` → 2025-11-25, 2025-06-18 → 2025-06-18, 2024-11-05 → 2024-11-05.

**`server/discover` (modern era):** `dist/mcp-DIH4cS6P.mjs:1009`, :1053 (registered only when a modern version is supported) and `_ondiscover` :1354-1363 → `{supportedVersions: <modern only>, capabilities, instructions?}`, plus `resultType`, `ttlMs`, `cacheScope` and `_meta["io.modelcontextprotocol/serverInfo"]` from the 2026 encoder.

**The per-request envelope:** `params._meta` must carry `io.modelcontextprotocol/protocolVersion` and `io.modelcontextprotocol/clientCapabilities` (`REQUIRED_ENVELOPE_KEYS`, `dist/src-Cqbh3MYc.mjs:4013`; `hasEnvelopeClaim` :4267, `validateEnvelopeMeta` :4289, `carriesValidModernEnvelopeClaim` :5168). `io.modelcontextprotocol/clientInfo` is a SHOULD.

**stdio era selection** (what the Memory server uses): `src/memory/index.ts:1183-1194` `main()` → `serveStdio(({ era }) => createServer(memoryFilePath, era), …)`. `createServer(path, era)` (:746-749) changes one behaviour by era: `notifyGraphUpdated` (:768) always sends on modern (the listen router filters) and only to `resources/subscribe`-ers on legacy. `registerKnowledgeGraphSubscriptions` (:1162-1176) installs `resources/subscribe`/`unsubscribe`, which exist only on the 2025 era. README `src/memory/README.md:139, :143` ("Protocol versions"). Tests: `src/memory/__tests__/eras.test.ts:75-195`.
`serveStdio` (`server@2.3.1 dist/stdio.mjs`): `classifyOpeningMessage` (:235-266) classifies the **first message** of the connection:
1. `initialize` without a valid modern envelope → legacy (pins a legacy instance; `requestedVersion` is fed to `_oninitialize`).
2. No envelope claim → legacy ("no-claim").
3. Claim with a malformed envelope → `-32602 "Invalid _meta envelope for protocol revision 2026-07-28: <key>: <problem>"` with `data.envelope`, connection stays un-pinned.
4. Claim naming an unsupported revision → `-32022 UnsupportedProtocolVersion`, `data: {supported: ["2026-07-28"], requested}`.
5. Valid modern claim → modern. A `server/discover` puts the connection in a **probe** phase (:462-476). If the next message is a legacy `initialize`, the probe instance is discarded and a legacy instance is pinned (:505-520). That's the in-process fallback the probe tests show (`discover` → `initialize 2025-11-25` → `tools/list` all succeed).
Once pinned modern, a later claim-less `initialize` is refused (:430-433), and `resources/subscribe` from a modern peer → `-32601` (eras.test.ts:145-170). Malformed / non-JSON-RPC lines get no reply at all on stdio (probe: parse error, batch, missing `jsonrpc`, primitive → silence; the SDK reports them through `onerror`).

**Streamable HTTP era selection** (Everything; Memory is stdio-only): `src/everything/transports/streamableHttp.ts:1-27` (design comment), :160-176 (`createMcpHandler(factory, { legacy: "reject" })` for the stateless modern side), :187-210 (route: a POST **without** `Mcp-Session-Id` that `isLegacyRequest()` says is modern → modern handler; everything else → the sessionful 2025 transport), :275 GET / :307 DELETE (2025-only), :77-83 `sessionNotFound` (404 `-32001`, echoes the request id read from the body by `readRequestId`, :56-70), :86 4 MiB cap → 413, :148-152 CORS `exposedHeaders` incl. `mcp-protocol-version`.
`isLegacyRequest` / `classifyInboundRequest` (`server@2.3.1 dist/index.mjs:1205-1279`, `dist/src-Cqbh3MYc.mjs:5186-5296`):
- non-POST → legacy. Posted responses or batch arrays → legacy (a batch containing an envelope → 400).
- `initialize` without a valid modern claim → legacy, **but** if the `MCP-Protocol-Version` header names a modern revision → **400 `-32020` HeaderMismatch** (:5191-5192).
- Envelope present → validate (`-32602` on a malformed one), header ≠ envelope version → 400 `-32020`, `Mcp-Method` header ≠ body method → 400 `-32020`; otherwise modern.
- No envelope but a modern header → 400 `-32602` ("missing the required per-request envelope key(s)").
- Otherwise legacy.

**`MCP-Protocol-Version` on the 2025 sessionful path:** `server@2.3.1 dist/index.mjs:895-911` `validateProtocolVersion`: header absent → accept (the transport assumes the negotiated version, or `DEFAULT_NEGOTIATED_PROTOCOL_VERSION` 2025-03-26 at :780). Present and in the handshake list → accept (it need not equal the negotiated one). Otherwise → **400 `-32000` "Bad Request: Unsupported protocol version: X (supported versions: …)"**. It's checked on GET (:538), non-initialize POST (:759, *after* the session check, so an unknown session gets 404 first) and DELETE (:862). A modern value on a legacy session → 400 too (probe `session_header_modern`).

**Client side (decides whether a legacy server works):** `client@2.3.1 dist/index.mjs:2396-2510` (`UNSUPPORTED_PROTOCOL_VERSION`, `NOT_PROBE_RECOGNIZED`, `classifyProbeOutcome` :2413). A `server/discover` probe answered with **any JSON-RPC error** (including `-32601`, `-32600`, `-32001`, `-32020`, `-32021`) → legacy fallback. `-32022` → corrective retry if `data.supported` lists a mutual modern version, otherwise legacy. A result that fails the discover schema → legacy. HTTP 4xx (except 401/403) → parse the body → same rules. **HTTP 401/403 or ≥500 → hard error, no fallback.** On stdio a closed pipe or timeout → legacy. In stdio `auto` mode the probe runs on a **disposable sibling process** spawned from the same command (`negotiateStdioViaSibling`, :2886-2931), then the real process is started. `DEFAULT_VERSION_NEGOTIATION_MODE = "legacy"` in the SDK (:2559); Claude Code chose `auto` (its changelog 2.1.292).

**What 2026-07-28 requires beyond the version string (only what matters for a tools/resources server; from the spec changelog https://modelcontextprotocol.io/specification/2026-07-28/changelog, fetched 2026-10-20):**
1. `server/discover` MUST be implemented (supportedVersions, capabilities, instructions; serverInfo SHOULD go in result `_meta`).
2. There's no `initialize`/`initialized` and no sessions: every request carries `_meta` protocolVersion + clientCapabilities and is validated on its own. A mismatch gets `-32022` with `{supported, requested}`, and a malformed envelope gets `-32602`.
3. HTTP: no `Mcp-Session-Id`, no GET stream, no DELETE, no SSE resumability (`Last-Event-ID`). POSTs carry `Mcp-Method` (+ `Mcp-Name` for name/uri methods). Header/body disagreement → 400 `-32020`. `MCP-Protocol-Version` must match the envelope.
4. Every result carries `resultType: "complete"`. `tools/list`, `resources/list`, `resources/templates/list`, `resources/read` and `prompts/list` must carry `ttlMs` + `cacheScope` (v2.0.0 Memory sends `ttlMs: 0, cacheScope: "private"`).
5. `resources/subscribe`/`unsubscribe` and the GET stream are replaced by `subscriptions/listen` (a long-lived POST response stream). Notifications are tagged `io.modelcontextprotocol/subscriptionId`, and a modern peer calling `resources/subscribe` gets `-32601`.
6. `ping`, `logging/setLevel` and `notifications/roots/list_changed` are removed. `notifications/message` only goes out when the request carried `io.modelcontextprotocol/logLevel` (graph_mem/fast-mcp emit none: grep finds no logging/progress/sampling/elicitation code in either).
7. A resource that isn't found → `-32602` (fast-mcp already uses `-32602`, server.rb:392). List results must not vary per connection; graph_mem varies them per **path** (`McpProfile.from_request` → `from_path`, `lib/graph_mem/mcp_profile.rb:23-34`), which is allowed. `tools/list` order SHOULD be deterministic.
8. Not needed by graph_mem: MRTR / `input_required` (no server→client requests), the tasks extension, sampling/roots/elicitation.

**What 2025-11-25 and 2025-06-18 require of this server (for advertising them in `initialize`):** 2025-06-18 needs no batching (reject arrays), `MCP-Protocol-Version` honoured on HTTP, optional `structuredContent`/`outputSchema` (fast-mcp already emits output schemas) and an optional `title`. 2025-11-25 needs 403 for a bad Origin (both repos do this), input-validation errors as tool errors (fast-mcp does this), JSON Schema 2020-12 as the default dialect (fast-mcp strips `$schema`, `tool.rb:175`, so clients assume 2020-12); everything else (icons, URL elicitation, tasks, sampling tools) is optional. **Both are honest to advertise once PR-1 §1.6 and PR-2 §2.2/§2.3a land.**

---
## PR-1 [Claude] — fast-mcp v1.8.0: negotiation, strict JSON-RPC, body cap, per-session subscriptions, legacy SSE session semantics, CORS allowlist (ships FIRST)

- **Repo / base:** steveoro/fast-mcp, `main` @ `b2a8eb8` (was `b10243c`; the in-between commits are tooling only)
- **Branch:** `claude/pr-1-hardening-1.8.0`
- **Title:** `Hardening 1.8.0: handshake negotiation to 2025-11-25, strict JSON-RPC, body limit, per-session subscriptions, SSE session checks, CORS allowlist`
- **Version:** `lib/mcp/version.rb` → `'1.8.0'` (minor: new options and behaviour changes for bad SSE ids and malformed JSON-RPC). Tag `v1.8.0` after merge: **Steve creates the tag** after the Ruby matrix is green (fast-mcp `AGENTS.md` release policy: GitHub-only, no `rake release`, `PUBLISH_TO_RUBYGEMS` unset). No agent pushes tags.
- **Before asking for review** (fast-mcp `CLAUDE.md`): run graph_mem's MCP specs and full suite against this branch locally, with a **local, uncommitted** `bundle config local.fast-mcp /path/to/fast-mcp` override, and paste the summary into the PR. graph_mem's actual bump happens in PR-2.

### 1.1 Handshake version negotiation (G1/G2), modelled on v2.0.0
`lib/mcp/server.rb` (replace :354 and the hard-coded value at :367):
```ruby
# Versions reachable through the initialize handshake, NEWEST FIRST (same order as the
# TS/Ruby SDKs). 2026-07-28 is never negotiated by initialize: it has no handshake, a
# client reaches it only via server/discover + a per-request _meta envelope (PR-4).
HANDSHAKE_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
LATEST_HANDSHAKE_PROTOCOL_VERSION = HANDSHAKE_PROTOCOL_VERSIONS.first
PROTOCOL_VERSION = '2024-11-05' # deprecated alias: oldest supported, kept for callers

attr_reader :protocol_versions, :negotiated_protocol_version

# Server.new(..., protocol_versions: [...]) lets an embedder cap the list (e.g. graph_mem
# could pass %w[2025-03-26 2024-11-05] if it ever needs to). Validate: non-empty, all
# YYYY-MM-DD, none >= '2026-07-28' (raise ArgumentError), stored newest first.

def negotiate_protocol_version(requested)
  return requested if requested.is_a?(String) && protocol_versions.include?(requested)
  protocol_versions.first # supported → echo; anything else (2026-07-28, future, garbage, nil) → newest
end
```
- In `handle_initialize(params, id)`: `@negotiated_protocol_version = negotiate_protocol_version(params['protocolVersion'])` and answer `protocolVersion: @negotiated_protocol_version`. Delete the "only version 2024-11-05" comment.
- Expose `Server#supported_protocol_version?(v)`, which transports use for `MCP-Protocol-Version` header checks (PR-2 §2.2, and fast-mcp's own Rack transport when it gains a Streamable endpoint).
- This is the exact behaviour of `Server._oninitialize` in `@modelcontextprotocol/server@2.3.1` (§0b) and of Ruby SDK 1.8.0 `LATEST_HANDSHAKE_PROTOCOL_VERSION`. **Changed from the Oct 12 draft:** the list goes up to 2025-11-25 (it stopped at 2025-06-18), and an unsupported request gets the *newest* version. 2026-07-28 is still **not** listed, and §0b explains why that's the correct way to support "up to 2026-07-28" until PR-4.
- Checklist before advertising 2025-06-18/2025-11-25 (§0b): no batching (§1.6 rejects arrays), the HTTP header check (Rack legacy SSE has no `MCP-Protocol-Version` on its 2024-11-05 path, so nothing to do there; the Streamable side is graph_mem's), output schemas (already emitted), Origin → 403 (rack_transport :259, done), and argument errors as `isError` (:523-525, done). If any item can't be met, drop 2025-11-25 from the default list and say why in the CHANGELOG.

### 1.1b `server/discover` probe answer (stdio and Rack)
- Keep answering `server/discover` with **`-32601 Method not found`, echoing the id**. That's what fast-mcp does today (probe: `{"code":-32601,"message":"Method not found: server/discover"},"id":1`). The TS client 2.3.1 and Ruby SDK 1.8.0 both treat it as "legacy server" and fall back (verified in `auto` mode: TS → `2024-11-05`, Ruby → `2024-11-05`).
- Don't answer `-32022` with a handshake-only `supported` list, and never `-32602`: both also fall back, but `-32601` is the honest "not implemented" signal and needs no envelope parsing.
- Make sure nothing on this path can raise (a 5xx or a crash over HTTP is a **hard** client failure with no fallback, §0b). The stdio process must exit promptly on SIGTERM, because TS clients spawn and reap a throwaway probe process.
- Add a spec that pins this answer for a well-formed envelope, a malformed one, and an unsupported revision.

### 1.2 Request body size limit (G7, GHSA-fmmv class)
(unchanged from the Oct 12 draft) `lib/mcp/transports/rack_transport.rb`:
- New option `max_request_bytes` (default `4 * 1024 * 1024`, the same 4 MiB the v2.0.0 Everything server and the TS SDK use; `nil` = unlimited), read in `initialize` (:39).
- Use a helper in `process_json_request_with_server` instead of `request.body.read`:
```ruby
class PayloadTooLarge < StandardError; end

def read_limited_body(request)
  limit = @max_request_bytes
  return request.body.read if limit.nil?
  len = request.env['CONTENT_LENGTH']
  raise PayloadTooLarge if len && len.to_i > limit
  body = request.body.read(limit + 1) || ''
  raise PayloadTooLarge if body.bytesize > limit
  body
end
```
- Rescue it in `handle_message_request_with_server` and return `json_rpc_error_response(413, -32_600, "Request body too large (limit #{limit} bytes)")`.
- Apply the same to `authenticated_rack_transport.rb` if it overrides body reading (check).
- stdio: cap the line length. Use `$stdin.gets("\n", @max_request_bytes + 1)`. When a line has reached the limit without a newline, discard the rest up to the next newline and `send_error(-32_600, 'Request too large', nil)`.

### 1.3 Per-session resource subscriptions with cleanup (G3; servers #4712/#5032)
(unchanged) `lib/mcp/server.rb`:
- `@resource_subscriptions = Hash.new { |h, k| h[k] = Set.new }`, keyed by URI and holding **session keys**, guarded by `@subscriptions_mutex`.
- Session key = `current_request&.session_id || current_request&.client_id || :stdio`. Check `request_context_for` (rack_transport :169); add `session_id:` to the context hash in both rack_transport and the graph_mem transport if it's missing.
- subscribe adds the key; unsubscribe deletes the key (not the request id) and drops empty URIs. New public `remove_subscriber(session_key)` returns the number of URIs touched.
- `notify_resource_updated(uri)`: `@transport.send_message_to(session_key, notification)` if the transport responds to it, otherwise `send_message` (stdio has one session).
- rack_transport: `send_message_to(client_id, message)`. `unregister_sse_client` / `cleanup_sse_connection` call `@server.remove_subscriber(client_id)`.
- Forward-compat note for PR-4: v2.0.0 Memory keeps the same split (`resources/subscribe` on the 2025 era only; on 2026-07-28 the entry's listen router filters, `src/memory/index.ts:768`, :1162-1176), so this per-session design is what the 2025 era needs either way.

### 1.4 Legacy SSE session semantics (servers #5020)
(unchanged) Server-issued `sessionId` in the `endpoint` event (keep the param name `setup_sse_connection` uses today); duplicate GET id → **409** (remove the takeover; option `allow_sse_reconnect_takeover: false`); POST without an id → **400** `-32600 "Missing sessionId"`, unknown → **404** `-32001 "Session not found"` echoing the JSON-RPC `id` (`require_sse_session: true` default); idle reaping (`sse_idle_timeout`, default 30 min) calling `remove_subscriber`. Note that 2026-07-28 reclassifies HTTP+SSE as **Deprecated** (SEP-2596), which is why graph_mem docs mark `/mcp/sse` as deprecated (decision D-3) while still hardening it here.

### 1.5 CORS allowlist (G20)
(unchanged) Reflect an allowed `Origin` (validated by `validate_origin`, :201) instead of `'*'`, add `Vary: Origin`, option `cors_allowed_origins:`. Add `MCP-Protocol-Version` to `Access-Control-Allow-Headers` and `Mcp-Session-Id, MCP-Protocol-Version` to `Access-Control-Expose-Headers` (the v2.0.0 Everything server exposes `mcp-protocol-version`, `streamableHttp.ts:148-152`).

### 1.6 Strict JSON-RPC 2.0 handling (new; mirrors Ruby SDK `lib/json_rpc_handler.rb` and the TS server)
Ruby SDK 1.8.0's change (#590, `lib/mcp/client/stdio.rb`, `lib/mcp/client/http.rb`) is **client-side**: it rejects *server* messages without `"jsonrpc": "2.0"`. fast-mcp already passes that (every outbound path sets it; §0). The work here is on fast-mcp's **inbound** side, where the probes found real deviations. `server.rb#handle_request` (:245-299):
1. **Parse error** → `-32700 "Parse error"`, `id: null` (today `-32600`).
2. **Body that is not a JSON object** (array, number, string, `null`) → `-32600 "Invalid Request"`, `id: null`, no exception text. Arrays get the message `"JSON-RPC batching is not supported"` (batching was removed in 2025-06-18). Today: `-32600 "Internal error: no implicit conversion of String into Integer"`.
3. **`jsonrpc` missing or not exactly `"2.0"`** → `-32600`, echoing a valid `id` (already done; keep it, add a spec).
4. **`id` shape:** an id must be a String or an Integer (MCP forbids `null` ids on requests). Any other type → `-32600`, `id: null`. `method` must be a String, and `params`, when present, an object (MCP never uses positional params) → otherwise `-32600` / `-32602`.
5. **Notifications** (a message with `method` and no `id`): **never reply**. An unknown notification is logged and dropped. `notifications/cancelled` and `notifications/initialized` are accepted silently. Today an unknown notification gets a `-32601` reply with `id: null` (probe `jsonrpc_unknown_notification`).
6. **Responses posted by the client** (`result`/`error` with an id, no `method`) → ignored as today (`when nil`), but only when they really are response-shaped. A message with neither `method` nor `result`/`error` → `-32600`.
7. **Internal errors** (the rescue at :292-298) → `-32603 "Internal error"`. Log the message server-side and send it to the client only when a new `expose_internal_errors: false` option (default false) is turned on; today `e.message` is always sent.
8. On stdio, keep replying to a malformed line (unlike the TS SDK, which goes silent, §0b): JSON-RPC says the server SHOULD answer a parse error, and the Ruby SDK client fails fast on any reply it can't parse, which is better than hanging until its timeout.
9. **Outbound guard:** in `send_response`, assert (spec-only, or a debug-mode `raise`) that every message is a Hash with `jsonrpc: '2.0'` and exactly one of `result`/`error` for responses, so a future change can't regress Ruby SDK ≥1.8.0 clients.

### 1.7 OAuth 2.1 resource server (Ruby SDK 1.8.0 #545): only reserve the hook (decided, see Decisions D-9)
- What 1.8.0 ships (verified in `lib/mcp/server/oauth/*.rb`, `docs/_server/authorization.md`): a `token_verifier:` hook on `StreamableHTTPTransport` with `JWTVerifier` (issuer and audience taken from the RFC 9728 metadata and **both required**; `alg: none` refused, HMAC and asymmetric algorithms can't share an allowlist), `IntrospectionVerifier` (RFC 7662), RFC 6750 challenges (401 `invalid_token`, 403 `insufficient_scope`), and `ProtectedResourceMetadataMiddleware` (RFC 9728). Token issuance stays external.
- Recommendation: **don't adopt now.** graph_mem runs on Steve's LAN behind a static bearer plus an IP allowlist (`lib/graph_mem/mcp_access_policy.rb`), which already returns `WWW-Authenticate: Bearer` on 401 (§0). In fast-mcp, only reserve the interface so it can be added later without breaking anything: `AuthenticatedRackTransport` gets an optional `token_verifier:` duck type (`verify(token) → { subject:, scopes: [], expires_at:, resource: } | nil`) next to the existing static-token check, plus `required_scopes:`. Write it up in the README as "not implemented". If it's ever built, copy 1.8.0's rules exactly: aud == canonical resource URL, iss pinned, no `none`, no mixing HMAC and RSA, and the metadata document served outside the protected scope.
- Probe-related constraint to keep in mind: a 401/403 answer to a `server/discover` probe is a **hard** failure in the TS client (no legacy fallback, §0b). That's correct for a missing token, but the auth layer must not 401 anything a configured client legitimately sends.

### 1.8 Docs
README (fork): name steveoro/fast-mcp as the fork of yjacquin/fast-mcp, document the new options, the handshake versions and that 2026-07-28 isn't served yet (clients fall back through `server/discover` → `-32601`). CHANGELOG entry:
```
## [1.8.0] - 2026-10-xx
### Added
- Handshake negotiation: HANDSHAKE_PROTOCOL_VERSIONS (2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05); initialize echoes a supported requested version, otherwise answers the newest (never 2026-07-28, which has no handshake). Server.new(protocol_versions:) to cap.
- max_request_bytes (Rack, default 4 MiB → 413) and stdio line cap.
- Per-session resource subscriptions; Server#remove_subscriber; Transport#send_message_to.
- cors_allowed_origins; Vary: Origin; MCP-Protocol-Version in allowed/exposed CORS headers.
### Changed (behaviour)
- Strict JSON-RPC 2.0: -32700 on parse errors, -32600 on non-object/batch bodies and bad ids, -32603 on internal errors (message hidden unless expose_internal_errors), notifications are never answered.
- Legacy SSE: messages POST requires a known sessionId (400/404); a duplicate GET /sse id → 409 instead of taking over the stream; idle SSE clients are reaped.
### Fixed
- resources/unsubscribe never removed subscriptions (keyed by request id).
- Unknown notifications got a -32601 reply with id null.
```

### 1.9 Specs (RSpec; fast-mcp uses `spec/`)
```ruby
# spec/mcp/server_protocol_negotiation_spec.rb
RSpec.describe FastMcp::Server do
  let(:server) { described_class.new(name: 't', version: '0') }
  {
    '2024-11-05' => '2024-11-05', '2025-03-26' => '2025-03-26', '2025-06-18' => '2025-06-18',
    '2025-11-25' => '2025-11-25', '2026-07-28' => '2025-11-25', '2099-01-01' => '2025-11-25',
    'garbage' => '2025-11-25', nil => '2025-11-25', 42 => '2025-11-25'
  }.each do |asked, answered|
    it("answers #{answered} when asked #{asked.inspect}") { expect(server.negotiate_protocol_version(asked)).to eq(answered) }
  end
  it 'honours protocol_versions: and rejects modern entries' do
    capped = described_class.new(name: 't', version: '0', protocol_versions: %w[2025-03-26 2024-11-05])
    expect(capped.negotiate_protocol_version('2025-11-25')).to eq('2025-03-26')
    expect { described_class.new(name: 't', version: '0', protocol_versions: %w[2026-07-28]) }.to raise_error(ArgumentError)
  end
end

# spec/mcp/server_discover_probe_spec.rb — the legacy-fallback contract
ENV_META = { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28', 'io.modelcontextprotocol/clientCapabilities' => {} }
it 'answers server/discover with -32601 and the same id (well-formed, malformed, future-revision envelopes)'
it 'serves initialize normally after a failed server/discover on the same stdio connection'

# spec/mcp/server_jsonrpc_strictness_spec.rb
it('parse error → -32700, id null')
it('array body → -32600 "JSON-RPC batching is not supported", id null')
it('number/string/null body → -32600, id null, no Ruby exception text in message')
it('object id or boolean id → -32600')
it('unknown notification gets NO response; notifications/cancelled gets no response')
it('internal error → -32603 without e.message unless expose_internal_errors')
it('every outbound message has jsonrpc "2.0"')   # wrap transport.send_message and assert across a full session

# spec/mcp/transports/rack_transport_body_limit_spec.rb, server_subscriptions_spec.rb,
# rack_transport_sse_sessions_spec.rb, CORS specs — unchanged from the Oct 12 draft
it 'returns 413 when Content-Length exceeds max_request_bytes' do
  transport = described_class.new(app, server, max_request_bytes: 10, logger: Logger.new(nil))
  env = Rack::MockRequest.env_for('/mcp/messages?sessionId=x', method: 'POST', input: '{"a":"' + 'x' * 50 + '"}')
  status, = transport.call(env)
  expect(status).to eq(413)
end
it 'returns 413 when the body exceeds the limit without Content-Length (chunked)'
it 'removes all subscriptions for a session on remove_subscriber'
it 'notifies only subscribed sessions'
it 'unsubscribe actually removes the subscription'
it('POST messages without sessionId → 400'); it('unknown sessionId → 404 echoing the JSON-RPC id')
it('second GET /sse with a connected id → 409, original stream untouched'); it('idle SSE client is reaped')
it('reflects an allowed Origin and sets Vary: Origin'); it('omits Access-Control-Allow-Origin for a disallowed Origin')
```
stdio: add `input:` / `output:` IO options to `StdioTransport#initialize` (:10; today it uses `$stdin` :21 and `$stdout` :42-43 directly), which graph_mem PR-2 §2.13 needs. An over-long line through a `StringIO` gives a `-32600` error and the next valid line is still processed. Add an **interop spec** (tagged `:interop`, skipped when the gem is missing) that runs the Ruby SDK client (`gem "mcp", "~> 1.8"` in the dev group only) against `examples/server_with_stdio_transport.rb` in `mode: :auto` and `:legacy`, so the probe fallback and strict JSON-RPC stay covered.

### 1.10 Acceptance criteria
- `bundle exec rspec` and `rubocop` are green. The existing initialize specs are updated (they currently expect 2024-11-05 for any request).
- Manual stdio check with `/workspace/triage/mcp-compat/drive.rb` and `scenarios.json` against the synthetic server: `initialize 2026-07-28` → `2025-11-25`; `server/discover` → `-32601`; parse error → `-32700`; no reply to `notifications/cancelled`.
- Ruby SDK 1.8.0 client `auto` and `legacy` both connect (today: both connect at 2024-11-05; afterwards they should negotiate 2025-11-25).
- No change in default behaviour for well-behaved clients other than the documented SSE and JSON-RPC strictness.

### 1.11 Risks and rollback
- Stricter SSE session checks could break old clients that POST without `sessionId`: the `require_sse_session` / `allow_sse_reconnect_takeover` options. Rollback: graph_mem keeps pinning `b10243c` until PR-2.
- Clients that (wrongly) relied on a reply to a notification: none known. The TS and Ruby SDKs both expect silence.
- Advertising 2025-11-25 while missing something it implies: mitigated by the checklist in §1.1.
- stdio `gets` with a limit splits lines; a spec must cover it.

### 1.12 graph_mem as the reference implementation (new, decision 7)
Steve's rule: keep fast-mcp current first, with graph_mem as its first reference consumer. So every new fast-mcp 1.8.0 feature gets **one real use in graph_mem 1.53.0**, and each side documents the link. Add a "Reference implementation" section to the fast-mcp README and a "fast-mcp feature map" section to graph_mem `docs/architecture.md`:

| fast-mcp 1.8.0 feature | Where graph_mem 1.53.0 demonstrates it |
|---|---|
| `Server#negotiate_protocol_version`, `HANDSHAKE_PROTOCOL_VERSIONS`, `protocol_versions:` | `lib/graph_mem/mcp_streamable_http_transport.rb#resolve_session` (PR-2 §2.2.1); stdio through the runner |
| `Server#supported_protocol_version?` | the same transport's `MCP-Protocol-Version` check (PR-2 §2.2.2) |
| `filter_tools` / `filter_prompts` (already 1.7.x) | `config/initializers/fast_mcp.rb:35-42` + `GraphMem::McpProfile` (`/mcp`, `/mcp/readonly`, `/mcp/maintenance`) |
| `StdioTransport` `input:` / `output:` | `bin/mcp_stdio_runner.rb` (PR-2 §2.13, clean stdout) |
| `max_request_bytes`, `cors_allowed_origins`, `require_sse_session`, `allow_sse_reconnect_takeover`, `sse_idle_timeout` | `config/initializers/fast_mcp.rb` legacy `/mcp/sse` options (PR-2 §2.1) |
| `Transport#send_message_to`, `Server#remove_subscriber` | `McpStreamableHttpTransport#send_message_to`, `close_session` + the reaper (PR-2 §2.5) |
| strict JSON-RPC (`-32700/-32600/-32603`, silent notifications), `expose_internal_errors:` | stdio path as is; the Streamable HTTP transport mirrors it (PR-2 §2.3a) |
| `token_verifier:` hook (reserved, not implemented) | not used: graph_mem keeps the static bearer + IP policy (`GraphMem::McpAccessPolicy`). Documented as the deliberate non-use |

Spec on the fast-mcp side: every row's option is covered by a spec under `spec/mcp/`. On the graph_mem side: PR-2 §2.12 specs exercise each row.

---
## PR-0 [Claude] — graph_mem (part of 1.53.0): read-only home-folder scan mount, ScanRootPolicy, subfolder filter, denylist

- **Why:** graph_mem mostly runs as a container (`docker-compose.yml`, `config/deploy.yml`) and nothing mounts host folders into it, so `scan_project`, the dashboard scan forms and guided scans only see the container's own filesystem. Meanwhile `POST /api/v1/scan` and MCP `scan_project` accept **any** directory. No MCP protocol code is touched.
- **Base:** `main` after **UI-0** has merged (hard dependency, §C). **Branch:** `claude/pr-0-scan-home-mount`. **Title:** `Scans: read-only home mount (identity path), one ScanRootPolicy for UI/API/MCP/jobs, runtime subfolder filter, hard denylist`.
- **Version:** none of its own. `## [Unreleased]` entries (§0.11); PR-2 releases them as 1.53.0.

### 0.0 What the code does today (verified at `57d9524`, synthetic temp dirs only)
| Area | Today | Problem |
|---|---|---|
| Container | `Dockerfile`: uid/gid 1000 (`useradd rails --uid 1000`), `WORKDIR /rails`, `USER 1000:1000`. The compose `app` service mounts only `${DB_BACKUP_HOST_PATH}:/rails/db/backup` and `graph_mem_storage`; `network_mode: host`. Kamal `config/deploy.yml` mounts only storage. | No host folder is visible, so container scans can't work. |
| Allowed roots | `AppSettings.project_scan_roots` (DB, Settings › Project scans), default `[Dir.pwd, Dir.home, Dir.tmpdir]` (`app/models/app_settings.rb:42`). `project_scan_root_paths` (:74-79) falls back to `ENV["PROJECT_SCAN_ROOTS"]` only when the setting is blank, which never happens. Settings are read through rails-settings-cached (process cache); only some readers bypass it (`read_boolean_setting`, :141-148). | In a container the defaults are `/rails` (the app itself, incl. `config/`), `/home/rails`, `/tmp`. The ENV fallback is dead code. A web form can widen the boundary to `/`. A cached read could make a job see a stale value. |
| Enforcement | Only `ProjectScansController#allowed_root?` and `ProjectScanSkillsController#allowed_root?` (duplicated; realpath + prefix). | **`Api::V1::ScanProjectsController#create` (`scan_projects_controller.rb:8-18`) and `ScanProjectTool#call` (`scan_project_tool.rb:36-47`) check nothing.** `ProjectScanJob` / `ProjectScanner` / `ProjectScanSkill` (`project_scan_skill.rb:46`) never re-check. `ProjectScansController` stores `expanded_root` rather than the realpath it checked (:36). |
| File discovery | `ProjectScanner#discover_files` (`project_scanner.rb:266-277`): `Dir.glob(File.join(@project_root, g))` for caller `file_globs`, else `**/*` (dotfiles skipped by default) with a text-extension filter; `File.file?` follows symlinks. | **Escapes the root:** `file_globs: ["../outside/*"]` returns files outside it, and a symlinked file pointing outside is read (both reproduced). Explicit globs can also hit `.env`, `.git/config` (may embed tokens), key files. `first(@max_files).sort` truncates before sorting. |
| Errors | "Project root is not a directory" / "outside the allowed scan directories" | A pasted host path gets "not a directory", with no hint that it simply isn't mounted. |

### 0.1 Mount model (decision S-5): identity-mapped home, read-only
`docker-compose.yml`, `app` service:
```yaml
    environment:
      # ...existing...
      OPERATOR_USERNAME: ${OPERATOR_USERNAME:-}          # (UI-0)
      OPERATOR_PASSWORD: ${OPERATOR_PASSWORD:-}          # (UI-0)
      # Scan root = the host user's home, at the SAME path inside the container.
      GRAPH_MEM_SCAN_ROOTS: ${GRAPH_MEM_SCAN_HOME:-${HOME}}
      GRAPH_MEM_SCANS: ${GRAPH_MEM_SCANS:-on}            # "off" disables scans without touching the mount
    volumes:
      - ${DB_BACKUP_HOST_PATH:-./db/backup}:/rails/db/backup
      - graph_mem_storage:/rails/storage
      # READ-ONLY. Same path in and out, so /home/steve/Projects/foo works as typed.
      - ${GRAPH_MEM_SCAN_HOME:-${HOME}}:${GRAPH_MEM_SCAN_HOME:-${HOME}}:ro
```
- `Dockerfile`: `ENV GRAPH_MEM_IN_CONTAINER=1`. No `mkdir` is needed (the bind mount creates the mount point).
- `.env.example` documents `GRAPH_MEM_SCAN_HOME=` ("leave empty to use the HOME of the user running compose; set it explicitly for systemd/cron, where HOME may be unset"). Nested default interpolation (`${A:-${B}}`) is supported by Docker Compose v2. Acceptance checks it with `docker compose config`.
- **No path map in 1.53.0.** Identity mapping makes it unnecessary on Linux Docker/Podman. `ScanRootPolicy#map_host_path(input)` exists as a single seam returning `input` unchanged. A future non-identity host (Docker Desktop on Windows, Kamal to another box) adds `GRAPH_MEM_SCAN_PATH_MAP` there. The Oct 20 draft's `/scan` + map design is dropped.
- **Hard roots** (`ScanRootPolicy.hard_roots`): container mode → `GRAPH_MEM_SCAN_ROOTS` (`:`-separated, realpath'd). Native mode (`bin/dev`, no `GRAPH_MEM_IN_CONTAINER`) → `GRAPH_MEM_SCAN_ROOTS` or `Dir.home`. That's the same "home is the boundary" semantics, so specs set `GRAPH_MEM_SCAN_ROOTS` to a tmpdir. `PROJECT_SCAN_ROOTS` is dropped (it was dead code; noted in the CHANGELOG).
- **Overlap guard:** a hard root is rejected (`:not_configured`, logged at boot) if it is `/`, or equals/contains/is inside `/rails` (`Rails.root`), `/usr`, `/etc`, `/bin`, `/sbin`, `/lib*`, `/proc`, `/sys`, `/dev`, `/var`, `/boot`, `/home/rails` (the container user's own home). The last item covers a host user that happens to be called `rails`. Running compose as root makes the root `/root`: allowed, but with an amber "running as root" warning.
- **Mount detection** (container mode): parse `/proc/self/mountinfo`. The root must be a mount point (field 5) or scans are disabled with `:not_configured` ("nothing is mounted at /home/steve: add the volume line"). If its options (field 6) contain `rw`, scans still work but Settings, Home and every scan result carry the amber **"mounted read-write, use :ro"** warning. Native mode skips detection.

### 0.2 Subfolder filter (runtime, no restart)
- New `AppSettings` field `project_scan_subfolders`, string, default **`"Projects"`**. It accepts a comma/newline-separated list of paths **relative to the home root** (`Projects, work/clients, oss/rails`). An absolute path under a hard root is accepted on save and stored relative (so pasting `/home/steve/Projects` works).
- It **replaces** `project_scan_roots`. The old field stays defined (read-only, hidden) for one release. If it holds a non-default value, Settings shows "Legacy scan roots value ignored: … [Clear]".
- **Validation on save** (`Operator::SettingsController#validate_project_scans_settings`, :207-218), per entry with its own error: it must be relative (after conversion), with no `..`, no empty segment, no segment that is denylisted or starts with `.` (§0.3), and ≤ 512 chars; at most 20 entries. An entry whose folder doesn't exist **is saved** but shown as "missing", so folders can be pre-configured. **Blank = the whole home** (still minus the denylist), with an amber warning.
- **Runtime read, uncached:** `AppSettings.project_scan_subfolders_raw` reads the row with a raw `SELECT` (the `read_boolean_setting` pattern, :141-148), so a change made in the web process is seen on the next call by **every** process (Puma, Solid Queue workers, the stdio runner). `ScanRootPolicy.allowed_roots` calls it on every invocation and never memoizes across calls.
- **Who re-reads it:** every entry point (§0.5 items 1-3, 6) at request time, **and** `ProjectScanJob#perform` / `ProjectScanSkill#initialize` at job start (§0.5 item 4). A scan whose folder left the filter between enqueue and start fails with the policy message. A scan already running isn't interrupted (its file list was fixed when discovery ran).

### 0.3 Hard denylist (constants, not settings; cannot be overridden)
`ScanRootPolicy::DENY` applies twice.
1. **Choosing a scan root:** no path segment *below the hard root* (checked on the lexical path **and** on the realpath) may
   - start with `.`. That covers `.ssh .gnupg .aws .azure .config .kube .docker .password-store .mozilla .thunderbird .local .cache .var .npm .gem .bundle .rvm .Trash` and every other dotfolder;
   - or be one of `snap` (snap app data, incl. browser profiles), `Library` (macOS), `AppData` (Windows), `Maildir`, `Mail`.

   Error `:denied` ("`/home/steve/.config/x` is inside a hidden or protected folder; this can't be enabled"). A symlink from `~/Projects/foo` into `~/.local/src/foo` is denied through the realpath check.
2. **Reading files inside a project** (`ProjectScanner#discover_files`, `ProjectScanSkill` file reads, `ProjectScanValidator` if it opens files): skip files and directories matching
   - directory segments `.git .ssh .gnupg .aws .kube .docker .password-store`;
   - files `.env .env.* *.pem *.key *.p12 *.pfx *.jks *.keystore *.kdbx id_rsa* id_dsa* id_ecdsa* id_ed25519* .netrc .npmrc .pypirc .git-credentials credentials credentials.* master.key *.tfstate *.tfstate.*`.

   This holds **even when an explicit `file_globs` entry names them**. Count them in `counters["skipped_denylisted"]`. Other dot-directories inside a project (`.github`, `.cursor`, `.devin`, `.claude`) are still reachable through explicit globs, as today. `**/*` keeps skipping dotfiles.
3. Settings › Project scans shows the denylist read-only ("Always blocked") so the operator knows why something is refused. A spec asserts that no setting value can make a denylisted path resolvable.

### 0.4 `ScanRootPolicy` (new `app/services/scan_root_policy.rb`, < 300 lines; split helpers into `scan_root_policy/` if needed)
```ruby
Result = Data.define(:ok, :path, :root, :code, :message, :warnings)
# codes: :ok, :blank, :invalid, :disabled, :not_configured, :not_mounted, :denied,
#        :not_found, :not_directory, :not_readable, :outside_roots, :outside_filter

ScanRootPolicy.hard_roots      # [{ path:, mounted:, read_only:, readable: }]  (§0.1)
ScanRootPolicy.allowed_roots   # hard_root/<each subfolder filter entry> that exists; blank filter ⇒ hard roots
ScanRootPolicy.resolve(input)  # → Result, steps below
ScanRootPolicy.contained?(root_real, path_real)   # == root || start_with?(root + "/")
ScanRootPolicy.denied_file?(root_real, file_path) # §0.3 rule 2, used by the scanners
ScanRootPolicy.status          # for Settings / Home / health JSON
```
`resolve(input)`, in order (each step returns a distinct code with an actionable message):
1. `GRAPH_MEM_SCANS=off` → `:disabled`. Container mode with no valid mounted hard root → `:not_configured` (the message includes the compose volume line).
2. Strip. Blank → `:blank`. NUL byte or > 4096 chars → `:invalid`.
3. Any `..` segment → `:invalid` ("use a path without '..'"); no attempt to clean it.
4. `~` or `~/…` → the single hard root (only when exactly one exists). A relative path resolves against the single allowed root when exactly one exists; otherwise `:invalid` ("give the full path").
5. `map_host_path` (identity in 1.53.0).
6. Not under any hard root → `:not_mounted` ("only `/home/steve` is visible to graph_mem").
7. Lexical denylist → `:denied`.
8. `File.realpath`: `ENOENT` → `:not_found` (the message names the path and says whether the parent exists); `EACCES` → `:not_readable` (with the uid-1000 hint, §0.7).
9. The realpath isn't `contained?` in its hard root → `:outside_roots` (a symlink escape). A denylisted realpath → `:denied`.
10. Not inside an allowed root → `:outside_filter` ("`/home/steve/Other/x` is outside the scan filter (`Projects`). Add `Other` in Settings › Project scans").
11. Not a directory → `:not_directory`. Not readable+executable → `:not_readable`.
12. `ok`, with `warnings` (e.g. `:mounted_read_write`, `:whole_home_allowed`, `:running_as_root`). The **realpath** is what gets stored and scanned.

### 0.5 Wire it into every entry point
1. `ProjectScansController#create`, `ProjectScanSkillsController#create`: replace `File.expand_path` + the private `allowed_root?` with `ScanRootPolicy.resolve`; flash `Result#message` (+ warnings); store the realpath. Delete the duplicated private methods.
2. `Api::V1::ScanProjectsController#create`: same; `render_error(result.message, details: { code: result.code })` → 422 (403 for `:denied`).
3. `ScanProjectTool#call`: same, `raise FastMcp::Tool::InvalidArgumentsError, result.message`. Description: "`project_root` is an absolute path under the operator's scan folders (see `scan_project_status` / the Settings page); hidden folders are never scannable." Return `project_root` and `warnings`.
4. `ProjectScanJob#perform`, `ProjectScanSkill#initialize` (`project_scan_skill.rb:46`): **re-resolve** at job start and fail the operation with the policy message.
5. `ProjectScanner#discover_files` (`project_scanner.rb:266-277`):
   - reject `file_globs` entries that are absolute or contain a `..` segment (failed result, nothing read);
   - after globbing, keep only files where `contained?(@root_real, realpath(f))` (`counters["skipped_outside_root"]`) and not `denied_file?` (`counters["skipped_denylisted"]`);
   - **`sort` before `first(@max_files)`**.

   Same filters in `ProjectScanSkill` file reads (:173, :392) and `ProjectScanValidator` if it opens files.
6. `lib/tasks/graphify.rake`: resolve `GRAPH` through the policy (the file's directory). Outside the roots → **warn** (operator shell, not a web input) unless `GRAPH_MEM_SCAN_STRICT=1`; denylisted → always refuse.
7. `Operator::SettingsController`: the `project_scans` group becomes `%w[project_scan_subfolders enable_project_scan_validation]` (`settings_controller.rb:141-144`), with the validation from §0.2.
8. `AppSettings.project_scan_root_paths` becomes a thin delegate to `ScanRootPolicy.allowed_roots.map { _1[:path] }` (kept for existing callers).

### 0.6 UI (Settings › Project scans, scan forms; the full picker comes in UI plan UI-6)
- **"Scan folders"**, read-only: each hard root with mounted ✓/✗, read-only ✓ / **amber "read-write: use :ro"**, readable. When nothing is mounted: a red "Scans are disabled: nothing is mounted" + the compose snippet + a docs link.
- **"Subfolder filter"**, editable (default `Projects`), with per-entry status (✓ exists · missing · rejected: reason) and the hint "Takes effect immediately for new scans, no restart."
- **"Always blocked"**, read-only: the denylist (§0.3).
- **"Check a path"** (Turbo Frame, `GET /operator/settings/project_scans/check_path?path=`) shows the `Result`: ✓ `/home/steve/Projects/foo` (read-only), or the code + message.
- Both dashboard scan forms list the allowed folders under the path field. The Project Scans card shows the disabled state.
- Health: `ScanRootPolicy.status` feeds the UI plan's Home pill.

### 0.7 Docs: `docs/container_scan_mounts.md` (new; linked from README "Docker" and `docs/app_settings_reference.md`, which also fixes its dead `plans/project_scan.md` link → `plans/done/project_scan.md`)
- **Linux Docker (tested):** the compose lines above. `docker run` equivalent: `-v "$HOME:$HOME:ro" -e GRAPH_MEM_SCAN_ROOTS="$HOME"`. Kamal: `volumes: ["/home/deploy:/home/deploy:ro"]` + `GRAPH_MEM_SCAN_ROOTS` (untested).
- **Always `:ro`.** The scanner never writes, and read-only stops anything in the container from touching your home.
- **UID/permissions:** the app runs as uid/gid 1000. If your host uid is 1000 (the usual first user), it reads your files as you. Otherwise grant read on the scanned subfolders only: `setfacl -m u:1000:x "$HOME"` (traverse only) plus `setfacl -R -m u:1000:rX -m d:u:1000:rX ~/Projects`, or a shared group via `group_add`. **Never** `chmod -R o+r $HOME`. Don't change the container `user:` (`storage/`, `log/`, `tmp/` are owned by 1000).
- **Rootless Podman (best-effort, not CI-tested):** works with `podman compose` using the same file plus an override:
  ```yaml
  services:
    app:
      userns_mode: "keep-id:uid=1000,gid=1000"   # your host uid ↔ container uid 1000 (Podman ≥ 4.3)
      security_opt: ["label=disable"]           # SELinux hosts: see below
  ```
  Quadlet (`~/.config/containers/systemd/graph_mem.container`, after building or pulling the image):
  ```ini
  [Container]
  Image=localhost/graph_mem:latest
  Network=host
  UserNS=keep-id:uid=1000,gid=1000
  SecurityLabelDisable=true
  Volume=%h:%h:ro
  Environment=GRAPH_MEM_SCAN_ROOTS=%h
  EnvironmentFile=%h/.config/graph_mem/env
  ```
  **SELinux (Fedora/RHEL, Podman or Docker):** an unlabelled bind mount reads as "permission denied". **Never use `:z` or `:Z` on your home directory**: they relabel every file under it recursively, which breaks other confined programs, and `:Z` makes it private to this one container. Use `:ro` + `label=disable` (as above; weaker isolation for this container only), or mount individual project subfolders with `:ro,z` instead of the home **only** if those folders are dedicated to graph_mem (then set `GRAPH_MEM_SCAN_ROOTS` to them).
- **Docker Desktop (macOS/Windows):** untested. Identity mapping should work on macOS (`/Users/steve`) once the folder is shared in Docker Desktop; Windows needs the future path map.
- **Changing what's scannable:** the subfolder filter is runtime (Settings). Changing the **mount** (`GRAPH_MEM_SCAN_HOME`) needs `docker compose up -d` (it recreates `app`).
- **Symlinks:** links that resolve outside the home root, or into a hidden folder, are skipped.

### 0.8 Specs (synthetic temp dirs only: `Dir.mktmpdir`, never real trees; `GRAPH_MEM_SCAN_ROOTS` set per example)
```
# spec/services/scan_root_policy_spec.rb
- inside an allowed subfolder → ok (realpath returned); the subfolder itself → ok
- sibling prefix (/tmp/x/home2 vs root /tmp/x/home) → :not_mounted
- any '..' segment → :invalid (also 'foo/../..'); NUL / 5000 chars → :invalid; blank → :blank
- '~/Projects/a' and relative 'a' resolve with one root; relative with two roots → :invalid
- dot segment at any depth (.ssh, Projects/.secret/x, .config/y) → :denied; 'snap/x', 'Library/x' → :denied
- symlink inside Projects → outside the root → :outside_roots; → into root/.ssh → :denied; → elsewhere inside Projects → ok
- path in home but outside the filter → :outside_filter with the add-to-filter hint
- filter 'Projects, work/clients' → both allowed; blank filter → whole home ok, warning :whole_home_allowed
- runtime: update the setting row with raw SQL (as another process would), then resolve → the new filter applies with no reload/restart
- GRAPH_MEM_SCANS=off → :disabled; container mode + no root → :not_configured; root not in mountinfo → :not_configured
- mountinfo fixtures: ro mount → no warning; rw mount → :mounted_read_write warning
- overlap guard: root '/', '/rails', Rails.root, '/home/rails', '/usr/local' → rejected
- file instead of dir → :not_directory; chmod 000 → :not_readable (skipped when running as root)
# spec/services/scan_root_policy_denied_file_spec.rb
- .env, .env.local, config/master.key, id_ed25519, .git/config, deploy.pem, terraform.tfstate → denied; app/models/x.rb, .github/workflows/ci.yml → allowed
# spec/models/app_settings_project_scan_subfolders_spec.rb + spec/requests/operator/settings_spec.rb
- default 'Projects'; save rejects '../x', '/etc', '.ssh', 'Projects/.git' with per-entry errors; absolute under home stored relative; missing folder saved + shown missing; check_path frame renders each code
# spec/services/project_scanner_spec.rb (additions)
- file_globs ['../outside/*'] or ['/etc/*'] → failed result, nothing read
- symlinked file to outside the root is skipped (skipped_outside_root); explicit glob '.env' skipped (skipped_denylisted)
- sort happens before the max_files cap (deterministic set)
# spec/requests/project_scans_spec.rb, project_scan_skills_spec.rb: home path accepted; /etc → :not_mounted; .ssh → :denied; outside filter → :outside_filter message
# spec/requests/api/v1/scan_projects_spec.rb: (with operator session, UI-0) outside → 422 {code: "outside_filter"}; .ssh → 403 {code: "denied"}
# spec/tools/scan_project_tool_spec.rb: same codes via InvalidArgumentsError
# spec/jobs/project_scan_job_spec.rb: folder removed from the filter after enqueue → operation fails with the policy message
```
Manual acceptance (PR description): `GRAPH_MEM_SCAN_HOME=$(mktemp -d)` containing a synthetic `Projects/demo` (two files plus a `.env` decoy), `docker compose config` (shows the resolved mount, `:ro`), `docker compose up -d --build`, then scan by host path from the UI and via MCP. Confirm `.env` was skipped, `…/.ssh` is refused, editing the filter takes effect without a restart, and with the volume removed scans report "nothing mounted".

### 0.9 Acceptance criteria
- With the default compose and `HOME=/home/steve`, pasting `/home/steve/Projects/foo` in the dashboard, `POST /api/v1/scan` (authenticated) or MCP `scan_project` scans exactly that path.
- `/etc`, `/rails`, `/home/steve/.ssh`, `/home/steve/Other/x` (outside the filter) and `foo/../../x` are rejected on **all three** entry points and at job start, with distinct, actionable messages, and nothing is enqueued.
- Editing the subfolder filter in Settings affects the next scan request and the next job start in every process, without a restart.
- A symlink pointing outside the home or into a hidden folder is never read; `file_globs` can't escape the root or read denylisted files.
- Settings shows mounts with read-only/read-write status, the filter, the denylist and "check a path". With no mount, scans are clearly disabled.
- Native (`bin/dev`) installs: home is the boundary and `Projects` is the default filter, so a dev scanning `/tmp/foo` must set `GRAPH_MEM_SCAN_ROOTS` or the filter. This is called out in the CHANGELOG.
- `docker compose config` is valid with and without `GRAPH_MEM_SCAN_HOME`.

### 0.10 Risks and rollback
- **Behaviour change** for API/MCP callers that scanned arbitrary paths: intended (it was a hole), and called out.
- **Native dev change:** `Dir.pwd` and `Dir.tmpdir` are no longer default roots. Specs set `GRAPH_MEM_SCAN_ROOTS`, and the docs say how.
- The whole home is visible inside the container, read-only. The denylist, the filter and UI-0's auth are the layers that keep it safe, and the order rule (UI-0 first) is part of the plan.
- SELinux advice copied blindly: the docs lead with "never `:z`/`:Z` on home".
- Rollback: revert the PR. The compose volume line is harmless without the app code (an extra read-only mount); drop it too to remove the exposure.

### 0.11 CHANGELOG (`## [Unreleased]`, released by PR-2 as 1.53.0)
```
### Added
- Project scans in containers: the host user's home is mounted read-only at the same path (`${HOME}:${HOME}:ro`, override with GRAPH_MEM_SCAN_HOME); GRAPH_MEM_SCAN_ROOTS / GRAPH_MEM_SCANS; Settings › Project scans shows mounts (read-only/read-write), a runtime subfolder filter (default "Projects"), the always-blocked list and a path checker. docs/container_scan_mounts.md (Linux Docker; rootless Podman best-effort; SELinux, UID).
### Changed
- `project_scan_roots` is replaced by `project_scan_subfolders` (relative to the scan root, editable at runtime); PROJECT_SCAN_ROOTS (never effective) is removed. Native installs default to home + "Projects".
### Security
- One ScanRootPolicy for the dashboard, POST /api/v1/scan, MCP scan_project and job start (previously the API and MCP accepted any directory). Hidden folders and secret files (.ssh, .gnupg, .aws, .env, keys, .git/config, …) are never scanned, even via explicit file_globs. `..`/absolute file_globs are rejected; symlinks resolving outside the root are skipped.
### Fixed
- Scanner applied max_files before sorting (non-deterministic file set).
```

---
## PR-2 [Claude] — graph_mem v1.53.0: bump fast-mcp to v1.8.0 plus transport and tool hardening (the release PR of 1.53.0)

- **Base:** `main` **after** UI-0 and PR-0 have merged (both write `## [Unreleased]`), and after Steve has tagged fast-mcp `v1.8.0`. M-D1…M-D3 (Devin-simple) may merge before or after; whatever has merged is folded in.
- **Branch:** `claude/pr-2-mcp-hardening-1.53`
- **Title:** `MCP hardening: fast-mcp 1.8.0, handshake to 2025-11-25, MCP-Protocol-Version, body/shape validation, clean stdio, query cap, targeted notifications, race-safe writes, CORS allowlist`
- **Version:** `lib/graph_mem/version.rb` `1.52.1` → **`1.53.0`**. This PR renames `## [Unreleased]` to `## [1.53.0] - <merge date>` and adds its own entries (§2.16), so the release notes cover UI-0 + PR-0 + PR-2 (+ any merged M-D items).
- **Reference implementation:** each fast-mcp 1.8.0 feature gets one real use here (map in PR-1 §1.12). Add the "fast-mcp feature map" section to `docs/architecture.md` in this PR.
- **Contains the two high bugs** Steve wants in 1.53.0: §2.3a (a JSON-array POST body is returned as the raw Rack response) and §2.13 (`config/initializers/fast_mcp.rb:24` logs to STDOUT, which breaks strict stdio clients). Both were re-verified at `57d9524` on 2026-10-21.

### 2.1 Gemfile bump
`Gemfile:35-37`: change `ref:` to the merged fast-mcp v1.8.0 SHA, with the comment `# FastMCP v1.8.0`, then `bundle update fast-mcp --conservative` (Gemfile.lock:6 → `fast-mcp (1.8.0)`). In `config/initializers/fast_mcp.rb`, pass the new legacy-SSE options explicitly (`max_request_bytes`, `cors_allowed_origins`, `require_sse_session: true`).

### 2.2 Handshake negotiation and `MCP-Protocol-Version` over Streamable HTTP (G1), modelled on v2.0.0
`lib/graph_mem/mcp_streamable_http_transport.rb`:
1. **`resolve_session` (:350-354).** Replace the string compare with the fast-mcp negotiator, so HTTP and stdio give the same answer:
```ruby
requested = parsed.dig(:params, :protocolVersion)
version   = @server.negotiate_protocol_version(requested)  # echo if supported, else newest (2025-11-25)
session   = build_session(session_id, version)
```
Note: use the per-profile `@server` the request routes to; all three profile servers share the same list. Keep `normalize_initialize_protocol_version!` (:572) as a safety net, but it should now be a no-op.
2. **Header check** (new private `protocol_version_error(request, session)`), called **after** session resolution on every non-initialize POST (:228-232), on GET (:296-310) and on DELETE (:336-343). The order matters: unknown session → 404 first, exactly like the reference (`server@2.3.1 dist/index.mjs:759`).
```ruby
header = request.env["HTTP_MCP_PROTOCOL_VERSION"]&.strip
return nil if header.nil? || header.empty?                       # absent → accept (pre-2025-06-18 clients)
return nil if @server.supported_protocol_version?(header)        # any handshake version, need not equal the negotiated one
json_rpc_error_response(400, -32_000,
  "Bad Request: Unsupported protocol version: #{header} (supported versions: #{@server.protocol_versions.join(', ')})", request_id)
```
`2026-07-28` on a session therefore → 400, as on v2.0.0 Everything (probe `session_header_modern`).
3. **`initialize` with a modern header.** The reference answers 400 `-32020`. graph_mem stays **lenient**: ignore the header, negotiate from the body and log a debug line. The TS client's fallback `initialize` carries no 2026 headers (`client@2.3.1 dist/index.mjs:3343`), so neither choice breaks a reference client; PR-3 records it as a deliberate difference.
4. **Session-less, non-initialize POST** (the 2026-07-28 probe and any modern request): keep the 4xx JSON-RPC answer, and **never** 401/403/5xx for a client that passed the access policy. Today it's `400 -32600 "Bad Request: missing Mcp-Session-Id header"` (:304/:339/:367), which the TS client classifies as legacy (verified). Improve it by echoing the request `id` when the body parsed (the reference does, `readRequestId`). Create no session (already true; keep a spec).
5. Session state: store `negotiated_protocol_version` (already `requested_protocol_version`) and expose it to tools only for logging.
6. Update the class comment (:12-24): "Streamable HTTP (handshake versions 2024-11-05 … 2025-11-25) + legacy 2024-11-05 SSE; 2026-07-28 clients fall back through a failed `server/discover` probe."

### 2.3 Request body size cap (G7)
(unchanged) In `handle_streamable_post` (:222), replace `request.body.read` with `read_limited_body` (`MAX_REQUEST_BYTES = 4 * 1024 * 1024`, overridable via options / `ENV["GRAPH_MEM_MCP_MAX_REQUEST_BYTES"]`) → `json_rpc_error_response(413, -32_600, "Request body too large")`, checked before session resolution so an oversized POST never creates a session.

### 2.3a JSON body shape validation — fixes the array-reflection bug (new, high)
`handle_streamable_post` :225-226 uses `parsed.is_a?(Array)` both as "parse_json returned an error triplet" and, by accident, as "the client sent a JSON array" (§0: a crafted array becomes the Rack response). Fix:
```ruby
def parse_json(body)
  [ :ok, JSON.parse(body, symbolize_names: true) ]
rescue JSON::ParserError
  [ :error, json_rpc_error_response(400, -32_700, "Parse error: Invalid JSON") ]
end

kind, parsed = parse_json(body)
return parsed if kind == :error
unless parsed.is_a?(Hash)
  msg = parsed.is_a?(Array) ? "Bad Request: JSON-RPC batching is not supported" : "Bad Request: the request body is not a valid JSON-RPC message"
  return json_rpc_error_response(400, -32_600, msg)
end
return json_rpc_error_response(400, -32_600, "Bad Request: the request body is not a valid JSON-RPC message", valid_id(parsed)) unless parsed[:jsonrpc] == "2.0"
```
Apply the same "Hash or reject" rule wherever `resolve_session`'s Array return (:232) is checked, or switch it to the same tagged return. Validate `id` (String/Integer) and `method` (String) here too, matching fast-mcp §1.6. Specs: each of `[]`, `[1,2,3]`, `[299,{"x":"1"},["b"]]`, `5`, `"x"`, `null` → 400 JSON-RPC error with `content-type: application/json` and no client-chosen header; a missing `jsonrpc` → 400 `-32600` echoing the id (as the reference does).

### 2.4 Unknown/duplicate session semantics (#5006)
(updated line refs) `json_rpc_error_response` already accepts `id = nil` (:756), but the 404 paths (:309, :343, :373) and the 400 paths (:304, :339, :367) don't pass it. Pass the parsed `id` on POST. A second GET stream for a session that already has one → **409** (check `register_stream` / the session `:streams`; cap GET streams at 1 per session and document it). Session cap `MAX_SESSIONS = ENV.fetch("GRAPH_MEM_MCP_MAX_SESSIONS", 256)` → 503 `-32000 "Too many sessions"` after a reaper pass; keep only clientInfo name/version and the negotiated version on the session (GHSA-84m7 lesson).

### 2.5 Targeted notifications (G6)
(unchanged) `send_message` (:133) never broadcasts `notifications/resources/updated`. Implement `send_message_to(session_id, message)` (the fast-mcp 1.8.0 interface) through `broadcast_to_session_streams`. Only `notifications/*/list_changed` and `notifications/message` may still go to `broadcast_to_streamable_sessions` (:567). `close_session` and the reaper call `@server.remove_subscriber(session_id)` on each of the three profile servers.

### 2.6 Search query cap (G8): [Devin-simple] → done as **M-D1** (§D below); PR-2 only checks it's merged
(updated line refs) `app/tools/search_tool.rb:34` → `optional(:query).maybe(:string, max_size?: 2048)` via `SearchQueryLimits::MAX_QUERY_LENGTH = 2048` (new `app/tools/concerns/search_query_limits.rb`), plus an explicit guard next to the blank check at **:72**: `raise FastMcp::Tool::InvalidArgumentsError, "Query is too long (max 2048 characters)." if query.length > MAX_QUERY_LENGTH`. Apply to `search_entities_tool.rb:26`, `search_subgraph_tool.rb:36`, `get_entities_tool.rb:31`, `get_entity_tool.rb:32`, `rank_observations_tool.rb:28`. Assert `"maxLength": 2048` in each emitted input schema.

### 2.7 Race-safe writes (G9), following Steve's rule: block or queue, never crash or race
(updated line refs) `app/services/graph_write_service.rb`:
1. Move the duplicate preflight inside the lock **in both paths**: batch `#call` (`duplicate = duplicate_response` :73 → inside `with_membership_lock` :80, before `transaction` :81) and the single-operation path (:137 → inside :141, before :142). Confirm the lock's scope; if it's per project, add `GraphWriteLock.with_lock(names)` with sorted per-name `GET_LOCK("graph_mem:<db>:write:<sha1(normalized_name)>", timeout)`. Keep `find_similar_entity` outside the transaction but inside the lock. If the lock is busy → the existing "retry shortly" response, never a 500.
2. Rescue `ActiveRecord::RecordNotUnique` around the transaction (mirror `graph_mutation_batch.rb:73`) → structured `possible_duplicate` (look up by `(project_scope, name)`; key `index_memory_entities_on_scope_name`, structure.sql :173).
3. Observations: re-check exact duplicate content per entity inside the lock. No TEXT unique index in this PR (decision D-4).

### 2.8 `skipped` reporting and delete counts (G11/G12)
(unchanged) Opt-in `on_duplicate: "reject" | "skip"` with `skipped: [{index:, type:, name:, existing_id:, reason:}]` + `next_move`, and `skipped` in `lib/graph_mem/mcp_output_schemas.rb`. This matches v2.0.0 Memory's `create_entities` (the description says existing names are skipped; `outputSchema.skipped` optional, `src/memory/index.ts` `create_entities` registration). Delete counts come from actual deleted rows (`GraphDeleteService` :64, :94-96, `destroy!` :143/:182) + `observations_deleted`.

### 2.9 CORS allowlist (G20)
(updated) `SSE_HEADERS` (:40-50): drop `Access-Control-Allow-Origin` from the constant and set it per response from `validate_origin` (:696) for allowed origins, plus `Vary: Origin`. Add `MCP-Protocol-Version` to `Access-Control-Allow-Headers` (:47) and to `Access-Control-Expose-Headers` (:48). OPTIONS for a disallowed origin → 403 (verify).

### 2.10 Description limits: [Devin-simple] → **M-D2**
(unchanged) `spec/tools/tool_description_length_spec.rb`: every registered tool `description.length <= 2048`, and the server `instructions` ≤ 2,048 (decision D-7).

### 2.11 Docs (G22, G21): the line-ref fixes are [Devin-simple] → **M-D3** (after PR-2 merges, since they describe 1.53.0 behaviour); PR-2 itself writes only the new behaviour docs (body/session limits, header check, stdio logging)
README.md:36-38, :67, :335; docs/development.md:75, :87, :208 (curl example → `"protocolVersion":"2025-11-25"`), :304 (spec link → 2025-11-25); docs/troubleshooting.md:23-24: fast-mcp v1.8.0, "Streamable HTTP negotiates 2024-11-05 … 2025-11-25; 2026-07-28 clients fall back automatically via the `server/discover` probe; `MCP_PROTOCOL_NEGOTIATION=legacy` skips the probe (and the extra stdio process start)". Document the body limit, the session limit and the `MCP-Protocol-Version` behaviour. In docs/mcp_access_control.md: launch stdio with a fixed absolute path to `bin/mcp_stdio_runner.rb` and no user-supplied args.

### 2.12 Specs (graph_mem)
```ruby
# spec/lib/graph_mem/mcp_streamable_http_transport_hardening_spec.rb
it "returns 413 for an oversized POST and creates no session" do
  env = Rack::MockRequest.env_for("/mcp", method: "POST",
        "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream",
        input: { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", pad: "x" * 5_000_000 } }.to_json)
  status, _h, _body = transport.call(env)
  expect(status).to eq(413)
  expect(transport.instance_variable_get(:@sessions)).to be_empty
end
{ "2026-07-28" => "2025-11-25", "2025-11-25" => "2025-11-25", "2025-06-18" => "2025-06-18",
  "2025-03-26" => "2025-03-26", "2024-11-05" => "2024-11-05", "9" => "2025-11-25" }.each do |asked, answered|
  it("initialize asking #{asked} negotiates #{answered}")
end
it("in-session MCP-Protocol-Version absent or any supported value → served")
it("in-session MCP-Protocol-Version 1999-01-01 or 2026-07-28 → 400 -32000 listing supported versions")
it("unknown session + bad header → 404 (session check first)")
it("session-less server/discover with a 2026-07-28 envelope + header → 4xx JSON-RPC error with the id, no session created")
it("array / primitive / null bodies → 400 -32600, never a client-chosen status or header")   # §2.3a regression
it("404 for an unknown Mcp-Session-Id carries the JSON-RPC id")
it("409 on a second GET stream for the same session")
it("503 once MAX_SESSIONS is reached")
it("sends notifications/resources/updated only to the subscribed session")
it("close_session removes the session's subscriptions")
it("reflects an allowed Origin, never '*'")

# spec/bin/mcp_stdio_runner_stdout_spec.rb (§2.13) — spawn with RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9
it "writes only JSON-RPC 2.0 lines to stdout across initialize, tools/list and tools/call get_version"

# spec/tools/search_tool_spec.rb   (added by M-D1; PR-2 only checks they're present and green)
it("rejects queries longer than 2048 characters"); it("accepts exactly 2048"); it("advertises maxLength 2048")

# spec/services/graph_write_service_concurrency_spec.rb  (use_transactional_tests = false; clean up rows after)
it "two concurrent creates of the same name yield one entity and one structured duplicate, no exception" do
  results = 2.times.map { Thread.new { ActiveRecord::Base.connection_pool.with_connection {
    GraphWriteService.new(operations: [{ type: "create_entity", name: "SynthWidget", entity_type: "Component" }],
                          logger: Logger.new(nil)).call } } }.map(&:value)
  expect(MemoryEntity.where(name: "SynthWidget").count).to eq(1)
  expect(results.map { _1[:status] }).to contain_exactly("success", "possible_duplicate")
end
it("same, through the single-operation path")   # :137 preflight
it("RecordNotUnique inside the transaction becomes a possible_duplicate response")
it("busy write lock returns the retry-shortly response")
it("on_duplicate: skip lists stored and in-batch duplicates under skipped and creates the rest")
# spec/services/graph_delete_service_spec.rb
it("reported counts equal the COUNT(*) delta for entities, observations, relations")
```
Fixtures are synthetic names only (`SynthWidget`, `Alpha Service`). Mutation-check the race specs (moving the preflight back outside the lock must turn them red; use a `Queue` barrier) and the §2.3a spec (restoring `return parsed if parsed.is_a?(Array)` must turn it red).

### 2.13 Clean stdout for the stdio runner (new, high for non-TS clients)
- **Cause:** `config/initializers/fast_mcp.rb:24-25` `Logger.new(STDOUT)` at DEBUG, built for the HTTP server, also runs when `bin/mcp_stdio_runner.rb` loads `config/environment` (:7-11). Registering tools on it prints 48 lines (and `[McpAccessPolicy] …` at :61). In production `config/environments/production.rb:38` also points `Rails.logger` at STDOUT.
- **Fix:** the runner sets `ENV["GRAPH_MEM_MCP_STDIO"] = "1"` *before* requiring the environment. The initializer uses `Logger.new($stderr)` (or `Rails.logger`) when that's set, and the runner reassigns `Rails.logger = ActiveSupport::Logger.new($stderr)` (and `ActiveRecord::Base.logger`) right after boot. Belt and braces: fast-mcp's `StdioTransport` writes to the `$stdout` global (`lib/mcp/transports/stdio_transport.rb:42-43`) and reads `$stdin` (:21), so PR-1 adds `input:` / `output:` options (defaulting to `$stdin` / `$stdout`). As its first action the runner then does `mcp_out = STDOUT.dup; STDOUT.reopen(STDERR); $stdout = $stderr` and passes `output: mcp_out`. After that, a stray `puts` or `Logger.new(STDOUT)` anywhere in Rails can't corrupt the stream.
- **Evidence it matters:** the Ruby SDK 1.8.0 client fails to connect in both modes (§0). The TS client tolerates it, so Claude Code works today, but any Ruby/Python/Go client that is strict about stdout won't.
- **Also:** TS clients in `auto` mode start the runner twice per connect (probe sibling, then the real process), so boot cost is paid twice (2.8 s vs 1.4 s measured). Check that boot has no side effects that matter when killed with SIGTERM within ~1 s (no job enqueueing, no migrations, no lock left held), and document `MCP_PROTOCOL_NEGOTIATION=legacy` as the way to skip the probe.

### 2.14 Acceptance criteria
- Full suite green **run on its own** (`RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`, test DB truncated before and after), plus rubocop and brakeman green, CI green.
- The test DB is left with 0 rows.
- Manual: `/workspace/triage/mcp-compat/http_probe.sh http://127.0.0.1:<port>/mcp` matches the "graph_mem after PR-2" column of §3.0 (oversized → 413; `initialize 2026-07-28` → `2025-11-25`; bad header → 400; arrays → 400; unknown session → 404 with id).
- `drive.rb` against `bin/mcp_stdio_runner.rb`: every stdout line is JSON-RPC 2.0. The Ruby SDK 1.8.0 client (`rsdk_client.rb`) connects in `auto` and `legacy`, and the TS client 2.3.1 (`tsclient/tsclient.mjs`) connects in both modes over stdio and HTTP.
- No behaviour change for existing callers of `graph_write` unless they pass `on_duplicate: "skip"`.

### 2.15 Risks and rollback
- The per-name GET_LOCK ordering could deadlock against `ProjectMembership`'s lock. Rule: membership lock first, then name locks in sorted order, all before any transaction; add a spec.
- The session cap / 409 could reject legitimate reconnecting clients: the reaper runs before 503, and the limits are configurable.
- The header check could reject a client that sends a version it negotiated elsewhere: accept any *supported* value (as the reference does) and only reject unknown ones.
- Rollback: revert the PR; the Gemfile goes back to `b10243c`. No migrations.

### 2.16 CHANGELOG
```
## [1.53.0] - 2026-10-xx
<!-- UI-0 (Security) and PR-0 (Added/Changed/Security) entries from [Unreleased] stay above or merged into these headings -->
### Changed
- fast-mcp bumped to steveoro v1.8.0 (handshake negotiation up to 2025-11-25, strict JSON-RPC, per-session subscriptions).
- Streamable HTTP and stdio negotiate 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25; any other requested version gets 2025-11-25. 2026-07-28 clients fall back via the server/discover probe.
- MCP-Protocol-Version is validated on in-session requests (400 for unsupported values).
- CORS reflects allowed origins only (Vary: Origin); MCP-Protocol-Version allowed/exposed.
### Added
- 4 MiB request body cap (413), session cap (503), 409 on duplicate GET stream, JSON-RPC id on 400/404.
- search/query cap of 2,048 chars (maxLength in schema) on every free-text query argument.
- graph_write `on_duplicate: "skip"` with a `skipped` list.
### Fixed
- A JSON-array POST body was returned as the raw HTTP response (status/headers/body chosen by the caller); non-object bodies now get 400 -32600.
- The stdio runner wrote Rails/FastMcp log lines to stdout, breaking strict stdio clients (e.g. the Ruby MCP SDK); logs now go to stderr.
- Duplicate preflight now runs under the write lock (batch and single-op paths); concurrent duplicates return a structured response.
- Delete counts reflect rows actually deleted.
- resources/updated notifications go only to subscribed sessions.
```

---
## PR-3 [Claude] + [Devin-simple] docs — graph_mem 1.53.1: protocol interop tests against the v2.0.0 reference servers

- **Branch:** `claude/pr-3-mcp-interop-v2-reference`
- **Title:** `Compat: replay synthetic MCP handshakes against graph_mem and the v2.0.0 reference servers`
- **Version:** 1.53.1 (tests, scripts and docs only). Implementing 2026-07-28 is the separate PR-4 (confirmed, right after this one).
- **Base:** after PR-2 merges (the "after PR-2" expectations below assume PR-1 and PR-2).

### 3.0 Baseline already recorded (2026-10-20, synthetic fixtures)
Scripts and raw results live in `/workspace/triage/mcp-compat/` (copy into `script/mcp_compat/` and `spec/fixtures/mcp/handshakes/` in this PR). Reference servers: **Memory 2.0.0** (stdio only, `node src/memory/dist/index.js`, empty `MEMORY_FILE_PATH`) and **Everything 2.0.0** (Streamable HTTP, `PORT=… node src/everything/dist/index.js streamableHttp`), both built from tag `v2.0.0` on Node 24 (their floor is Node 24, `src/memory/package.json:16`).

**stdio** (`drive.rb` + `scenarios.json`; one fresh process per scenario)

| Scenario | fast-mcp 1.7.1 (= graph_mem stdio today) | Memory 2.0.0 | graph_mem / fast-mcp after PR-1/2 |
|---|---|---|---|
| `initialize` 2025-03-26 / 2025-11-25 | 2024-11-05 / 2024-11-05 | 2025-03-26 / 2025-11-25 | echo |
| `initialize` 2026-07-28 / `"9"` | 2024-11-05 | 2025-11-25 | 2025-11-25 |
| `server/discover` + envelope | `-32601` (id echoed) | result `supportedVersions:["2026-07-28"]`, `resultType`, `ttlMs:0`, `cacheScope:"private"`, `_meta.serverInfo` | `-32601` (PR-4: like Memory) |
| discover claiming 2027-01-01 | `-32601` | `-32022`, `data:{supported:["2026-07-28"],requested}` | `-32601` |
| envelope missing `clientCapabilities` | `-32601` | `-32602` `data.envelope:{key,problem:"missing"}` | `-32601` |
| `tools/list` + envelope, no initialize | served, no `resultType` | served with `resultType`/`ttlMs`/`cacheScope` | served (PR-4: stamped) |
| discover → `initialize 2025-11-25` → `tools/list` | ok (2024-11-05) | ok (2025-11-25) | ok (2025-11-25) |
| parse error / batch / missing `jsonrpc` / primitive | `-32600` / `-32600 "Internal error: no implicit conversion…"` / `-32600` / same leak | no reply (all four) | `-32700` / `-32600` batching / `-32600` / `-32600` |
| unknown notification | **reply** `-32601`, `id:null` | no reply | no reply |
| non-JSON stdout lines before the first frame | 0 (fast-mcp) / **48 (graph_mem runner)** | 0 | 0 |

**Streamable HTTP** (`http_probe.sh`)

| Probe | graph_mem 1.52.1 | Everything 2.0.0 | graph_mem after PR-2 |
|---|---|---|---|
| discover + envelope + `MCP-Protocol-Version: 2026-07-28` | 400 `-32600` missing session, `id:null`, no session | 200 discover result | 4xx JSON-RPC error **with id**, no session |
| modern header, no envelope / header≠envelope / future revision | 400 `-32600` (all) | 400 `-32602` / 400 `-32020` / 400 `-32022` | 400 `-32600` + id (PR-4: as reference) |
| `initialize` + modern header | 200, session, 2025-03-26 | 400 `-32020` | 200, 2025-11-25 (deliberately lenient) |
| `initialize` 2026-07-28 / 2025-11-25 / 2025-06-18 / 2024-11-05 / `"9"` | 2025-03-26 / 2025-03-26 / 2025-03-26 / 2024-11-05 / 2025-03-26 | 2025-11-25 / 2025-11-25 / 2025-06-18 / 2024-11-05 / 2025-11-25 | as reference |
| in session: header absent / `1999-01-01` / `2026-07-28` | 200 / **200** / **200** | 200 / 400 `-32000` / 400 `-32000` | 200 / 400 `-32000` / 400 `-32000` |
| unknown session | 404 `-32001`, `id:null` | 404 `-32001`, id echoed | 404, id echoed |
| session-less non-initialize | 400 `-32600` | 400 `-32000 "Server not initialized"` | 400 + id |
| parse error | 400 `-32700` | 400 `-32700` | 400 `-32700` |
| JSON array body | **500 / raw Rack response** (`[299,{…},[…]]` → HTTP 299 + injected header) | 400 | 400 `-32600` batching |
| missing `jsonrpc` | 400 `-32600` (missing session) | 400 `-32600` id echoed | 400 `-32600` id echoed |

**Real SDK clients** (`tsclient/tsclient.mjs` = `@modelcontextprotocol/client@2.3.1`; `rsdk_client.rb` = Ruby SDK 1.8.0)

| Client / mode | graph_mem HTTP | graph_mem stdio | fast-mcp synth stdio | Memory 2.0.0 stdio | Everything 2.0.0 HTTP |
|---|---|---|---|---|---|
| TS `auto` | legacy 2025-03-26 ✓ | legacy 2024-11-05 ✓ (2.8 s; sibling probe) | legacy ✓ | modern 2026-07-28 ✓ | modern ✓ |
| TS `legacy` | 2025-03-26 ✓ | 2024-11-05 ✓ (1.4 s) | ✓ | 2025-11-25 ✓ | 2025-11-25 ✓ |
| Ruby `auto` / `legacy` | (not run) | **✗ / ✗ "Failed to parse server response"** | ✓ / ✓ (2024-11-05) | ✓ modern / ✓ 2025-11-25 | (not run) |

### 3.1 Work
1. [Claude] **Handshake fixtures** (`spec/fixtures/mcp/handshakes/*.json`): convert `scenarios.json` plus the `http_probe.sh` cases into data files. Each case gives the transport (stdio/http), the messages and headers, and the expected outcome per target: `graph_mem`, `reference` (Memory for stdio, Everything for HTTP), and an optional `divergence_reason`. Author them from the spec and the v2.0.0 code (§0b); **never** capture them from private systems.
2. [Claude] **In-suite spec** `spec/requests/mcp_protocol_compat_spec.rb`: replays every HTTP case through the Rack transport and every stdio case through `bin/mcp_stdio_runner.rb` in a subprocess (`RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`), and asserts graph_mem's column. It always runs and doesn't need Node.
3. [Claude] **Reference comparison** `script/mcp_compat/compare.rb` (opt-in, needs Node ≥24 and the v2.0.0 tag checked out, or `npx -y @modelcontextprotocol/server-memory@2.0.0` / `server-everything@2.0.0`): runs the same fixtures against graph_mem *and* the reference servers and prints a diff table. Each row is "same", "documented divergence", or "**unexpected**" (exit 1 on unexpected). Allowed divergences: error-code choice where both are fallback-safe (`-32601`/`-32600` vs `-32022`/`-32602` before PR-4), replying to malformed stdio lines (graph_mem replies, the reference is silent), and the lenient `initialize` + modern header. Compare by **shape and code**, not by message text.
4. [Claude] **Client matrix** `script/mcp_compat/clients.sh`: TS client 2.3.1 (`auto`, `legacy`) and Ruby SDK ≥1.8.0 (`auto`, `legacy`) against graph_mem stdio and HTTP. All eight must connect and list tools. Record the timings: the stdio `auto` row shows the sibling-probe cost.
5. [Steve, manual] **Claude Code check**: Steve runs it himself (Claude Code Max plan) with the ready-made prompt `prompts/claude-mcp-client-check.md` (next to these plans): Claude Code as the MCP client against a local graph_mem over stdio and HTTP (default + maintenance profiles), with and without `MCP_PROTOCOL_NEGOTIATION=legacy`, plus the negative checks (bad token → 401, clean stdio stdout, scan outside the allowed roots refused). Steve pastes the filled results table back; Claude copies it into `docs/protocol_compat.md` next to the SDK client matrix. Claude doesn't wait on it to open PR-3: the PR description marks step 5 "pending Steve's run".
6. [Devin-simple] `docs/protocol_compat.md`: the §0b summary (how 2026-07-28 clients fall back), the matrices, the known divergences, and the PR-4 decision point.

### 3.2 Acceptance criteria
The in-suite spec is green and pins graph_mem's behaviour. `compare.rb` shows no "unexpected" rows. The client matrix is all green. `docs/protocol_compat.md` says which clients and versions work and what the workaround is.

### 3.3 Risks
The fixtures could drift from real clients. Mitigation: the client matrix uses the official open-source SDK clients (TS 2.3.1, Ruby 1.8.0), not Claude Code internals. Pin the reference by tag (`v2.0.0` / npm `2.0.0`) and bump it on purpose.

---

## PR-4 [Claude] (confirmed Oct 21, right after PR-3; decision D-1) — dual-era: serve 2026-07-28 next to the handshake

- **Repos / versions:** two PRs. **PR-4a** = fast-mcp **1.9.0** (era plumbing; branch `claude/pr-4a-dual-era`; Steve tags `v1.9.0`). **PR-4b** = graph_mem **1.54.0** (branch `claude/pr-4b-dual-era`; bumps the gem to 1.9.0 and adds the stateless modern path). As with PR-1, PR-4a is validated against graph_mem via an uncommitted `bundle config local.fast-mcp` override before it's tagged.
- **Model:** v2.0.0 Memory (stdio) and Everything (HTTP), §0b. One factory serves both eras. The era is picked by the **first message** on stdio and **per request** on HTTP (an envelope claim → stateless modern path; `Mcp-Session-Id`/GET/DELETE/claim-less → today's sessionful path, unchanged).
- **fast-mcp:**
  - `MODERN_PROTOCOL_VERSIONS = %w[2026-07-28]`.
  - Envelope parsing/validation (required protocolVersion + clientCapabilities; `-32602` with `data.envelope`; `-32022` with `{supported, requested}`).
  - `server/discover` handler (`supportedVersions` modern only, capabilities, instructions, `_meta` serverInfo).
  - A result encoder that stamps `resultType: "complete"`, plus `ttlMs`/`cacheScope` on the cacheable list/read results.
  - `ping` → `-32601` on modern. `resources/subscribe` → `-32601` on modern.
  - `subscriptions/listen` (or advertise `resources.subscribe: false` / `listChanged: false` on modern at first: allowed, and graph_mem has no live updaters today, §0).
  - Stdio era pinning (probe phase, then discard on a legacy `initialize`).
- **graph_mem:**
  - Route session-less POSTs that carry a valid claim (and not `initialize`) to a stateless per-request dispatch.
  - Validate `MCP-Protocol-Version` == envelope, and `Mcp-Method` (+ `Mcp-Name`) == body → 400 `-32020`.
  - No session creation on that path; context stays keyed by `X-MCP-Client` (already session-independent).
  - Keep `/mcp/sse` legacy only. HTTP+SSE is Deprecated in 2026-07-28 (SEP-2596).
- **Not needed:** MRTR/`input_required`, tasks, sampling, roots, elicitation, logging (none are used).
- **Acceptance:** PR-3's `compare.rb` shows "same" for every modern row. The TS client `auto` → era modern for stdio and HTTP; the Ruby SDK `auto` → modern; both `legacy` modes still work.
- **Cost estimate:** larger than PR-1 + PR-2 together, mostly the HTTP routing, the result encoder and the specs. The benefit is mainly skipping the probe round-trip (on stdio, a second Rails boot); everything already works through the fallback.

---
## Advisory-theme checklist (put this in each PR description)
| Theme | Status after this series |
|---|---|
| Unbounded body (GHSA-fmmv, Java/Kotlin/PHP) | PR-1 (Rack + stdio), PR-2 (Streamable HTTP) |
| Sessions never reclaimed (GHSA-84m7) | graph_mem reaper already done; PR-1 adds legacy SSE idle reaping; PR-2 adds a session cap and stores minimal init state |
| Tasks/state not bound to session (GHSA-22jm) | PR-1/PR-2 bind subscriptions and resource notifications to a session; no task API in either repo (no `tasks/` methods in server.rb) |
| Cross-origin redirect credential leak (GHSA-6prh/5h93) | N/A: neither repo is an HTTP MCP client. Outbound HTTP (`embedding_service.rb`, `summary_generation_client.rb`) goes to operator-configured URLs; Devin confirms Net::HTTP doesn't follow redirects with auth headers and adds a comment |
| OAuth issuer/audience (6qxp/qx49/rvq5/w4fh) | N/A: static bearer in `lib/graph_mem/mcp_access_policy.rb`. If OAuth is ever added (PR-1 §1.7), copy Ruby SDK 1.8.0's required iss+aud checks |
| `$ref` fetching (rwrf) | N/A: no client-side schema validation of remote refs |
| stdio command injection | Docs only (PR-2 §2.11) |
| **Filesystem boundary / path traversal in tool arguments** (new) | PR-0: one `ScanRootPolicy` for UI, `/api/v1/scan`, MCP `scan_project` and job start; read-only home mount; runtime subfolder filter; hard denylist (dotfolders, secret files, even via explicit globs); no `..`/absolute `file_globs`; symlink escapes skipped |
| **Unauthenticated HTTP API next to the MCP endpoint** (new) | UI-0 (in 1.53.0): `/api/v1` requires an operator session or the MCP bearer token + IP policy; no compatibility flag |
| **Malformed JSON-RPC / response injection** (new) | PR-1 §1.6 (fast-mcp inbound strictness), PR-2 §2.3a (array-body reflection), PR-2 §2.13 (clean stdio stdout) |

---

## D. Devin-simple tasks (step lists; no design decisions; `## [Unreleased]` CHANGELOG line; no version bump)
Rules for every item: branch `devin/m-d<n>-<slug>` off `main`; touch only the listed files; run the listed spec, then the full suite **alone** with `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9` and the test DB truncated before and after (UI plan §0.1); synthetic fixtures only; stop and ask if a step doesn't match the code.

- **[Devin-simple] M-D1. Search query cap (PR-2 §2.6, G8).** May merge before PR-2.
  1. Create `app/tools/concerns/search_query_limits.rb`: `module SearchQueryLimits; MAX_QUERY_LENGTH = 2048; def self.check!(query) … raise FastMcp::Tool::InvalidArgumentsError, "Query is too long (max 2048 characters)." if query.to_s.length > MAX_QUERY_LENGTH; end; end`.
  2. Add `max_size?: SearchQueryLimits::MAX_QUERY_LENGTH` to the `:query` declaration in `app/tools/search_tool.rb:34` (`maybe(:string, max_size?: …)`), `search_entities_tool.rb:26`, `search_subgraph_tool.rb:36` (`filled(:string, max_size?: …)`), `get_entities_tool.rb:31`, `get_entity_tool.rb:32` and `rank_observations_tool.rb:28`.
  3. In each tool's `call`, call `SearchQueryLimits.check!(query)` next to its existing blank check (`search_tool.rb:72` for the main tool).
  4. Specs: in `spec/tools/search_tool_spec.rb` add "rejects 2049 chars", "accepts exactly 2048", "advertises maxLength 2048 in its input schema". Add one schema assertion per other tool in a new `spec/tools/query_length_limits_spec.rb` (iterate the six classes and check `input_schema_to_json` → `properties.query.maxLength == 2048`).
  5. CHANGELOG `[Unreleased]` › Added: "2,048-char cap (maxLength in schema) on every free-text `query` argument."
- **[Devin-simple] M-D2. Tool description length spec (PR-2 §2.10).** May merge before PR-2.
  1. New `spec/tools/tool_description_length_spec.rb`: for every class registered in `McpToolRegistry` (canonical and aliases), `expect(klass.description.to_s.length).to be <= 2048`; and the server `instructions` string from `config/initializers/fast_mcp.rb` ≤ 2048.
  2. If any description is longer, **don't shorten it yourself**: mark the example `pending` with the tool name and report it in the PR (wording is a design decision).
  3. CHANGELOG `[Unreleased]` › Added: "Spec: tool descriptions and server instructions stay ≤ 2,048 chars."
- **[Devin-simple] M-D3. Docs drift (PR-2 §2.11, G21/G22).** **After** PR-2 merges.
  1. README.md:36-38, :67, :335; docs/development.md:75, :87, :208 (the curl example becomes `"protocolVersion":"2025-11-25"`), :304 (spec link → 2025-11-25); docs/troubleshooting.md:23-24. Replace "fast-mcp v1.7.1" with "v1.8.0" and the protocol sentences with: "Streamable HTTP and stdio negotiate 2024-11-05 … 2025-11-25; 2026-07-28 clients fall back automatically via the `server/discover` probe; `MCP_PROTOCOL_NEGOTIATION=legacy` skips the probe (and the extra stdio process start)."
  2. Add "(deprecated in MCP 2026-07-28; kept for older clients)" after each `/mcp/sse` mention in README and `docs/mcp_tools.md` (decision D-3).
  3. `docs/mcp_access_control.md`: add "Launch stdio with a fixed absolute path to `bin/mcp_stdio_runner.rb` and no user-supplied arguments."
  4. Re-grep (`rg -n "1\.7\.1|2025-03-26" README.md docs`) and list any remaining hits in the PR rather than guessing.
- **PR-3 step 6** (`docs/protocol_compat.md`) is also Devin-simple, once Claude's PR-3 specs and matrices exist.

---

## E. Remaining questions for Steve

None. R1 is decided (D-1: PR-4 after PR-3 as fast-mcp 1.9.0 → graph_mem 1.54.0), and the PR-3 step 5 check is Steve's own run (`prompts/claude-mcp-client-check.md`). The only optional choice left: if you want the UI series before PR-4, say so and the version numbers swap (§C).
