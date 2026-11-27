<img src="../app/assets/images/logo.svg" alt="GraphMem logo" width="64" height="64" align="right">

# Development Guide

This guide covers everything you need to know to set up a development environment and contribute to the GraphMem project.

## Local Development Setup

### Prerequisites

Before starting, ensure you have the following installed:

* Ruby 3.4.13+ (we recommend using [RVM](https://rvm.io/) or [rbenv](https://github.com/rbenv/rbenv) for Ruby version management)
* MariaDB 11.8+ (with vector support)
* [Bundler](https://bundler.io/)
* Git

> **MariaDB 11.8+ is a hard requirement, not a recommendation.** On an older server
> (10.x) the `memory_entities.embedding vector(768)` column cannot be created, so the
> database comes up with an incomplete schema. Two consequences: anything touching
> embeddings or vector search fails, and **`rails db:migrate` will dump a
> `db/structure.sql` with the vector columns and indexes silently missing.** Never commit
> a `structure.sql` generated on an older server -- check `git diff db/structure.sql` for
> disappearing `vector(768)` lines and MariaDB pragma churn (`@OLD_NOTE_VERBOSITY`
> becoming `@OLD_SQL_NOTES` indicates the wrong dump client) before committing a
> migration.

### Step 1: Clone the Repository

```bash
git clone https://github.com/your-org/graph_mem.git
cd graph_mem
```

### Step 2: Install Dependencies

Install the required Ruby gems:

```bash
bundle install
```

> **Upgrading from a checkout on an earlier Ruby.** The project runs on Ruby 3.4.13 (1.93.2: `.ruby-version`
> and `.versions.conf` pin it). With RVM, install it and create the `graph_mem` gemset for it, then
> install the gems there; a gemset belongs to one Ruby, so the one you had on 3.4.12 doesn't carry over:
>
> ```bash
> rvm install ruby-3.4.13
> rvm use ruby-3.4.13@graph_mem --create
> bundle install
> ```
>
> With rbenv, `rbenv install 3.4.13` and `bundle install`. A scripted or agent shell must select the
> gemset in the same command as the one it runs (source RVM's script, then `rvm use
> ruby-3.4.13@graph_mem && bundle exec rspec`), because RVM's per-directory switch is a hook of the
> interactive shell. `Bundler::GemNotFound` listing most of the lockfile means the wrong Ruby or gemset
> is active, not a broken bundle.

### Step 3: Configure the Database

Copy the sample database configuration:

```bash
cp config/database.example.yml config/database.yml
```

Edit `config/database.yml` to match your local MariaDB configuration. (`bin/setup` makes the same
copy when the file is missing.)

No master key is needed: in development and test Rails generates its own `secret_key_base` in
`tmp/local_secret.txt`.

### Step 4: Set Up the Database

Create and initialize the database:

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed  # Optional: loads sample data
```

### Step 5: Run the Server

Start the Rails server:

```bash
bin/rails server
```

Alternatively, use the provided MCP server script:

```bash
bin/mcp
```

The server exposes three Streamable HTTP profiles:

- `/mcp` — 12 advertised context, read, and mutation tools
- `/mcp/readonly` — 9 advertised context and read tools
- `/mcp/maintenance` — all 22 canonical tools

MCP is served by the official MCP Ruby SDK (`mcp` gem, pinned to 1.11.0) through the adapter in
`lib/graph_mem/official_mcp/` ([architecture.md](architecture.md#official-mcp-sdk-feature-map)).
Streamable HTTP and stdio speak 2026-07-28 (`server/discover`) and 2024-11-05 … 2025-11-25 (the
`initialize` handshake). Each profile has its own server and transport, and a session belongs to
the profile path that created it. Any other `/mcp/*` path (including the legacy `/mcp/sse`,
removed in 1.55.0) is 404.

The MCP endpoint checks the `Host` header (DNS-rebinding protection, always on). `localhost`,
`127.0.0.1` and `::1` are accepted; to reach a dev server by another address or name, list it in
`GRAPH_MEM_MCP_ALLOWED_HOSTS` ([mcp_access_control.md](mcp_access_control.md)).
Workflow guidance is available on demand through the `orient`, `recall`, and
`persist` MCP prompts (`persist` is not available on the readonly profile).
Each concrete prompt declares its profiles explicitly with
`mcp_metadata(profiles: ...)` in `app/prompts/`; the `ApplicationPrompt` base
class defaults to all three profiles as a safety net for undeclared subclasses.

The default 12 tools advertise `outputSchema` and emit matching
`structuredContent` plus mirrored JSON text. Maintenance-only tools remain
text-only until their schemas are migrated.

For the STDIO interface:

```bash
bundle exec ruby bin/mcp_stdio_runner.rb
```

STDIO defaults to the `default` profile. Set `GRAPH_MEM_MCP_PROFILE=readonly` or
`GRAPH_MEM_MCP_PROFILE=maintenance` in the launcher environment to select a
different catalog. The readonly stdio catalog also omits the `persist` prompt.

The stdio runner keeps stdout for JSON-RPC only: Rails, MCP and runner logs go to stderr, so a
`puts` or a `Logger.new($stdout)` in app code can't break strict clients such as the Ruby MCP SDK.
Read the logs from the client's MCP log view, or redirect stderr when running the runner by hand.
Launch it by a fixed absolute path with no user-supplied arguments
(see [mcp_access_control.md](mcp_access_control.md#stdio)).

Clients that probe `server/discover` in a separate process (the TS client in `auto` mode) start the
runner twice on first connect; `MCP_PROTOCOL_NEGOTIATION=legacy` in the client's environment skips
the probe.
Body, session and `MCP-Protocol-Version` limits on the HTTP endpoints are listed in
[mcp_access_control.md](mcp_access_control.md#request-limits-and-protocol-checks).

## Adding MCP Tools

1. Create `app/tools/my_feature_tool.rb` inheriting from `ApplicationTool` with a `tool_name` class method.
2. Declare `mcp_metadata` with profile membership, the `advertised:` flag, and all four boolean MCP annotation hints.
3. Update the tool counts in `spec/lib/graph_mem/mcp_tool_registry_spec.rb`, and re-record the list snapshots in `spec/fixtures/mcp/snapshots/` (`spec/mcp/tools_list_snapshot_spec.rb` compares `tools/list`, `prompts/list`, `resources/templates/list` and, since 1.87.0, `resources/list` per profile; replace only the changed entries in place; say so in the PR). To open an MCP Apps view on the tool's calls, set `mcp_ui_view` next to `title` (only `traverse_graph` and `find_shortest_path` do).
4. Add a request/tool spec under `spec/tools/`.

Tool files are **not** registered by filename alone. `GraphMem::McpToolRegistry` eager-loads every `*_tool.rb` before `GraphMem::OfficialMcp::ServerFactory` builds each profile's server, so new classes are picked up even in development lazy-load mode.

After adding a tool:

1. Restart `bin/dev` (or touch a file to trigger `to_prepare` re-registration in development).
2. **Reconnect the MCP server in Cursor** (disable/re-enable it in MCP settings) so the client refreshes its cached `tools/list`. Choose `/mcp/maintenance` explicitly when the client needs maintenance tools.

## Project Structure

The GraphMem project follows a standard Rails application structure with a few additions:

```
.
├── app/
│   ├── controllers/      # API controllers
│   ├── models/           # ActiveRecord models
│   ├── resources/        # MCP resources
│   ├── serializers/      # JSON serializers
│   └── tools/            # MCP tools
├── bin/                  # Scripts and utilities
├── config/
│   ├── initializers/
│   │   ├── mcp.rb        # MCP middleware (access gate, request context, router)
│   │   └── ...           # See lib/graph_mem/official_mcp for the SDK adapter
│   └── ...
├── db/
│   ├── migrate/          # Database migrations
│   └── structure.sql     # Current MariaDB schema definition
├── docs/                 # Documentation files
├── lib/
│   └── graph_mem/        # Core library code
└── spec/                 # Tests
```


## Code Style Guidelines

GraphMem follows the [Ruby Style Guide](https://github.com/rubocop/ruby-style-guide) with a few customizations. We use RuboCop to enforce these guidelines.

### Key Style Points

* Use 2 spaces for indentation (not tabs)
* Use snake_case for methods and variables
* Use CamelCase for classes and modules
* Keep lines under 100 characters
* Write descriptive method and variable names
* Include documentation for public methods

To check your code against our style guidelines:

```bash
bundle exec rubocop
```

To automatically fix issues:

```bash
bundle exec rubocop -a
```


## Running Tests

GraphMem uses RSpec for testing. To run all tests:

```bash
bundle exec rspec
```

The suite needs a MariaDB 11.8+ server (see [Prerequisites](#prerequisites)). On an older
server the boot succeeds but any spec touching embeddings or vector search fails.

### Membership drift guard

An entity's `project_id` is derived from its `part_of` parent chain (see
[architecture](architecture.md#project-membership-1931-1932-1933)).
`spec/support/membership_drift_guard.rb` fails an example that leaves the graph drifted, so a writer
that changes a `part_of` edge without syncing the child can't pass the suite.

- **What it checks:** `ProjectIdBackfill.drift`, the same report the backfill prints. The example
  fails when an entity's `project_id` differs from what its `part_of` chain gives (`wrong_project`,
  `stamped_without_path`, `path_without_stamp`), when two Project roots reach one entity, or when an
  entity has two `part_of` parents. The failure message lists the offending entities by kind.
- **When it runs:** after every example except system specs, inside the example's fixture
  transaction (before the rollback, so it sees the example's rows). It records the failure on the
  example instead of raising, so the rollback still happens. On a graph with no `part_of` edge and no
  `project_id` it costs one query; the whole suite pays about 2%.
- **Build consistent data with `fs_member!`.** `fs_member!(parent, "SynthWidget")`
  (`spec/support/fact_supersede_helpers.rb`) creates the `part_of` edge to `parent` (a Project root or
  any entity) and then runs `ProjectMembership.sync!`, so the member's `project_id` is what its chain
  gives. It also takes an existing entity in place of a name, and returns the member reloaded. Do not
  stamp `project_id` by hand or create a `part_of` edge without a sync.

  ```ruby
  alpha  = fs_project!("Alpha Service")
  widget = fs_member!(alpha, "SynthWidget")
  gadget = fs_member!(widget, "SynthGadget", "Class")
  ```
- **Opting out:** tag the example (or group) `membership_drift: :allowed`, with a one-line comment
  saying why, only when the drift is the point of the example (a repair spec that builds two parents
  on purpose, a refused repair, an entity found through a `part_of` that was never synced).

### Embedding lock guard

The membership lock (`ProjectMembership.with_membership_lock`) is never held across a network call (see
[architecture](architecture.md#project-membership-1931-1932-1933)). `spec/support/embedding_lock_guard.rb`
fails an example that calls the embedding service while its thread holds the lock, so a path that embeds
under it can't pass the suite.

- **What it checks:** every public embedding call of `EmbeddingService` (`embed`, `embed!`,
  `embed_entity`, `embed_observation` and the two binary forms; the class-level API delegates to them).
  The check runs before `vector_enabled?`, so it also sees the many specs that run with vectors off, and
  it sees both the real client and the `:with_test_embeddings` stub (which stubs below it, at the private
  `embed_with_retries`). The thread's lock state is `ProjectMembership.membership_lock_held?`.
- **How it fails:** the call raises, but the models' embedding callbacks rescue their own errors, so the
  attempt is also recorded and an `after` hook fails the example. The message names the method, the
  nearest repo frames that made the call (not the embedding plumbing) and the fix: defer the inline
  embedding (the models' callbacks do it under the lock), suppress it on a bulk path
  (`EmbeddingService.suppress_inline_embeddings`) and enqueue the backfill after the commit, or move the
  call before or after the lock.
- **No opt-out:** no tag turns it off. A spec that stubs `embed`, `embed!` or `embed_entity` itself
  replaces the check with its stub and bypasses it, so a spec on a lock path uses
  `:with_test_embeddings` and `record_embedding_calls!` instead:

  ```ruby
  it "embeds a new entity after the lock", :with_test_embeddings do
    calls = record_embedding_calls!
    ProjectMembership.with_membership_lock do
      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    end
    expect(calls.sole).to include(text: "Component: SynthWidget", held: false, lock_free: true)
  end
  ```

  `record_embedding_calls!` answers each call with a deterministic vector and records its text, whether
  this thread held the lock (`held`) and whether MariaDB showed the lock free (`lock_free`).
- **Doubles:** a double standing in for `ImportObservationDuplicateDetector` must answer `precompute!`
  and `fallback_warning`, which `ImportExecutionStrategy` calls around the lock.
- **Fixing a failure:** a new write path that creates or edits rows under the lock needs nothing
  special, the models defer. A new explicit embedding call (a service, a job step) moves outside the
  lock block.

### Vector index specs

`spec/db/vector_index_explain_spec.rb` and `spec/db/vector_index_recall_spec.rb` (step 1 of the
[MariaDB vector search plan](plans/mariadb-vector-search-plan.md)) run on a clustered fixture of 1,000
entities and 1,000 observations, from the bench's generator (`GraphMem::VectorBench::Fixture`, below).
The shared context `vector index fixture` (`spec/support/vector_index_fixture.rb`) seeds it once per
group inside a group-level transaction (`pin_connection!`, the call the fixture transactions use), so
every example's own transaction nests as a savepoint and `after(:all)` rolls the rows back, vector index
included; it then checks the memory tables are empty again. The group is skipped below MariaDB 11.8.

- **EXPLAIN shapes:** each example runs a real vector query site and checks whether its EXPLAIN shows
  `idx_memory_entities_embedding` / `idx_memory_observations_embedding`. Today none does; a control
  example checks the raw `ORDER BY VEC_DISTANCE_COSINE(...) LIMIT n` shape does. Steps 2 and 3 flip the
  examples of the queries they change.
- **Recall:** recall@10 of the raw index shape against exact, one probe per cluster and table. The
  index's graph differs from run to run on the same rows, so the asserted floor sits under the lowest
  measured run, and the plan's bar (Decision 4) is a skipped example until step 2 clears it (not `pending`: a run that happened to clear it would fail the suite).
- **Filter hazard:** with a one-type filter the index returns fewer rows than exact, which is why
  filtered searches stay exact scans.

## Vector index bench

`bin/rails graph_mem:vector_bench` measures vector search and write cost on synthetic rows, for the
PR bodies of the [MariaDB vector search plan](plans/mariadb-vector-search-plan.md). It's opt-in and run
by hand, never in CI. It creates its own scratch database (`graph_mem_vector_bench`), loads
`db/structure.sql` into it, installs the VECTOR KEYs and triggers through `EmbeddingIndexManager` (as
`embeddings:add_indexes` does) and drops it at the end. It refuses production, any database named in
`config/database.yml`, a name without the `_vector_bench` suffix and an existing database it didn't
make. It never connects to the configured database, never calls the embedding endpoint, and keeps the
SQL log off while it runs.

```bash
RAILS_ENV=test bin/rails graph_mem:vector_bench ROWS=50000 > tmp/vector_bench_50k.md
```

| Variable | Default | Meaning |
|---|---|---|
| `ROWS` | 10000 | entities |
| `OBSERVATIONS` | `ROWS` | observations, each on an entity of its own cluster |
| `CLUSTERS` | 50 | vector clusters |
| `PROBES` | 20 | timed queries per channel (and recall probes per table) |
| `WRITES` | 500 | single-row writes per table, with and without the VECTOR KEYs |
| `K` | 10 | recall@K |
| `SEED` | 1 | the generator's seed |
| `DB` | `graph_mem_vector_bench` | another `<name>_vector_bench` scratch database |
| `KEEP_DB` | off | `1` keeps the database at the end (the next run drops it) |

The data (`GraphMem::VectorBench::Fixture`): 768-d unit vectors, each a shared direction plus a cluster
center plus noise, so two members of a cluster sit at a cosine distance of about 0.3 and two clusters at
about 0.6 (tie-heavy: a probe's top 10 sit within a few hundredths); 5% zero-vector placeholders;
generic names (`SynthEntity123`, `SynthFact123`); 10 types drawn independently of the cluster. The
Markdown it prints has three parts:

- **Search latency**, p50/p95 per channel: today's exact queries (`VectorSearchStrategy#search` with and
  without a type, `#search_observations`, `suggest_merges`' per-entity query,
  `EntityMergeEvidence.candidates_for`) and the raw index shape, with whether EXPLAIN shows the index;
- **Recall@K** of the raw index shape against exact, and the rows a one-type filter keeps;
- **Write cost**: single-row INSERTs and embedding UPDATEs (`EmbeddingService#store_vector`'s
  statement), rows/s and p50/p95, with the VECTOR KEYs and again after `EmbeddingIndexManager.drop_indexes!`.

It loads the local MariaDB server for the length of the run (on one workstation: 10k rows about 45 s,
50k rows about 5.5 min; 200k rows would take well over 20 min), so run it when nothing else needs the
server.

## MCP Access Control in Development

All MCP profile paths are governed by the same `GRAPH_MEM_MCP_TOKEN` and
`GRAPH_MEM_MCP_ALLOWED_IPS`; see [mcp_access_control.md](mcp_access_control.md).
Profiles reduce tool visibility but are not authorization boundaries. Neither access-control
variable is needed for local work -- the defaults allow unauthenticated access from loopback
and private ranges. The active posture is logged once at boot:

```
[McpAccessPolicy] /mcp access: no token (unauthenticated), 7 allowed range(s)
```

To exercise the authenticated path locally, export a token and send it as a bearer header:

```bash
GRAPH_MEM_MCP_TOKEN=dev-token bin/rails server -p 3030

curl -s -X POST http://localhost:3030/mcp \
  -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -H "X-MCP-Client: curl-dev" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}'
```

Without the header the same request returns `401` with `WWW-Authenticate: Bearer`. A `403`
means the client IP fell outside the allowlist, or `Origin` validation failed -- note that
`Origin` falls back to `request.host`, so requests must target `localhost` or an allowed
hostname.

## MCP Tool Usage Telemetry

Every validated MCP tool attempt records one row in `tool_invocations`, including the tool and
client names, outcome, error category, duration, result size, scope, and the incoming top-level
argument **keys**. Argument values are never stored. Telemetry persistence is fail-open: a
database write failure is logged but never changes the tool result or replaces the original
exception.

Report the last 30 days:

```bash
bundle exec rake graph_mem:tool_usage
```

Use `DAYS=7` for a shorter window or `DAYS=all` for all recorded history. The report includes
every currently registered tool, so tools with zero calls are visible alongside call share,
error rate and categories, and p50/p95 duration.

Signed-in operators can inspect the same data at `/system/telemetry`, with
time-series, client/error/signature breakdowns, filters, and paginated raw
invocations. The default retention is 90 days and is configurable under
**System › Settings › Telemetry**; daily garbage collection prunes expired rows.
See [`docs/operator/telemetry.md`](operator/telemetry.md).


## Pull Request Workflow

1. **Fork the Repository**: Create your own fork of the project

2. **Create a Feature Branch**:

```bash
git checkout -b feature/my-new-feature
```

3. **Make Your Changes**: Implement your feature or bug fix

4. **Write Tests**: Add tests for your changes

5. **Check Style**:

```bash
bundle exec rubocop
```

6. **Run Tests**:

```bash
bundle exec rspec
```

7. **Commit Your Changes**:

```bash
git commit -am "Add new feature: description"
```

8. **Push to Your Fork**:

```bash
git push origin feature/my-new-feature
```

9. **Create a Pull Request**: Through the GitHub interface

## Code Review Process

1. All code changes must be submitted via pull requests
2. At least one core maintainer must review and approve changes
3. All tests must pass
4. Code must comply with style guidelines
5. Documentation must be updated to reflect changes


## Versioning

GraphMem follows [Semantic Versioning](https://semver.org/):

* **MAJOR** version for incompatible API changes
* **MINOR** version for new functionality in a backwards compatible manner
* **PATCH** version for backwards compatible bug fixes

The current version is stored in `lib/graph_mem/version.rb`.

**Release check (manual, not CI):** before each release, run `skills-ref validate`
(from `agentskills/agentskills`, the `skills-ref` package) on `skills/graph-mem-mcp-toolset`
and `skills/project-scan`, and paste the output in the release PR. Run it only in a
throwaway venv outside the repo, on temporary copies of the two folders (`cp -rL`), so no
venv, `pip` cache or validator output lands in the working tree. Expected: the first is
valid; the second reports only `triggers` and `disable-model-invocation` as unexpected
fields (documented in `docs/rules/README.md`). After bumping `lib/graph_mem/version.rb`,
run `bin/rails graph_mem:sync_skill_version` to copy the version into `metadata.graph-mem-version`
of `skills/graph-mem-mcp-toolset/SKILL.md`; that file is static Markdown read by agents, so it
can't reference `GraphMem::VERSION` itself (`spec/docs/agent_text_sync_spec.rb` checks they match).

## Additional Resources

* [Ruby on Rails Guides](https://guides.rubyonrails.org/)
* [Official MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk)
* [Migrating a Rails app from fast-mcp to the `mcp` gem](guides/migrating-fast-mcp-to-mcp-gem.md)
* [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)


## Getting Help

If you encounter issues or have questions:

1. Check the documentation in the `/docs` directory
2. Look for existing issues in the issue tracker
3. Create a new issue with:
   * A clear title and description
   * Steps to reproduce the issue
   * Expected and actual behavior
   * Any error messages or logs
   * Your environment details (Ruby version, Rails version, etc.)


## License

By contributing to GraphMem, you agree that your contributions will be licensed under the project's [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).