# PR-2 resume notes (graph_mem 1.54.0)

Written 2026-10-23 on wks-0 before a three-day break, so a new Claude Code session on
another machine can pick PR-2 up. Read this first, then `claude-kickoff.md` (the rules)
and `mcp-update-plan.md` (PR-2 is §2.1–§2.21, CHANGELOG text in §2.16, acceptance in
§2.14). Delete this file in the release commit; it's a one-off handoff.

## Where the train is

| Item | State |
|---|---|
| AR rules rewrite (1.53.0) | merged (#107) |
| PR-1 fast-mcp 1.8.0 | merged (fast-mcp #4), tagged `1.8.0` = `84c98dd` |
| PR-0 (mounts / ScanRootPolicy) | merged (#111) |
| **PR-2 (1.54.0)** | **in progress** on `claude/pr-2-mcp-hardening-1.54`, pushed, **no PR opened yet** |
| Next | AR-E harness (never start the AR-E *eval*), PR-3 (1.54.1), MG track (MG-0 needs Steve's OK before MG-1), UI-1…UI-7 |

## PR-2: done (one commit each, oldest first)

| Commit | Plan § | What |
|---|---|---|
| `3b7baa9` | 2.1 | Gemfile pins fast-mcp `84c98dd` (tag 1.8.0); `McpServerPatch::EXPECTED_FORK_VERSION = "1.8.0"`; initializer passes `max_request_bytes`, `cors_allowed_origins`, `require_sse_session: true` |
| `f49c567` | 2.13 | `bin/mcp_stdio_runner.rb` keeps stdout for JSON-RPC only (logs → stderr); `spec/bin/mcp_stdio_runner_stdout_spec.rb` |
| `32e8f50` | 2.17–2.18 | `lib/graph_mem/mcp_server_options.rb`: per-profile `instructions`, capabilities advertise `subscribe`/`listChanged: false` |
| `80f66eb` | — | behaviour-neutral split of the transport into `lib/graph_mem/mcp_streamable_http/{sessions,streams,responses}.rb`. **Alone it fails eager loading** (fixed in the next commit); say so in the PR |
| `869e4d5` | 2.2–2.4, 2.9, 2.19 | `request_checks.rb` (413 body cap, tagged `parse_json`, envelope / null-id / id-type checks, `MCP-Protocol-Version` 400), negotiation, 256-session cap → 503, 409 duplicate GET stream, ids on 400/404, CORS reflects origin + `Vary: Origin`; hardening spec (31 examples) |
| `14fe3e1` | 2.7–2.8 | `app/services/graph_write_service/duplicates.rb`: semantic check outside the lock, exact check inside; `on_duplicate: "reject"\|"skip"` with `skipped`; real delete counts; concurrency spec |
| `5cb38b0` | 2.20.1 | CSRF matrix rows (junk Bearer, no session → 401 + `WWW-Authenticate`; public IP → 403) |
| `263ce1a` | 2.20.2 | import review inline `:javascript` → `import_decision_controller.js` (Stimulus); nonce request spec + static guard `spec/inline_scripts_spec.rb` |
| `abbe28b` | 2.20.4 | README stray `)` |
| `5914826` | 2.20.6 | `GRAPH_MEM_MCP_ALLOWED_IPS` default = loopback + private (README and `docs/mcp_access_control.md`) |
| `0d6b9a3` | 2.20.5 | 503 page and log line name only `OPERATOR_PASSWORD` |
| `d626e5a` | 2.20.7 | `allow_guest` appends; `spec/controllers/concerns/role_authorization_spec.rb` |
| `9749871` | 2.20.8 | `DataExchangeController` CSRF skip removed (the graph JS already sent `X-CSRF-Token`); `spec/requests/data_exchange_csrf_spec.rb` (16 rows) |

§2.20 item 3 was already done on `main` (`39db049`). Each new spec was checked red against the old code.

## PR-2: still to do, in this order

1. **§2.21 no unstubbed HTTP in specs.** `rg -n "\.test(:\d+)?" spec` lists the offenders (`spec/requests/api/v1/summaries_spec.rb`, `spec/requests/operator/settings_spec.rb`, `spec/services/embedding_config_spec.rb`). Stub them at the service boundary (`SummaryGenerationClient`, `EmbeddingService`). Add a global guard in `spec/support/` that lets localhost through (system specs, Selenium). Choose WebMock (a new test dependency, so say so in the PR) or a small `Net::HTTP` guard, and give the reason. Own commit.
2. **§2.11 docs**, new behaviour only: body limit (`GRAPH_MEM_MCP_MAX_REQUEST_BYTES`, 4 MiB → 413), session limit (`GRAPH_MEM_MCP_MAX_SESSIONS`, 256 → 503), `MCP-Protocol-Version` handling, stdio logging to stderr, `MCP_PROTOCOL_NEGOTIATION=legacy`. In `docs/mcp_access_control.md`, add the stdio launch rule (a fixed absolute path to `bin/mcp_stdio_runner.rb`, no user-supplied args). Add a fast-mcp feature map to `docs/architecture.md`. The line-ref fixes are Devin's M-D3, after PR-2 merges.
3. **Release commit:** `VERSION` → 1.54.0, `skills/graph-mem-mcp-toolset/SKILL.md` `metadata.graph-mem-version: "1.54.0"`, CHANGELOG `[Unreleased]` → `[1.54.0] - <commit date>` (Steve's rule: the commit date, not the merge date) with the §2.16 entries, adjusted:
   - **drop** the 2,048-char query-cap line, because M-D1 (`devin/m-d1-query-cap`) isn't merged (D-23);
   - **drop** the "resources/updated only to subscribed sessions" line; §2.5 doesn't apply now that §2.18 sets `subscribe: false`;
   - the import-review line: "moved to a Stimulus controller";
   - **add (behaviour change):** an exact duplicate entity name in `graph_write` now returns a structured `possible_duplicate` (`reason: "same_name"`) instead of a validation error;
   - delete this file.
4. **Verification:** the full suite run on its own (truncate the test DB before and after, then confirm 0 rows), `bundle exec rubocop`, `bin/brakeman`.
5. **Manual checks** (§2.14): curl probes against a local `/mcp` (oversized → 413; `initialize` 2026-07-28 → 2025-11-25; bad header → 400; arrays → 400; unknown session → 404 with id); Ruby SDK client over HTTP; click through the graph UI's move/merge/delete-relation in dev (forgery protection on there), since no system spec drives those writes.
6. Report to Steve (files, deviations, suite count, rubocop, brakeman, "test DB rows after: 0", handoffs, manual checks). **No PR or push without his OK.**

## Deviations to put in the PR description

- An exact-duplicate entity name now returns `possible_duplicate` (`same_name`) rather than a validation error. `create_entity_tool_spec` and `bulk_update_tool_spec` were updated for it.
- Exact-duplicate checks on observations run only with `on_duplicate: "skip"`, so the default behaviour is unchanged (D-5).
- The plan's "three profile servers" are one server with per-request profile filters.
- §2.5 targeted notifications: N/A (no subscribe capability).
- `80f66eb` fails eager loading on its own; `869e4d5` fixes it by moving the header constants into `lib/graph_mem/mcp_streamable_http.rb`.
- Outside PR-2's scope, reported only: `spec/services/compaction_review_service_spec.rb` leaves ~26 `audit_logs` rows; the full-suite truncate clears them.

## Environment notes (machine-specific: re-check on the new machine)

- On wks-0, RVM lives at **`/usr/share/rvm/scripts/rvm`**, not `~/.rvm` as `AGENTS.md` says. Use whichever exists, and confirm with `ruby -v` (3.4.1) before trusting a pass or a failure. Gemset: `ruby-3.4.1@graph_mem`. The fast-mcp gemset is `ruby-3.4.1@fast_mcp`.
- Spec env: `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`, with **`SUMMARY_URL` unset** (it falls back to `OLLAMA_URL`; exporting it breaks a spec). No spec may reach a real embedding or LLM service.
- On wks-0, the Ollama on :11434 serves the production graph_mem container. Never stop it.
- The fast-mcp 1.8.0 dependency comes from GitHub (pinned ref), so `bundle install` needs no local `../fast-mcp`.
- Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Dir.mktmpdir`); test DB only; no `zz_*` scratch specs.

Test-DB truncate (`truncate.rb`; run with `RAILS_ENV=test bin/rails runner truncate.rb`, from outside the repo):

```ruby
c = ActiveRecord::Base.connection
c.execute("SET FOREIGN_KEY_CHECKS=0")
(c.tables - %w[schema_migrations ar_internal_metadata]).each { |t| c.execute("TRUNCATE TABLE #{c.quote_table_name(t)}") }
c.execute("SET FOREIGN_KEY_CHECKS=1")
rows = (c.tables - %w[schema_migrations ar_internal_metadata]).sum { |t| c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name(t)}").to_i }
puts "test DB rows: #{rows} (db=#{c.current_database})"
```

Leftover-row finder (handy after a single spec file):

```ruby
c = ActiveRecord::Base.connection
rows = (c.tables - %w[schema_migrations ar_internal_metadata]).to_h { |t| [ t, c.select_value("SELECT COUNT(*) FROM #{c.quote_table_name(t)}").to_i ] }.select { |_t, n| n.positive? }
puts "rows left: #{rows.inspect}"
```

## Still open with Steve

- Devin handoffs M-D3 (docs line refs, after PR-2) and AR-D4: offered earlier, no answer yet. They go in `docs/plans/handoff/devin-<id>-<slug>.md` when he says go.
- Full adoption smoke test across clients: Steve runs it after 1.54.0 is deployed to the production container.
