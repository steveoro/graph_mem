# graph_mem on the official `mcp` gem: streamlined plan (replaces MG-0 … MG-6)

**Status: DONE (2026-10-25).** PR A shipped as 1.55.0 (#118), PR B as 1.55.1 (#120), PR C as 1.55.2.
Approved by Steve on 2026-10-25. All work is Claude's. This plan supersedes the MG track in
`docs/plans/mcp-update-plan.md` (§MG, rows 7–14) and the MG-0 draft in PR #117, which is closed unmerged
(Steve closes it; the branch `claude/mg-0-design` stays for reference: spike results, the load shim and the
`AccessToken` context pattern).

**Approach.** fast-mcp is dropped as soon as possible, so graph_mem takes the gem's defaults wherever the
two differ, unless that's a security problem. There's no engine switch, no dual-engine CI and no per-tool
parity work; rollback is a revert, or redeploying the previous tag. A downstream app migrates only after
graph_mem runs on the gem alone, so the reusable migration guide is written last, from the finished code (PR C).

**Baseline:** `main` 64e16bb (1.54.3), fast-mcp fork 1.8.0 (`84c98dd`), `mcp` gem 1.8.1. The MG-0 spike
showed:
- one generic wrapper serves all 40 tool classes;
- every schema passes the gem's 2020-12 validation;
- per-request context reaches tools through an `AccessToken` in `env["mcp.auth_info"]`.

## 1. Decisions (APPROVED by Steve, 2026-10-25)

| # | Today (fast-mcp / graph_mem) | `mcp` 1.8.1 | Decision |
|---|---|---|---|
| D1 | At the session cap, evict the least recently active idle session | Reap expired sessions, then **503** on a new `initialize` | Accept the gem's behaviour |
| D2 | `GRAPH_MEM_MCP_MAX_SESSIONS` (256) | `max_sessions:` (default 10 000) | Keep the setting: `max_sessions: Integer(ENV.fetch("GRAPH_MEM_MCP_MAX_SESSIONS", 256))` |
| D3 | Idle sessions reaped after 30 min | `session_idle_timeout:` 1800 s | Gem default (same value) |
| D4 | Origin allowlist with patterns | `allowed_origins:` exact `scheme://host:port`; same-origin and no-`Origin` requests pass | New `GRAPH_MEM_MCP_ALLOWED_ORIGINS` (comma-separated exact list, empty by default) |
| D5 | `rack-cors` for `/mcp/*` + the old transport's SSE headers | No CORS headers | `config/initializers/cors.rb` stays as it is; nothing added |
| D6 | Origin check in the old transport | DNS-rebinding protection (Host **and** Origin), on by default | **Keep it ON.** New `GRAPH_MEM_MCP_ALLOWED_HOSTS` for LAN host names. Never set `dns_rebinding_protection: false` (it also drops the Origin check, and the IP allowlist can't stop rebinding) |
| D7 | `GRAPH_MEM_MCP_MAX_REQUEST_BYTES` (4 MiB) | `max_request_bytes:` (+ 64 KiB `initialize` cap); stdio `max_line_bytes:` | Keep the setting and pass it to both; accept the 64 KiB `initialize` cap |
| D8 | Tool errors → `ToolError` envelope; other errors logged | `configuration.exception_reporter`, called only on the gem's -32603 path | The wrapper keeps the envelope with `code`; `exception_reporter` calls `Rails.error.report` |
| D9 | The normaliser and dry-schema validate (aliases allowed) | `validate_tool_call_arguments` is an `MCP::Configuration` option | One shared `MCP::Configuration.new(validate_tool_call_arguments: false, exception_reporter: …)` for all 3 servers, plus a lenient `InputSchema` |
| D10 | 17 wire edge cases (PR-3's Ruby SDK 1.8.1 column in `docs/protocol_compat.md`) | Gem answers | Accept them all; the fixtures move to the gem's answers |
| D11 | 18 hidden alias tools | The gem lists every registered tool | **Remove** in PR A (breaking) |
| D12 | Legacy `/mcp/sse` (deprecated) | No equivalent | **Remove** in PR A (breaking) |
| D13 | 2026-07-28 planned as MG-5 | The gem serves both eras | Comes with PR A |
| D14 | Gem pin | n/a | `gem "mcp", "1.8.1"` (exact); one PR per upgrade |

The 18 aliases: `bulk_update`, `clear_context`, `create_entity`, `create_observation`, `create_relation`,
`delete_entity`, `delete_observation`, `delete_relation`, `find_relations`, `get_entity`,
`get_subgraph_by_ids`, `get_version`, `list_entities`, `merge_entities`, `search_entities`,
`search_subgraph`, `update_entity`, `update_observation`.

## 2. Rules for every PR
- **Order:** A, then B, then C. Each PR waits for review and **Steve's merge** before the next one starts.
  Branch off the latest `main`.
- **CI:** CircleCI (`rspec`, `rubocop`, `brakeman`, reported as commit statuses) and GitHub Actions
  (`lint`, `scan_ruby`, `scan_js`). All must be green.
- **Locally:**
  - `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 bundle exec rspec`, with the test DB truncated before
    and after;
  - `bundle exec rubocop` (rubocop-rails-omakase);
  - `bin/brakeman --no-pager`.
- **No new code** references `FastMcp`, `fast_mcp` or `fast-mcp`. In PR A, only the existing tool, prompt
  and resource base classes still inherit from fast-mcp; PR B removes that.
- **Releases:** Steve merges and tags. Each PR bumps `lib/graph_mem/version.rb` and adds a dated
  CHANGELOG section (Keep a Changelog). Never rewrite older CHANGELOG entries.
- **Public text:** docs, commits and PR text name only public projects (graph_mem, fast-mcp, the official
  SDKs and reference servers). Any other consumer is "a downstream app". Examples use synthetic data.
- **Stop and ask** (comment on the PR and wait) whenever a stop condition below triggers, or when the plan
  and the code disagree.

## 3. PR A: swap the engine → 1.55.0
**Branch:** `claude/mg-a-engine-swap`. All MCP traffic is served by the `mcp` gem. fast-mcp stays in the
Gemfile only because `ApplicationTool`, `ApplicationPrompt` and `ApplicationResource` still inherit from it.

**Tasks, in order:**
1. **First commit (docs):**
   - add a status note at the top of §MG in `docs/plans/mcp-update-plan.md` pointing to this file, and mark
     rows 7–14 of its table as superseded;
   - replace `docs/plans/mcp-gem-migration.md`, if it's on `main`, with a one-line pointer here.
2. **Gemfile:** `gem "mcp", "1.8.1"`; run `bundle install`.
3. **Load shim, `lib/graph_mem/official_mcp.rb`:** both gems ship `lib/mcp/{version,tool,prompt,resource,server}.rb`,
   so require those 5 from the `mcp` gem's directory (`Gem.loaded_specs["mcp"].full_gem_path`), then the
   rest of the gem. It's removed in PR B.
4. **`lib/graph_mem/official_mcp/tool_wrapper.rb`:** `ToolWrapper.build(tool_class)` returns an `MCP::Tool`
   subclass with the same `tool_name`, description, input/output schema (fast-mcp's JSON in a lenient
   `MCP::Tool::InputSchema` subclass whose `missing_required_arguments` returns `[]`) and annotations.
   - `call(server_context:, **args)` runs `tool_class.new(...).call_with_schema_validation!` and formats the
     result exactly as today: content, `structuredContent`, `_meta`, and `next_move`.
   - Every error becomes the existing `ToolError` JSON envelope (with `code`) as an `isError` result.
5. **`lib/graph_mem/official_mcp/server_factory.rb`:** `ServerFactory.for(profile)` builds an `MCP::Server`
   per profile (`default`, `readonly`, `maintenance`) with:
   - tools and prompts from `McpProfile.select_tools` / `select_prompts`;
   - `instructions:` from `McpInstructions.for(profile)`;
   - an explicit `capabilities:` matching today's `initialize` result (no `listChanged`, no `subscribe`,
     no `logging`);
   - the shared configuration (D8, D9);
   - resources: the 4 templates from `app/resources/`, and a `resources_read_handler` that dispatches the
     URI to the matching resource class;
   - `persist` left off readonly.
6. **`lib/graph_mem/official_mcp/request_context.rb`:** a Rack middleware that runs after `McpAccessPolicy`
   and sets
   `env["mcp.auth_info"] = MCP::Server::OAuth::AccessToken.new(token: "graph_mem", claims: { graph_mem: context })`.
   - The context holds the client (`X-MCP-Client`), the profile and the session id.
   - The wrapper reads it from `server_context` and sets the thread-locals `ApplicationTool` already uses.
   - `ApplicationTool#current_mcp_profile` and the client lookup read it instead of
     `self.class.server.current_request`.
7. **`config/initializers/mcp.rb`** replaces `config/initializers/fast_mcp.rb`:
   - `McpAccessPolicy` (unchanged) in front, then `RequestContext`;
   - one `MCP::Server::Transports::StreamableHTTPTransport` per path (`/mcp`, `/mcp/readonly`,
     `/mcp/maintenance`) with `enable_json_response: true`, `max_sessions:` (D2), `max_request_bytes:` (D7),
     `allowed_hosts:` from `GRAPH_MEM_MCP_ALLOWED_HOSTS` and `allowed_origins:` from `GRAPH_MEM_MCP_ALLOWED_ORIGINS`;
   - DNS-rebinding protection left at its default, which is on (D6).
8. **`bin/mcp_stdio_runner.rb`:**
   - keep the stdout guard (the saved real stdout; `STDOUT`/`$stdout` pointed at stderr);
   - serve `ServerFactory.for(ENV["GRAPH_MEM_MCP_PROFILE"])` through
     `lib/graph_mem/official_mcp/stdio_transport.rb`, a `MCP::Server::Transports::StdioTransport` subclass
     whose public `send_response` writes to the saved pipe, with `max_line_bytes:` from D7.
   - Check `bin/mcp_graph_mem_runner.sh` and `bin/docker-mcp` still work.
9. **Remove the 18 aliases** (D11): their tool classes, registry entries, specs and doc mentions.
   **Remove `/mcp/sse`** (D12): the route, the config and `spec/requests/mcp_messages_spec.rb`.
10. **Old request specs** that pinned fast-mcp wire quirks (`spec/requests/mcp_streamable_http_spec.rb`,
    `spec/requests/mcp_initialize_options_spec.rb`): delete the quirk cases, and move cases that check real
    behaviour into the new spec below. The old transport classes stay unreferenced until PR B.
11. **New `spec/requests/mcp_official_spec.rb`** (synthetic data only):
    - *Profile gating:*
      - `tools/list` returns 12 tools on `/mcp`, 9 on `/mcp/readonly` and 22 on `/mcp/maintenance`;
      - a write tool called on `/mcp/readonly` is refused and writes nothing;
      - a maintenance tool called on `/mcp` is refused;
      - `prompts/list` on readonly has no `persist`.
    - *Auth:*
      - with `GRAPH_MEM_MCP_TOKEN` set, a missing or wrong token gets 401 + `WWW-Authenticate`;
      - an IP outside `GRAPH_MEM_MCP_ALLOWED_IPS` gets 403;
      - a foreign `Host` or `Origin` gets 403;
      - `X-MCP-Client` reaches the `tool_invocations` row.
    - *Error envelope codes:* an invalid-argument call, a `scan_project` refusal (e.g. `not_mounted`) and an
      `ambiguous_name` in a `graph_write` batch each return the JSON envelope with its `code` as an
      `isError` result.
    - *Session cap:* with a cap of 2, a third `initialize` gets 503.
12. **stdio spec** (extend `spec/integration/mcp_structured_output_stdio_spec.rb`), with the runner spawned:
    - stdout carries only JSON-RPC lines;
    - a tool error comes back as the same envelope;
    - a line over the cap ends the session without writing anything else to stdout.
13. **Compat replay:** update the graph_mem expectations in `spec/fixtures/mcp/handshakes/` (16 stdio,
    27 HTTP) and `spec/requests/mcp_protocol_compat_spec.rb` to the gem's answers.
14. **Docs touched by behaviour:** `docs/mcp_access_control.md` (D1 session-cap text; the new
    `GRAPH_MEM_MCP_ALLOWED_HOSTS` / `GRAPH_MEM_MCP_ALLOWED_ORIGINS` settings; D6 kept on) and `.env` examples, if any.
15. **Version and CHANGELOG:** `1.55.0`, with a dated section:
    - **Changed:** MCP is served by the official MCP Ruby SDK (`mcp` 1.8.1). It includes the 2026-07-28
      protocol. Edge-case wire answers follow the SDK (link `docs/protocol_compat.md`). At the session
      cap, a new session gets 503 instead of evicting an idle one.
    - **Added:** `GRAPH_MEM_MCP_ALLOWED_HOSTS` and `GRAPH_MEM_MCP_ALLOWED_ORIGINS`.
    - **Removed (BREAKING):** the legacy `/mcp/sse` endpoint, and the 18 hidden alias tools (list them).
      Clients must use Streamable HTTP on `/mcp*` and the canonical tool names.

**Gate:**
- The full suite, rubocop and brakeman are green locally and in CI.
- **The existing tool, service, prompt and resource specs pass with no edits** (apart from alias removal
  and the error class). They are the behaviour check.
- The compat fixture diff matches the "Ruby SDK 1.8.1" column of `docs/protocol_compat.md` row for row.
- `script/mcp_compat/clients.sh`: the TS 2.3.1 and Ruby SDK clients connect in `auto` and `legacy` modes
  over stdio and HTTP, and `auto` negotiates 2026-07-28.
- `rg -n "FastMcp|fast_mcp|fast-mcp" lib/graph_mem/official_mcp config/initializers/mcp.rb spec/requests/mcp_official_spec.rb`
  finds nothing.

**Stop and ask if:**
- a compat fixture changes outside the SDK 1.8.1 column;
- any existing tool, service, prompt or resource spec needs an edit beyond alias removal;
- a tool needs per-tool code in the wrapper;
- the gem needs a monkey-patch or fork;
- the client run fails in either mode.

**Done when:** the gate is green, the PR against `main` lists the D1–D14 decisions it implements and the
breaking removals, and Steve has the client-check note (`docs/plans/claude-mcp-client-check.md` to re-run
before tagging).

## 4. PR B: delete fast-mcp → 1.55.1
**Branch:** `claude/mg-b-drop-fast-mcp`, after A is merged. No wire change.

**Tasks, in order:**
1. **Vendor the schema converter:** copy fast-mcp's `arguments do` → JSON Schema conversion (and the
   `arguments` / `input_schema` class API the tools use) into `lib/graph_mem/mcp_schema/`, with the MIT
   licence header and attribution. Add `gem "dry-schema"` to the Gemfile as a direct dependency.
2. **Base classes:** `ApplicationTool`, `ApplicationPrompt` and `ApplicationResource` stop inheriting
   from fast-mcp classes and use the vendored API.
3. **Error class:** add `GraphMem::InvalidArgumentsError` and replace `FastMcp::Tool::InvalidArgumentsError`
   everywhere: app, services and specs, about 40 files, mechanically.
4. **Delete:**
   - from the Gemfile and lockfile: the `fast-mcp` gem and its git pin;
   - `lib/graph_mem/mcp_server_patch.rb` (with `EXPECTED_FORK_VERSION`) and
     `spec/lib/graph_mem/mcp_server_patch_spec.rb`;
   - `lib/graph_mem/mcp_streamable_http_transport.rb`, `lib/graph_mem/mcp_streamable_http.rb`,
     `lib/graph_mem/mcp_streamable_http/` and their two specs in `spec/lib/graph_mem/`;
   - `spec/integration/fast_mcp_registration_spec.rb`;
   - `lib/graph_mem/mcp_server_options.rb` and `lib/graph_mem/mcp_tool_registry.rb`, if nothing references
     them any more;
   - the load shim (`lib/graph_mem/official_mcp.rb`), replaced by a plain `require "mcp"`;
   - the unused instance-level `input_schema_to_json` in `suggest_merges_tool.rb` (the other five were
     on alias classes that PR A removed).
5. **Snapshot spec** `spec/mcp/tools_list_snapshot_spec.rb`: the `tools/list` result for each profile,
   recorded on 1.55.0 **before** step 1.
6. **Version and CHANGELOG:** `1.55.1`, with **Removed:** the fast-mcp dependency (internal; no change on
   the wire).

**Gate:**
- `rg -n "FastMcp|fast_mcp|fast-mcp" app lib config bin spec Gemfile Gemfile.lock --glob '!spec/fixtures/files/**'`
  finds nothing. (Steve, 2026-10-25: the graph-export fixtures under `spec/fixtures/files/` mention fast-mcp
  as data, the graph's own history, and stay as they are.)
- The full suite, PR A's gate specs, rubocop and brakeman are green.
- The snapshot spec shows `tools/list` byte-identical to 1.55.0 for all 3 profiles.
- CHANGELOG history is untouched.

**Stop and ask if:**
- the vendored converter changes any `inputSchema`;
- a tool depends on fast-mcp behaviour other than the schema DSL and the error class;
- the licence or attribution of vendored code is unclear.

**Done when:** the gate is green and the PR against `main` lists every deleted file.

## 5. PR C: docs and the reusable guide → 1.55.2
**Branch:** `claude/mg-c-docs`, after B is merged. Docs only.

**Tasks, in order:**
1. **`docs/protocol_compat.md`:**
   - graph_mem's columns become the gem's answers;
   - rows the gem now matches become "same";
   - re-run `script/mcp_compat/compare.rb` and `clients.sh` once and record the results and the date.
2. **Name swap** to "the official MCP Ruby SDK (`mcp` gem)", removing fast-mcp-only details from:
   - `README.md` (stack line, MCP section, `/mcp/sse` mentions);
   - `docs/mcp_tools.md` (opening paragraph, exception mapping);
   - `docs/architecture.md` (feature map);
   - `AGENTS.md` and `CLAUDE.md` (MCP layer);
   - `docs/development.md` and `docs/troubleshooting.md`, wherever fast-mcp or `/mcp/sse` appears.
3. **`docs/guides/migrating-fast-mcp-to-mcp-gem.md`**, written from the finished code for a downstream
   Rails app making the same move:
   - an inventory checklist;
   - the wrapper and server-per-profile pattern;
   - a mapping table checked against `mcp` 1.8.1;
   - the decision table (§1) as a template;
   - pitfalls: the load-path clash while both gems are loaded, context through an `AccessToken`, stdout
     hygiene on stdio, keeping DNS-rebinding protection on;
   - the gate from PR A;
   - a removal checklist from PR B.

   graph_mem is the worked example, in "Example (graph_mem)" boxes. No other app is named. Link it from
   `README.md` and `docs/protocol_compat.md`.
4. **`docs/plans/mcp-update-plan.md`:** mark the MG track done.
5. **Version and CHANGELOG:** `1.55.2`, with **Documentation:** the migration guide and the refreshed
   protocol compatibility page.

**Gate:**
- `rg -n "fast-mcp|FastMcp|/mcp/sse" README.md docs/*.md AGENTS.md CLAUDE.md` finds only historical
  mentions (CHANGELOG, `docs/plans/`).
- All links resolve.
- CI is green.

**Stop and ask if:** a doc needs a statement about behaviour the code doesn't have.

**Done when:** Steve has read the guide through, and the PR against `main` is green.

## 6. What happened to the old MG steps
- **MG-0** (PR #117): superseded by §1 and closed unmerged.
- **MG-1, MG-2a, MG-3, MG-4, MG-5:** merged into PR A (no engine switch, no pilots, no parity template).
- **MG-2b:** dropped. The wrapper needs no per-tool work, and the aliases are removed.
- **MG-6:** split into PR B (removal) and PR C (guide).
- **MG-D1:** folded into PR C, done by Claude.
- **Dropped:** the `GRAPH_MEM_MCP_ENGINE` switch, the dual-engine CI job, the `compare.rb` engine column,
  per-tool parity specs, and the Rack pre-filter for PR-2 quirks.
