# MCP SDK 1.9.0 → graph_mem 1.72.0 (gem bump, non-object `_meta`, tool titles, D-7 query cap)

**✅ DONE:** shipped in #156 as **1.72.0** (steps A1–A6, T, Q, C and RA; compat verification recorded in `docs/protocol_compat.md`).

**Written 2026-11-05 (Europe/Rome)** for Claude, from the 1.71.0 code (`94ead39`, #155 merged, tagged `v1.71.0`).
File:line references were checked against `94ead39`. If a line has moved, find the code by the quoted text. If the code
no longer matches the description, **stop and ask Steve** instead of improvising.
Upstream: `modelcontextprotocol/ruby-sdk` v1.8.2..v1.9.0 (tag commit `2cd02af`, #653; 48 files, +5693/−74;
`mcp.gemspec` unchanged).

**A pre-check was run** on a throwaway checkout of an earlier `main` (1.68.0) with only the gem bump applied (Gemfile + lock),
on MariaDB 11.8.6 and Ruby 3.4.12:
- full `bundle exec rspec`: 3657 examples, 0 failures, 1 pending (shellcheck not installed);
- `compare.rb`: 47 cases (17 stdio, 30 HTTP), 0 failed expectations, 0 unexpected differences. The `ruby_sdk` column runs on `mcp` 1.9.0 and matches graph_mem everywhere;
- `clients.sh` with `RSDK_VERSIONS="1.8.1 1.8.2 1.9.0"`: 16 of 16 OK.

That run used Node 20, not 24, and predates titles and D-7, so step C re-runs everything on Node 24.

Context: `docs/plans/done/mcp-update-plan.md` (DONE), `docs/plans/done/mcp-sdk-1.8.2-plan.md` (shipped as 1.58.1–1.58.3),
`docs/plans/done/ui-dashboard-plan.md` §6.D (**D-7**), `docs/guides/migrating-fast-mcp-to-mcp-gem.md` (**D14** exact pin, one PR
per upgrade), `docs/protocol_compat.md`, `script/mcp_compat/README.md`. This plan is self-contained.

**Version.** Titles and the D-7 `maxLength` change what `tools/list` advertises, so this is a **minor** release: **1.72.0**.
(The patch-release argument for a bare gem bump no longer applies.)

**Expected MCP surface change, pre-approved by Steve.** Every tool gains a `title`. `search`, `get_entities`,
`rank_observations` and `summarize` gain `maxLength: 2048` on `query` and refuse a longer query. Non-object request `_meta`
is refused with −32602 (from the gem). The `tools/list` snapshots are re-recorded for these changes only. Tool names,
descriptions, other schema fields, annotations and counts stay as they are: `/mcp` **12** tools (≤ 12 is a hard limit),
readonly 9, maintenance 22.

## Brief

| | |
|---|---|
| **Branch / PR** | **One PR**, `claude/mcp-1.9.0`, off `main`, title `mcp 1.9.0, tool titles, query cap (1.72.0)`. Open it as a **draft** after A1; mark it ready only after RA. Steve merges and tags. Never merge, tag, push tags or run `rake release`. |
| **Commits** | **A1** gem bump, **A2** non-object `_meta` specs, **A3** compat cases, **T** tool titles, **Q** D-7 query cap, **A4** harness versions, **C** compat verification, **A5** version text + re-recorded results, **A6** mark the 1.8.2 plan DONE, **RA** release. Review fixes go in new commits. No force-push after review starts. |
| **Scope** | The gem bump, `_meta` specs and compat cases, tool titles (T) and the D-7 query cap (Q). No other tool, prompt, resource or `/api/v1` changes. No Skills (SEP-2640), no `icons`. Snapshot changes only from T and Q. |
| **Data** | Synthetic fixtures only (`SynthClient`, `synth-*` names). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `script/mcp_compat/README.md`, `docs/protocol_compat.md`, `docs/plans/done/ui-dashboard-plan.md` §6.D (D-7). |

## Upstream changes (verified at `v1.9.0`)

| PR | Change | For graph_mem |
|---|---|---|
| #651 | A request whose `_meta` is not an object (string, array, number) is refused with **−32602** "Invalid params: _meta must be an object" before any handler runs, on both lifecycles. `null` counts as absent. Call at `lib/mcp/server.rb:802`; `refuse_non_object_meta!` at `:939-953`. | **Wire change.** Checked live on the bumped checkout: legacy `tools/list` on `/mcp` with `_meta: "x"` or `[1]` → HTTP 200, `{"code":-32602,"message":"Invalid params: _meta must be an object"}`, id echoed; `_meta: null` → normal result. |
| #650 | A non-object `_meta` no longer raises `TypeError` in `validate_modern_headers`, `call_tool` (`server.rb:1427`) or `build_server_context`. A 2026-07-28 HTTP request gets 400 instead of 500. | Covered by A2. |
| #641 | Client: `MCP::Client::Tool` keeps `title`, `icons`, `execution`, `meta`. | Lets the 1.9.0 harness client see the new titles (A4, C). |
| #639 | Streamable HTTP reads `Host`/`Origin`/`Accept`/`Content-Type` as bytes (403/406/415 instead of raising). | Low; no spec sends invalid header bytes. |
| #649 | A root `$dynamicRef` counts as a root schema shape. | None; no root reference keywords in graph_mem's output schemas. |
| #637 | `StreamableHTTPTransport#close` skips the reaper join on the reaper thread. | Defensive only. |
| #635/#646 | Skills extension (opt-in, `skills: nil` by default). | Not used (see Later). The #629 trigger (invalid-UTF-8 tool name → −32603 with the id) still works on 1.9.0. |
| #636 | `VERSIONING.md`: breaking changes only in majors, "with the exceptions described below". | Why D14's exact pin stays. |

The gem accepts a tool `title` and only rejects it when the negotiated `protocol_version` is 2025-03-26 or older.
Check how 1.9.0 handles a titled tool for a 2025-03-26 client before T (omit vs. refuse); see Stop and ask.

## What the code looks like today (verified at `94ead39`)

- `lib/graph_mem/version.rb`: `VERSION = "1.71.0"`. `skills/graph-mem-mcp-toolset/SKILL.md:18` holds `graph-mem-version`.
- `Gemfile:35-36`: comment "Exact pin: one PR per upgrade (D14)", `gem "mcp", "1.8.2"`. `Gemfile.lock:228` `mcp (1.8.2)`, plus the `mcp (= 1.8.2)` DEPENDENCIES line. `json` is 3.1.0.
- `app/tools/`: 22 tool classes plus `application_tool.rb` and `concerns/`.
- `lib/graph_mem/official_mcp/tool_wrapper.rb:27-45` (`ToolWrapper.build`): sets `tool_name`, `description`, `input_schema` (`LenientInputSchema`, `:15-18`), `output_schema`, `annotations`. No `title`.
- Input schemas come from the vendored `arguments` DSL (`lib/graph_mem/mcp_schema/`); `metadata_processor.rb:18` builds them from dry-schema's `json_schema` (dry-schema 1.16.0), which maps `filled` to `minLength: 1`.
- `query` arguments:
  - `app/tools/search_tool.rb:38` `optional(:query).maybe(:string)`; `call` at `:56`.
  - `app/tools/get_entities_tool.rb:31` `optional(:query).filled(:string)`; `call` at `:40-41`.
  - `app/tools/rank_observations_tool.rb:28` `optional(:query).filled(:string)`; `call` at `:31`.
  - `app/tools/summarize_tool.rb:29` `required(:query).filled(:string)`; `call` at `:44`.
- `GraphMem::InvalidArgumentsError` exists (raised in `app/services/subgraph_search_service.rb:88`).
- Request `_meta` is never read. `lib/graph_mem/official_mcp/request_context.rb` reads only `server_context[:auth_info]` claims. Object `_meta` is written only into tools/call results in `tool_wrapper.rb`.
- Snapshots: `spec/fixtures/mcp/snapshots/{default,readonly,maintenance}.json`, checked by `spec/mcp/tools_list_snapshot_spec.rb`.
- `spec/requests/mcp_official_spec.rb:439`: the #629 block (comment names 1.8.2).
- Harness: `script/mcp_compat/rsdk_server.rb:4,15`, `rsdk_client.rb:4,11,16` (default 1.8.2; prints only the tool count), `clients.sh:2,12,22` (default `"1.8.1 1.8.2"`), `script/mcp_compat/README.md:19,20,23,33,81,83`.
- Version text: `README.md:71`; `AGENTS.md:44`; `docs/architecture.md:59,68,74`; `docs/development.md:81`; `docs/protocol_compat.md:5,36-43,67,153,155,157,177,179`.

## PR → 1.72.0

### A1. Gem bump
`gem "mcp", "1.9.0"` (keep the exact pin and the D14 comment), then `bundle lock --update mcp --conservative`.
The lock diff must be exactly the two `mcp` lines. Anything else: stop and ask. Open the draft PR after this commit.

### A2. Non-object `_meta` specs
In `spec/requests/mcp_official_spec.rb`, next to the #629 block, with a short "before 1.9.0" note per case:
- (a) legacy `tools/list` with `params: { _meta: "x" }` on `/mcp` and `/mcp/readonly` → HTTP 200, `error.code == -32602`, id echoed. `_meta: null` → a normal result.
- (b) `tools/call` on a read-only tool with `_meta: [1]` → −32602, and the tool does **not** run (no audit/telemetry row).
- (c) a 2026-07-28 request (with its `MCP-Protocol-Version` header and envelope) with `_meta: "x"` → HTTP 400, −32602. Assert what the gem actually sends.
- One stdio case in `spec/integration/mcp_structured_output_stdio_spec.rb` for (a), on the same subprocess pattern.

Case (a) must fail on 1.8.2 (check it once with the lock reverted, then restore).

### A3. Compat cases: a **documented divergence**
Add a non-object `_meta` case to `stdio.json` and `http.json`. The reference servers (TS SDK 2.3.1) don't answer −32602:
- Everything 2.0.1 (HTTP) returns **HTTP 400 −32700** "Parse error: Invalid JSON-RPC message" with `id: null`;
- Memory 2.0.0 (stdio) logs a transport `ZodError` and **sends no reply**.

Record a `divergence` on both cases, and the same text in `docs/protocol_compat.md`. Check that `compare.rb` can express
"reference sends no reply" for stdio. If it can't, add the stdio case for graph_mem only, and stop and ask before
changing `compare.rb`.

### T. Tool titles
- Add a `title` to every tool class (a class-level DSL on `ApplicationTool` next to `description`, or a constant; follow
  the existing style), and pass it in `ToolWrapper.build` (`title tool_class.title` when present).
- Wording: short, human, Title Case, ≤ 40 characters, no trailing period (e.g. "Search Graph", "Get Entities",
  "Rank Observations", "Summarize Topic"). No routing or "use when" text: that stays in the description.
- Tools only: prompts and resources keep their current fields.
- Spec: every registered tool in every profile has a non-blank `title` ≤ 40 chars; the wrapper advertises it in `tools/list`.
- Re-record the three snapshots. The diff must be `title` lines only (plus Q's `maxLength`, if Q is committed first).
- A client on 2025-03-26 or older must still get a working `tools/list` (spec it). If the gem refuses titled tools for
  such a client instead of omitting the field, stop and ask.

### Q. D-7 query length cap
- `MAX_QUERY_LENGTH = 2_048` (one shared constant, e.g. on `ApplicationTool` or `GraphMem`).
- `maxLength: 2048` on `query` in the four input schemas. Prefer the DSL predicate (`max_size?: MAX_QUERY_LENGTH`) if the
  vendored schema DSL emits `maxLength` for it; otherwise add it where the JSON schema is built. If neither works without
  changing the vendored DSL beyond a few lines, ship the runtime guard only and say so in the PR.
- A runtime guard in each of the four tools that raises `GraphMem::InvalidArgumentsError`
  ("Query is too long (max 2048 characters).") before any query work. Refuse; never truncate.
- `/api/v1` is out of scope: if the REST endpoints reach the same guard through shared code, keep it and spec it;
  don't add a new REST cap.
- Spec per tool: a 2,049-char query returns the tool error envelope and runs no search; a 2,048-char one passes. If the gem
  rejects the argument against the schema first, assert what it actually sends, as long as the tool doesn't run.
- Re-record the snapshots (diff: `maxLength` on those four `query` properties only). Say so in the PR.

### A4. Harness versions
- `RSDK_VERSION` default 1.8.2 → 1.9.0 in `rsdk_server.rb:4,15` and `rsdk_client.rb:4,11,16`.
- `clients.sh:2,12,22` `RSDK_VERSIONS` `"1.8.1 1.8.2"` → `"1.8.2 1.9.0"` (still 12 rows).
- `script/mcp_compat/README.md:19,20,23,33,81,83`: the install line becomes `gem install mcp -v 1.8.2 && gem install mcp -v 1.9.0`.
- `rsdk_client.rb` also prints how many tools carry a `title` (1.9.0 only; guard it for 1.8.2, which drops the field).

### C. Compat verification
On Node 24 and Ruby 3.4.12, against a local server on synthetic data (README "Run" section):
- `ruby script/mcp_compat/compare.rb`: 0 failed expectations, 0 unexpected differences, the new `_meta` cases recorded as
  divergences, and the `ruby_sdk` column (1.9.0) matching graph_mem.
- `script/mcp_compat/clients.sh <url>`: 12 of 12 OK (TS 2.3.1, Ruby SDK 1.8.2 and 1.9.0, × auto/legacy, × stdio/HTTP);
  the 1.9.0 rows report a title on every tool, and `/mcp` lists 12 tools.
- Paste both summaries in the PR. A new failure or unexpected difference: stop and ask.

### A5. Version text and recorded results
- `README.md:71`, `AGENTS.md:44`, `docs/architecture.md:59,68,74` (add a 1.9.0 row: non-object `_meta` → −32602), `docs/development.md:81`.
- `docs/protocol_compat.md:5,36-43` (the 1.8.1 rows drop with the matrix change), `:67,153,155,157,177,179`.
- The #629 comments in `mcp_official_spec.rb`: the trigger is unchanged on 1.9.0.
- Fixture divergence texts that name "Ruby SDK 1.8.2": update to 1.9.0 only if `compare.rb` still labels them correctly.
- Leave `spec/jobs/fact_supersede_job_spec.rb` (sample data "mcp 1.8.2.") and `docs/guides/migrating-fast-mcp-to-mcp-gem.md` as they are.
- Record C's counts in `docs/protocol_compat.md` and the harness README's "Expected results" (now 1.72.0).
- `docs/plans/done/ui-dashboard-plan.md` §6.D: mark D-7 done (this PR).

### A6. Housekeeping
Mark `docs/plans/done/mcp-sdk-1.8.2-plan.md` DONE in its header (shipped as 1.58.1–1.58.3, #130–#132), and this plan DONE in RA.

### RA. Release 1.72.0
- `lib/graph_mem/version.rb` → `1.72.0`; `skills/graph-mem-mcp-toolset/SKILL.md:18` → `"1.72.0"` (the sync spec checks it).
- CHANGELOG `## [1.72.0]`:
  - Added: tool titles in `tools/list`; a 2,048-character cap on `query` for `search`, `get_entities`, `rank_observations` and `summarize` (advertised as `maxLength`).
  - Changed: MCP requests whose `_meta` is not an object are refused with −32602 (mcp 1.9.0).
  - Dependencies: `mcp` 1.8.2 → 1.9.0.
- Mark the PR ready for review.

## Later (not in this PR; needs Steve's go-ahead)

**Skills over MCP (SEP-2640).** The SDK support is opt-in (`skills:` on `MCP::Server.new`). Catches:
- the extension is **Beta**, so breaking changes are allowed;
- neither Claude Code nor Cursor is on the official extension client matrix;
- serving skills changes the advertised capabilities, so the `eq CAPABILITIES` specs and `resources/list` change;
- frontmatter rules are stricter than YAML (no tags, aliases or merge keys, no ambiguous plain scalars, `name` = folder name);
- graph_mem's custom `resources_read_handler` (`server_factory.rb`) would have to delegate `skill://` URIs to `MCP::Skill.read_file`;
- end-to-end checks need MCP Inspector or the Ruby SDK client.

Also later: `icons`, D-8 (tool description length spec) and the "use when" description rewrite.

## Size

About 5 hours: A1 10 min, A2 1 h, A3 45 min, T 1 h, Q 1 h, A4 20 min, C 30 min, A5 30 min, A6 + RA 15 min.
Expected diff well under 1,500 lines (snapshots included).

## Decisions (defaults; Steve may change any)

1. **Exact pin** `"1.9.0"` (D14).
2. **Minor release 1.72.0** (titles and `maxLength` change the advertised surface). If another release lands first, take the next minor.
3. **Client matrix becomes 1.8.2 + 1.9.0** (12 rows); keeping 1.8.1 (16 rows) is the alternative.
4. **Non-object `_meta` is a documented divergence** from the reference servers (A3).
5. **Over-long queries are refused**, not truncated, with `GraphMem::InvalidArgumentsError`.
6. **No new REST cap**; only what shared code already gives.
7. **Titles on tools only**, short Title Case; not on prompts or resources; no `annotations.title`.

## Acceptance criteria

- The lock diff is `mcp` only. The full suite is green on CI (CircleCI rspec, rubocop, brakeman; Actions lint, scan_ruby, scan_js).
- The #629 spec still passes. The new −32602 specs pass on 1.9.0, and case (a) fails on 1.8.2.
- Snapshot diffs contain only `title` and the four `maxLength` lines. Tool counts unchanged (12 / 9 / 22).
- The 2,049 / 2,048 query specs pass for all four tools.
- `compare.rb`: 0 failed expectations, 0 unexpected differences. `clients.sh`: 12 of 12 OK.
- No real hostnames, IPs, usernames or home paths in docs. Synthetic data only.

## Stop and ask Steve if

The D-7, title and gem-bump surface change above is pre-approved; do not stop for it. Stop for anything beyond it:
- the lock diff touches anything other than `mcp`, or the work needs a new gem;
- the work needs a new migration;
- the diff grows past ~3,000 lines;
- anything would weaken the lockdown (profiles, allowlists, auth, `/mcp` ≤ 12 tools) or the anonymizer/cloud gate;
- an existing spec or snapshot changes for any reason other than T or Q;
- the gem refuses titled tools for an old-protocol client instead of omitting the title;
- `compare.rb` can't record a reference that sends no reply without code changes, or C shows a new failure;
- a newer `mcp` release has appeared by the time of the PR (re-plan rather than skip a version).
