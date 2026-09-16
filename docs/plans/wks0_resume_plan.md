# Resume plan: MCP access control + shared-client detection

Work done on **wks-1** (192.168.0.100) on 2026-09-16. Everything below is written and lint-clean
but **the RSpec suite has never been run against it**, because wks-1 has MariaDB 10.6 and GraphMem
needs 11.8+. Finish on **wks-0** (192.168.0.18), which runs the real instance.

## State at handover

| Check | Result |
|---|---|
| `bundle exec rubocop` on all changed Ruby | 9 files, no offenses |
| `ruby -c` on every changed file | Syntax OK |
| Rails boot (`rspec` loads `config/environment`) | Boots; logs `[McpAccessPolicy] /mcp access: no token (unauthenticated), 7 allowed range(s)` |
| Access-policy logic | 44 assertions verified standalone (no Rails/DB) — all passing |
| Transport guard | 15 assertions verified standalone — all passing |
| `bundle exec rspec` | **Never run.** Blocked by MariaDB version, then by the pending migration |
| `db/structure.sql` | Deliberately **not** regenerated — see the warning below |

## Do not regenerate `db/structure.sql` on an old MariaDB

wks-1 runs MariaDB 10.6.23, which cannot create `memory_entities.embedding vector(768)`. The local
`graph_mem_development` database therefore has **no embedding column**, and running
`rails db:migrate` there produced a `structure.sql` with the vector columns and indexes silently
deleted. That dump was reverted (`git checkout -- db/structure.sql`).

On wks-0, after `rails db:migrate`, check the diff before committing:

```bash
git diff db/structure.sql | rg '^[+-].*vector'      # expect NO deletions
git diff db/structure.sql | rg 'NOTE_VERBOSITY|SQL_NOTES'   # pragma churn = wrong dump client
```

The expected diff is exactly two added columns on `agent_contexts` (`context_set_at`,
`last_session_id`) plus possibly `AUTO_INCREMENT=` churn.

## Step 1 — Migrate and run the suite

```bash
cd ~/Projects/graph_mem
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem

bundle exec rails db:migrate
git diff db/structure.sql          # apply the checks above

bundle exec rspec \
  spec/lib/graph_mem/mcp_access_policy_spec.rb \
  spec/lib/graph_mem/mcp_streamable_http_transport_spec.rb \
  spec/models/agent_context_spec.rb \
  spec/models/graph_mem_context_spec.rb \
  spec/tools/set_context_tool_spec.rb \
  spec/tools/get_context_tool_spec.rb

bundle exec rspec                  # then the full suite
```

### Where failures are most likely

**`get_context_tool_spec` "session tracking" block.** It drives `record_client_activity!`
(a private method) twice and stubs `current_session_id` to fake two sessions. If `@concurrent_session`
does not survive the way the spec expects, prefer setting up the `AgentContext` row directly and
stubbing `concurrent_session?` on the tool instead.

**`set_context_tool_spec` "can overwrite an existing context".** This pre-existing example now also
triggers the shared-client warning, because it sets two different projects seconds apart. Its
assertions only check `current_project_id`, so it should still pass — if it does not, the warning
merge is leaking into a key it checks.

**Regression risk on `search`/`summarize` specs.** `GraphMemContext#current_project_id=` now
delegates to `set_project!`, which additionally stamps `context_set_at`. Behaviour is otherwise
identical, but anything asserting on `AgentContext` attributes may need the new column.

## Step 2 — Turn the token on

The token has **already been generated and written into the two client configs on wks-1**:

- `~/.cursor/mcp.json` (`X-MCP-Client: cursor-1`)
- `~/.codeium/windsurf/mcp_config.json` (`X-MCP-Client: devin-1`)

Backups were left alongside as `*.bak-20260916`. The value exists only in those files — read it
from there.

Ordering matters, and it is safe in this direction: **clients first, server second.** While no
token is configured server-side, `authenticated?` returns true regardless of the header, so the
clients keep working with the new header until the server starts requiring it.

On wks-0:

```bash
cd ~/Projects/graph_mem
# Add to .env (gitignored). Use the value already in ~/.cursor/mcp.json on wks-1.
echo 'GRAPH_MEM_MCP_TOKEN=<value-from-cursor-mcp.json>' >> .env
echo 'GRAPH_MEM_MCP_ALLOWED_IPS=192.168.0.0/24' >> .env

docker compose up -d --force-recreate app
docker compose logs app | grep McpAccessPolicy
# expect: bearer token required, 1 allowed range(s)
```

Then verify from another workstation:

```bash
# expect 401
curl -si -X POST http://192.168.0.18:3030/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | head -1

# expect 200
curl -si -X POST http://192.168.0.18:3030/mcp -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" -H 'X-MCP-Client: curl-check' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' | head -1
```

### The one thing to watch: both real clients use the legacy `/mcp/sse` endpoint

Their configured URL is `http://192.168.0.18:3030/mcp/sse`, not `/mcp`. The SSE flow is a
long-lived `GET /mcp/sse` **plus** separate `POST /mcp/messages` calls, and both now pass through
the token check. If a client sends configured headers only on the initial `GET` and not on the
subsequent `POST`s, tool calls will start returning 401 while the connection itself looks healthy.

Test this deliberately after enabling the token: connect, then call one tool. If it breaks, the
options are to migrate those clients to the Streamable HTTP endpoint (`/mcp`, which is the
recommended transport anyway) or to exempt `/mcp/messages` when its SSE session was already
authenticated. Migrating is preferable.

## Step 3 — Remaining follow-ups

**File the upstream reports.** Two ready-to-paste issues in
[`upstream_fast_mcp_issues.md`](upstream_fast_mcp_issues.md) against
<https://github.com/yjacquin/fast_mcp>: the inert `allowed_ips` guard (security) and the
advertised-but-unimplemented `tools.listChanged` capability.

**Decide on the toolset consolidation.** [`mcp_toolset_consolidation.md`](../mcp_toolset_consolidation.md)
proposes 35 tools → 12 in the default profile. Phase 0 there (queryable `tool_invocations`
telemetry) is the prerequisite and is independent of this work. Note the connection-profile
mechanism relies on `filter_tools`, which is the same upstream file as Issue 1 — worth landing
both together.

## Files changed

**New:** `lib/graph_mem/mcp_access_policy.rb`,
`spec/lib/graph_mem/mcp_access_policy_spec.rb`,
`db/migrate/20260916120000_add_session_tracking_to_agent_contexts.rb`,
`docs/mcp_access_control.md`, `docs/mcp_toolset_consolidation.md`,
`docs/plans/upstream_fast_mcp_issues.md`, this file.

**Modified:** `lib/graph_mem/mcp_streamable_http_transport.rb` (policy wiring, auth chokepoint,
`unauthorized_response`, `Authorization` in CORS headers), `config/initializers/fast_mcp.rb`,
`app/models/agent_context.rb`, `app/models/graph_mem_context.rb`, `app/tools/application_tool.rb`,
`app/tools/set_context_tool.rb`, `app/tools/get_context_tool.rb`, `docker-compose.yml`,
`.env.example`, `README.md`, `docs/development.md`, `docs/mcp_tools.md`, plus four spec files.
