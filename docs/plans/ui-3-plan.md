# UI-3 → graph_mem 1.60.0: Search (one page, every mode, filters shared with the MCP `search` tool, "Show as graph")

**Written 2026-10-28 (Europe/Rome), revised the same day with Steve's decisions** for Claude, from `main` at `487804e`
(1.59.0 tagged, #134 merged). Every file:line in "What the code looks like today" was checked against that commit.
If a line has moved, find the code by the quoted text; if the code no longer matches the description, **stop and ask
Steve** instead of improvising. Only code was read while writing this plan. **No spec was run**: the PR is checked by
running the suite locally and by CI (CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-3 [Claude]: Search → 1.60.0"** and §2.3
(Search) and wins where the two differ. Scope: one Search page for the operator and the guest, all modes, filters in
the URL, results with snippets, a read-only entity panel, "Show as graph", and a `GraphSearch` service extracted from
`SearchTool#call` so the page and agents get the same results. **Decided Oct 28 by Steve** (below): one PR; the page
ignores agents' context; project, type and "match in" become real filters of the MCP tool and the REST search
endpoint; "Show as graph" ships here. Earlier decisions stay: the guest is read-only and server-side enforced (§0.2
decisions 1 and 8, §2.1), guest searches are throttled (60/min per IP, 300/min across all guests), and **with the new
arguments omitted, ranking and output don't change**.

## Brief

| | |
|---|---|
| **Branch / PR** | **One PR** (Steve, Oct 28): branch `claude/ui-3-search` off the latest `main`, title `Search (1.60.0)`. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | **S1** characterization spec (today's tool), **S2** `GraphSearch` extraction, **S3** page retrieval options · **F1** `SearchFilter`, **F2** filters in every channel, **F3** tool + REST arguments, snapshots re-recorded, **F4** filter specs · **P1** page query, **P2** controller, **P3** views + highlight helper + CSS, **P4** entity panel, **P5** Stimulus, **P6** "Show as graph", **P7** specs, **P8** docs and folded items · **R** release. Push after each checkpoint (see "Size"); review fixes go in new commits; no force-push after review starts. |
| **Scope** | §2.3 and §6 UI-3, plus Steve's Oct 28 decisions. **Agent-visible change, intended:** the `search` tool gains `project_id` and `entity_types`, its `search_in_*` flags start applying in summary mode too, and its description changes; the three `tools/list` snapshots are re-recorded (F3). The REST search endpoint gains the same filters. No migration, no new embedding call, no write endpoint, no change to `GuestSearchThrottle`'s limits. |
| **Data** | Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Gadget Project`, temp dirs). Never real data, real credentials or a production dump. Specs must not reach a real embedding service: stub `EmbeddingService` / `VectorSearchStrategy` (the outbound HTTP guard fails any example that tries). |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (spec hygiene, test-DB truncate, done criteria), §2.1, §2.3, §2.4, §5.4, §6 UI-4b; `docs/mcp_access_control.md` (guest section); `docs/mcp_tools.md` (`search`); `docs/development.md:127` (snapshots); `spec/tools/search_tool_spec.rb`. |

## What the code looks like today (verified at `487804e`; no code changed since `07edfbf`)

- **Route and controller.** `config/routes.rb:105` `get "search", to: "search#results"` (the only HTML search route;
  there is no `index`). `app/controllers/search_controller.rb` (69 lines): `include GuestSearchThrottle` (4),
  `allow_guest :results` (6), `throttle_guest_search :results` (7), `RESULTS_PER_PAGE = 25` (9); `results` (11-30)
  reads `q` and `strategy` (`text`|`vector`, 13), blank query → empty page (16-20), paginates with
  `Kaminari.paginate_array` (23) and counts `part_of` children per row (25-29); `text_search` (42-44) is plain
  `EntitySearchStrategy`; `perform_search` (34-40) picks one; `vector_search` (46-68) is the private vector-merge code §2.3 says to delete. **The page
  doesn't use the ranking agents get**: it never calls `EntityRetrievalService`/`HybridSearchStrategy`.
- **Views.** `app/views/search/_form.html.haml` (14 lines: `q`, radio `strategy` text/vector, disabled vector hint) and
  `results.html.haml` (40 lines: old-style table, name links to `graph_path(scoped_entity_id:)` at 30, "Scope" column
  at 25, default Kaminari `paginate` at 38). `app/views/pages/graph.html.haml:6` **also renders `search/_form`**.
  Styles: 35 `search-*` rules in `app/assets/stylesheets/graph.css` (from 723). There is no `app/views/kaminari/`.
- **Other entry points.** Home's quick search `app/views/pages/home.html.haml:9` (`form_with url: search_path`, `q`).
  Sidebar `app/views/ui/_sidebar.html.haml:19` (`nav-search`); a guest's brand link and `/` go to `/search`
  (`_sidebar.html.haml:9`, `pages_controller.rb:9`). `/graph` (`PagesController#graph`, 31-33; `allow_guest :home,
  :graph` at 4) reads only `?scoped_entity_id=` (`app/javascript/controllers/graph_controller.js:34-35`); it takes no
  id list. There is no `EntitiesController`, no `app/views/entities/` and no `app/views/explore/` yet.
- **The MCP tool.** `app/tools/search_tool.rb` (225 lines): arguments (37-52), `call` (54-109: paging 58, projections 59,
  temporal window 60, perspective check 61-64, `max_tokens` 65, catalog mode 67-75, blank query 76, subgraph vs
  summary 78-101, error mapping 102-108), `normalized_paging` (113-123, `MAX_PER_PAGE = 100`), `summary_result`
  (136-201: `EntityRetrievalService.search(query, limit: offset + per_page, semantic: true, context_entity_ids:,
  context_scope:, temporal_window:, perspective:)` at 139-149, then `drop(offset).first(per_page)` at 150 and the token
  budget 154-193), `subgraph_result` (203-214, `SubgraphSearchService.call`), `build_temporal_window` (216-224). The
  context comes from `graph_mem_context.scoped_entity_scope` (137, 206), i.e. the caller's `X-MCP-Client` bucket
  (`app/tools/application_tool.rb:110-120`); when that bucket is empty the tool passes nil and gets the line-11
  fallback below.
- **Retrieval.** `app/services/entity_retrieval_service.rb` (59 lines): `search` (6-57). **Line 11 falls back to the
  ambient `GraphMemContext.scoped_entity_scope`** (the `"default"` client bucket, `app/models/graph_mem_context.rb:44-46`)
  when no context is passed, so any caller without an explicit context is boosted by whatever an agent without an
  `X-MCP-Client` header last set. REST `api/v1/memory_entities_controller.rb#search` (98-128) passes that bucket on
  purpose.
- **Hybrid strategy.** `app/strategies/hybrid_search_strategy.rb` (240 lines): `SearchResult#to_h` (10-26, includes
  `relevance_score` and `matched_fields`); `search` (45-108): text channel `EntitySearchStrategy` (56), entity vectors
  (58-62) and observation vectors (64-69, `scoped_ids` only narrow this channel), temporal channel (77-90), fusion +
  boosts, `.first(limit)` (100). `matched_fields` values: `name`, `aliases`, `entity_type`
  (`entity_search_strategy.rb:131-153`), `semantic`, `observation_semantic`, `temporal` (135, 148, 161). Boosts
  (`apply_relevance_boosts` 174, `apply_structural_boost` 213) are per entity (name match, type priority, relation
  counts, context), but the RRF
  ranks depend on each channel's `limit * 2` cut, so **two calls with different `limit`s can order their common top
  differently**. Parity therefore means "same arguments, same `limit`".
- **Vectors.** `VectorSearchStrategy#search` (24-28) returns `[]` unless `EmbeddingService.vector_enabled?` (a cached
  "DB has VECTOR columns" check, `embedding_service.rb:35-42`), then embeds the query; `search_observations` (52-)
  embeds it again, active observations only (70), perspective filter (72). `EmbeddingService#request_embedding` uses
  `open_timeout = 10`, `read_timeout = 30` (308-309) and `MAX_RETRIES = 3` (10). With the service refused
  (`OLLAMA_URL=http://127.0.0.1:9`) this fails fast; with a black-holed host, any semantic search is slow. That's the
  case today for the tool too, and this plan doesn't change it.
- **Observation ranking.** `ObservationRankingService.rank` (`observation_ranking_service.rb:8`): `trust` (no
  embedding) or `relevance`, which builds an `ObservationRelevanceRanker` that **embeds the query**
  (`observation_relevance_ranker.rb:9-14, 33-40`). `MemoryObservation`: statuses incl. `obsolete`/`superseded` (8-9),
  `PERSPECTIVES = %w[world experience]` (16), `scope :active` (33). Projects are `MemoryEntity` rows of type `Project`
  with `project_id` NULL (`memory_entity.rb:21-55`).
- **Guest throttle.** `app/controllers/concerns/guest_search_throttle.rb`: `LIMIT = 60`, `GLOBAL_LIMIT = LIMIT * 5`,
  `PERIOD = 1.minute` (18-20), `QUERY_GATED_ACTIONS = %w[show]` (23, `memory_entities#show` counts only with
  `?query=`), the two `rate_limit`s (27-33; the global one keyed on `session[:guest_cred_fp]`), 429 page/JSON (45-52).
  Applied to `SearchController#results` (7), `api/v1/memory_entities_controller.rb:11` (`:search, :show`) and
  `api/v1/search_controller.rb:8` (`:subgraph`). The throttled page (`app/views/shared/guest_search_throttled.html.haml`,
  `ui.en.yml:41-43`) mentions only the per-IP limit.
- **Guest rules.** `RoleAuthorization.allow_guest` (`role_authorization.rb:25`); `can_write?` (`ui_helper.rb:16`).
  `spec/requests/role_matrix_spec.rb` `guest_allowed` (12-21: `GET /search` 200, `GET /graph` 200, …) and the walk
  (106-118: a route not in the table must 403 for a guest).
- **Review link target.** `/review?q=` searches active rows (`review_controller.rb:20-21`, `load_search` 141-145).
- **Docs.** Guest search budget: `README.md:573`, `docs/mcp_access_control.md:259-264`,
  `docs/guides/ui-guide.md:202, 232`. None says that **one guest can use up the shared 300/min budget for every
  guest** (deferred note from the UI-1b review).
- **Specs.** `spec/tools/search_tool_spec.rb` (249 lines), `spec/services/entity_retrieval_service_spec.rb` (101),
  `spec/services/subgraph_search_service_spec.rb` (252), `spec/requests/guest_search_throttle_spec.rb`,
  `spec/mcp/tools_list_snapshot_spec.rb`. **No HTML request spec for `/search`** exists; it's covered only by the role
  matrix, the throttle spec and the CSP specs (`spec/requests/content_security_policy_spec.rb:33`,
  `spec/system/content_security_policy_spec.rb:29, 58`, visiting `/search?q=SynthWidget`), plus
  `spec/system/home_spec.rb:67`, `navigation_spec.rb:152` and `spec/requests/pages_spec.rb:45` (Home's only form
  posts to `search_path`). `spec/system/escaping_spec.rb` has no Search case.
- **System spec helper.** `spec/support/system.rb:16-20`: `wait_for_stimulus` builds its JS with `<<~JS`, an
  interpolating heredoc, so the `\s` in `split(/\s+/)` (18) reaches the browser as a plain space (deferred nit).
- **Version.** `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` at **1.59.0**; `CHANGELOG.md`
  starts at `## [1.59.0] - 2026-10-28` (no `## [Unreleased]`).
- **`search_in_*` today.** The four flags are declared with no description (`search_tool.rb:40-43`) and are passed
  **only to subgraph mode** (78-91); summary mode ignores them, and the tool description and `docs/mcp_tools.md:159`
  call them "subgraph" flags. In `SubgraphSearchService` they pick the lexical fields of `text_matching_ids` (153-172,
  observations via a LEFT JOIN on active rows); the vector merge (`merge_vector_ids`, 174-188) ignores them; all four
  off → `"At least one search field (name, type, aliases, observations) must be enabled."` (86-89).
- **No project or type filter anywhere.** `EntitySearchStrategy#fetch_candidate_entities` (87-99) is a bare
  `MemoryEntity.where(LIKE …)` over name/type/aliases; scoring (`calculate_entity_score`, ~118) weights
  `FIELD_WEIGHTS` (30-34). `VectorSearchStrategy#search` already takes a single `entity_type:` (24, 37) that no caller
  passes; `search_observations` (52-82) has no entity filter. `TemporalSearchStrategy#search` (18-31) takes
  `entity_ids:`. `HybridSearchStrategy` sorts the fused scores with `sort_by { -score }` (98-100), which isn't stable
  for equal scores.
- **The vector queries are exact scans.** The entity query filters with `HAVING vec_distance < 0.85` and orders by
  `(vec_distance + 0)` (`vector_search_strategy.rb:38-42`); the observation query groups by entity and orders by
  `MIN(VEC_DISTANCE_COSINE(…))` (58-78). Neither has the `ORDER BY VEC_DISTANCE_COSINE(col, const) LIMIT n` shape that
  MariaDB's `VECTOR KEY`s (`db/structure.sql:227, 280`) serve, so as written both read every embedded row. A `WHERE`
  on `project_id` / `entity_type` is therefore an exact pre-filter (no recall loss, fewer rows scanned).
- **REST search.** `GET /api/v1/memory_entities/search` (`config/routes.rb:24`;
  `api/v1/memory_entities_controller.rb:97-133`): `q`, `limit` (1-100, default 50), `semantic`, temporal params,
  `max_tokens`, `include_retrieval`; it **hard-filters** to the default bucket's context (`scope_entity_ids:`, 107),
  rescues only `ArgumentError` (133-134), and `GraphMem::InvalidArgumentsError` is a `StandardError`
  (`lib/graph_mem/invalid_arguments_error.rb:6`). It's guest-readable (`ApiAuthentication::GUEST_READ_ACTIONS`,
  `api_authentication.rb:19-21`) and documented by the rswag spec `spec/requests/api/v1/memory_entities_spec.rb:312-`
  and the hand-kept `swagger/v1/swagger.yaml` (`searchMemoryEntities`, ~234) and `docs/api/rest_api_reference.md:74-76`.
- **Tool list snapshots.** `spec/mcp/tools_list_snapshot_spec.rb` compares `tools/list` key order and content with
  `spec/fixtures/mcp/snapshots/{default,readonly,maintenance}.json`; `search` is in all three (`default.json:611-`).
  `docs/development.md:127` says to re-record on an intended change and say so in the PR. Agent docs: `docs/mcp_tools.md:151-170`,
  `skills/graph-mem-mcp-toolset/SKILL.md:34-58` ("Recall: `search`, then `get_entities`").
- **Graph canvas.** `/graph` (`PagesController#graph`) boots `graph_controller.js` (193 lines), which reads only
  `?scoped_entity_id=` (34-42) and loads `GET /api/v1/graph_data` through `graph/api_client.js:13-30`.
  `Api::V1::GraphDataController#index` (108 lines, 7-21) branches on `scoped_entity_id` / `entity_id` / `root_only`
  / full graph and renders Cytoscape JSON via `render_graph_data` (71-); it's guest-readable (`GUEST_READ_ACTIONS`).
  `POST /api/v1/search/subgraph_by_ids` (`api/v1/search_controller.rb:83-94`) returns entities + relations for an
  id list in a different (non-Cytoscape) format.
- **UI-4b** (`ui-dashboard-plan.md` §6 UI-4b, §2.4): rewrites `graph_controller.js` into `explore_controller.js`,
  adds `ExploreController#show` with a toolbar scope picker that includes **"from search"**, and **deletes the
  `/graph` page and its search form**. §2.3 planned "Show as graph" as `/explore?ids=…` via `SubgraphSearchService`.


## Steps

### S1. Characterization spec first (today's tool, before any change)
- New `spec/services/graph_search_spec.rb`, written and green **against the unchanged `SearchTool#call`**: on a
  synthetic graph (entities with aliases, observations in both perspectives, dated facts, two Project roots with
  members, a few relations), hard-code the expected `entity_id` order and envelope keys for: catalog mode; summary
  pages 1–2 at `per_page` 5 and 20; a temporal phrase in the query ("in October 2026"); `occurred_after`; `as_of`;
  `perspective`; `max_tokens`; subgraph mode with each `search_in_*` off; an active context; each
  `InvalidArgumentsError` message. Stub `VectorSearchStrategy#search` / `#search_observations` with fixed synthetic
  results so the semantic channels take part without HTTP.
- Build the fixture so no two top results tie on fused score (`sort_by { -score }` isn't stable). This spec is the
  gate: **it must pass unchanged after every later commit**, which is what "with the new args omitted, results are
  identical to today's" means. (Comparing `GraphSearch` with `SearchTool` after S2 would be circular: the tool calls it.)

### S2. Extract `GraphSearch` from `SearchTool#call`
- New `app/services/graph_search.rb`: `GraphSearch.call(query:, include: [], page: nil, per_page: nil, limit: nil,
  search_in_name: true, search_in_type: true, search_in_aliases: true, search_in_observations: true,
  occurred_after: nil, occurred_before: nil, as_of: nil, max_tokens: nil, perspective: nil, context_scope:,
  logger: Rails.logger)` returns exactly the hash `SearchTool#call` returns today and raises the same messages. Move
  `normalized_paging`, `normalize_projections`, `summary_result`, `subgraph_result` and `build_temporal_window` with it
  (keep the file under ~300 lines; split the token-budget block into `graph_search/summary.rb` if needed).
- `SearchTool#call` keeps its signature, description, arguments, `mcp_metadata` and `rescue` mapping (102-108) and
  passes `graph_mem_context.scoped_entity_scope`. S1, `search_tool_spec.rb` and the snapshot spec stay green unchanged.

### S3. Two page-only retrieval options (defaults unchanged)
- `EntityRetrievalService.search(..., ambient_context: true)`: `false` skips the line-11 fallback (Decided 2).
- `HybridSearchStrategy#search(..., text: true)`: `false` skips the text channel (56), for the page's Semantic mode.
- `GraphSearch.call` passes both through. They are **not** tool or REST arguments.

### F1. `SearchFilter`: one value object for project, types and fields
- New `app/services/search_filter.rb`, `SearchFilter.build(project_id: nil, entity_types: nil, search_in_name: true,
  search_in_type: true, search_in_aliases: true, search_in_observations: true)`, frozen, with `#entity_scope` (a
  `MemoryEntity` relation, or `nil` when neither project nor types is set), `#fields`, `#default?` and
  `#diagnostic`. Built and validated once per request by `GraphSearch`, the REST controller and the page.
- **`project_id`** (integer ≥ 1): must be a Project root (`entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE`,
  `project_id` NULL); matches the root itself and its members (`id = :p OR project_id = :p`). Otherwise
  `GraphMem::InvalidArgumentsError`, `"project_id must be the id of a Project entity."`.
- **`entity_types`** (array of strings): stripped, de-duplicated, 1–20 items of 1–100 characters; exact match on
  `entity_type` (DB collation, so case-insensitive); an unknown type simply matches nothing. Otherwise
  `"entity_types must be a list of 1 to 20 non-blank entity types."`. An empty array is the same as omitting it.
- **`search_in_*`**: all four `false` → the existing message, `"At least one search field (name, type, aliases,
  observations) must be enabled."`, now in summary mode too.
- Omitted arguments = `SearchFilter.build` defaults = `#default?` true = every channel runs exactly as today.

### F2. Apply the filter inside every channel (before ranking)
- **Text** (`EntitySearchStrategy#search(query, limit:, fields: %i[name entity_type aliases], scope: nil)`): the
  `LIKE` `WHERE` (87-99) is built only from the enabled fields and `merge`d with `scope`; `calculate_entity_score`
  counts only enabled fields. Not called when name, type and aliases are all off.
- **Entity vectors** (`VectorSearchStrategy#search(..., scope: nil)`): `merge(scope)` before the distance select. Runs
  unless name, type and aliases are all off (the entity embedding is built from type, name, aliases and description,
  `EmbeddingService#compose_entity_text`, `embedding_service.rb:289-295`). Keep `entity_type:` working.
- **Observation vectors** (`search_observations(..., scope: nil)`): join `memory_entities` and `merge(scope)`. Runs only
  when `search_in_observations`.
- Because both vector queries are exact scans today (see above), these `WHERE`s are true pre-filters: no recall
  loss, fewer rows read. **Check with `EXPLAIN` in development** that neither query uses the `VECTOR KEY`; if one
  does, the filter would apply around the index walk and could return fewer than `limit` rows (stop and ask).
- **Temporal** (`TemporalSearchStrategy#search(..., scope: nil)`): `memory_entity_id IN (scope.select(:id))`. The
  non-temporal-only path already ranks only the (now filtered) candidates; the temporal-only path and
  `EntityRetrievalService`'s fallback (28-43) pass `scope`.
- **Boosts** (name match, type priority, structure, context) are unchanged: they reorder candidates, never add them.
- **Subgraph** (`SubgraphSearchService`): takes `filter:`; `text_matching_ids` merges `entity_scope`; `merge_vector_ids`
  passes `scope:`; `temporal_candidate_ids` passes it too; the `search_in_*` handling stays as today.
- `EntityRetrievalService.search(..., filter: nil)` → `HybridSearchStrategy#search(..., filter: nil)`; `nil` is
  today's code path. Add `retrieval.filters` (`{ project_id:, entity_types:, search_in: [...] }`) **only when the
  filter isn't default**, so omitted arguments keep today's envelope byte for byte.

### F3. MCP tool and REST arguments; snapshots re-recorded on purpose
- **Tool** (`search_tool.rb` `arguments`, after `search_in_observations`):
  `optional(:project_id).filled(:integer).description("Only entities in this Project (the Project entity itself and its members).")`
  and `optional(:entity_types).array(:string).description("Only entities of these types (1-20, exact, case-insensitive).")`;
  give the four flags descriptions: `"Match the query against entity names (default true; summary and subgraph modes)."`
  and the same for types, aliases and observations.
- **Description**: replace `subgraph \`search_in_name\`, \`search_in_type\`, \`search_in_aliases\`,
  \`search_in_observations\` flags` with `` `search_in_name`, `search_in_type`, `search_in_aliases`,
  `search_in_observations` flags (which fields the query matches, both modes), `project_id` and `entity_types`
  filters (applied before ranking) ``. Nothing else in the description changes.
- **Combining:** filters apply before ranking in every mode, so `page`/`per_page` page through the filtered ranking
  (`limit: offset + per_page` as today), `perspective` stays an independent observation filter, the temporal window
  ranks/filters within the filtered candidates, and `max_tokens` packs the filtered page. **Catalog mode** (no
  `query`) with `project_id` or `entity_types` → `"project_id and entity_types require a query."` (a new check after
  the existing one, whose message stays unchanged).
- **`tools/list` snapshots change, intentionally:** in `spec/fixtures/mcp/snapshots/default.json`, `readonly.json` and
  `maintenance.json`, the `search` entry only: (1) the description text above; (2) `inputSchema.properties` gains
  `project_id` (`{"type": "integer", "not": {"type": "null"}, "description": …}`) and `entity_types`
  (`{"type": "array", "items": {"type": "string"}, "description": …}`) right after `search_in_observations`; (3) the
  four `search_in_*` properties gain `description`. No other tool, prompt or template changes. Re-record per
  `docs/development.md:127`, diff the JSON, and say so in the PR body.
- **REST** `GET /api/v1/memory_entities/search`: `project_id`, `entity_types[]=` (or a comma-separated
  `entity_types=`), `search_in_name|type|aliases|observations=false`; built with `SearchFilter.build`, passed as
  `filter:`; it keeps its own context hard-filter (the two intersect). Add `rescue GraphMem::InvalidArgumentsError =>
  e` → `render_error(e.message)` (422). Without the new params the response is unchanged. Update the rswag spec
  parameters, `swagger/v1/swagger.yaml` and `docs/api/rest_api_reference.md`. `GET /api/v1/search/subgraph` is out of
  scope (it can adopt `filter:` later in one line).

### F4. Filter specs
- `spec/services/search_filter_spec.rb`: every validation message; normalisation; `default?`; the scope matches the
  root and members only.
- `spec/services/graph_search_spec.rb` (extends S1, whose examples stay untouched): explicit default flags equal
  omitted ones; each filter alone and combined, in summary and subgraph modes, with paging (page 2 of a filtered
  search), perspective, a temporal window, a temporal-only query, the temporal fallback and `max_tokens`;
  `search_in_observations` only → no text or entity-vector channel (stub expectations), names only → no observation
  channel; catalog + filter → error; `retrieval.filters` only when set.
- `spec/strategies/*`: `fields:`/`scope:` on `EntitySearchStrategy`, `scope:` on both vector queries (assert the SQL
  scope with stubs) and on `TemporalSearchStrategy`.
- `spec/tools/search_tool_spec.rb`: **existing examples unchanged**; add examples for the new arguments and errors.
- `spec/requests/api/v1/memory_entities_spec.rb`: the filters, 422s, unchanged output without them; guest still 200.
- `spec/mcp/tools_list_snapshot_spec.rb`: unchanged code, re-recorded fixtures.

### P1. The page query: `GraphSearch::Page`
- New `app/services/graph_search/page.rb`, `GraphSearch::Page.call(params, per_page: 20)` → `rows`, `page`,
  `next_page?` (the page is full; no total), `mode`, `filters`, `error`. Each row: entity, `relevance_score`,
  `matched_fields`, up to 2 snippets, project name, relation count.
- **Modes:** `auto` (default) = `GraphSearch.call` summary mode; `text` = the same with `semantic: false` (no
  embedding call); `semantic` = `text: false`, **disabled with a reason** when `EmbeddingService.vector_enabled?` is
  false; `exact` = name equal to `q` or a whole alias equal to `q` (split as `EntitySearchStrategy` does), within
  `SearchFilter#entity_scope`, ordered by name, no ranking call. Legacy `strategy=text` → `text`, `strategy=vector` →
  `semantic`. Unknown values → `auto`.
- **All filters are tool arguments now:** `project_id`, `types[]` → `entity_types`, `match[]` (`name`, `aliases`,
  `type`, `observations`) → `search_in_*` (all on = omitted), `perspective`, `occurred_after`, `occurred_before`,
  `as_of`. The page calls `GraphSearch.call(..., context_scope: nil, ambient_context: false)` with the tool's own
  `page`/`per_page`, so **page N of the page is page N of the tool for the same arguments, with or without filters**
  (no candidate cap). Errors from `SearchFilter`/temporal parsing are shown inline with status 422.
- **`include_obsolete`** affects only snippets and the panel. Default off.
- **Snippets:** one query over `memory_observations` for the page's entity ids (active unless `include_obsolete`,
  `perspective` applied), matching any `QueryTokenizer.tokenize` token with `LIKE`, top 2 per entity by
  `QueryTokenizer.overlap_score` then trust. **No embedding call** (never `ObservationRankingService.rank(mode:
  "relevance")`). No snippet → show the description.
- **Breadcrumb and counts:** project names in one query; relation counts with two grouped counts. No per-row queries.
- Project chip options: one query for Project roots; type options: `distinct.pluck(:entity_type)` capped at 50.

### P2. Controller and routes
- `SearchController#results` (same `/search` route) becomes a thin adapter around `GraphSearch::Page`; permit `q mode
  strategy project_id perspective occurred_after occurred_before as_of include_obsolete page`, `types: []`,
  `match: []`. Delete `perform_search`, `text_search`, `vector_search` (34-68) and `RESULTS_PER_PAGE`. Keep `include
  GuestSearchThrottle`, `allow_guest :results` and `throttle_guest_search :results` exactly. Blank `q` → empty page.
- No `index` action (`/search` serves both states). If you add one, guest-allow and throttle it the same way and add
  it to the role matrix.

### P3. Views, highlight helper, CSS
- `search/results.html.haml` rewritten in the UI shell, with `_filters` (one GET form: query, mode radios, chips; all
  state in the URL), `_result` (name → panel link, type badge, breadcrumb, score + matched fields, relation count,
  snippets, "Open in Explore" → `graph_path(scoped_entity_id:)`), `_snippet`. The panel sits beside the results in
  `turbo_frame_tag "entity-panel"`; result links carry `data: { turbo_frame: "entity-panel" }` and a real `href`.
- `SearchHelper#highlight_snippet(text, tokens)`: split the **raw** text on the escaped tokens (case-insensitive),
  `ERB::Util.html_escape` each segment, wrap matches in `<mark>`, join, mark safe; truncate around the first hit
  (~240 chars). The only `html_safe` in the PR; never match against escaped text.
- Keep `search/_form.html.haml` for `/graph` (its `strategy` radios still map); UI-4b deletes it with the page. New
  styles in `app/assets/tailwind/search.css` (`@layer components`, imported from `application.css` like `home.css`);
  leave the old `search-*` rules in `graph.css`. Strings in `config/locales/search.en.yml`.

### P4. Read-only entity panel
- `EntitiesController#panel` (`GET /entities/:id/panel`, `as: :entity_panel`), `allow_guest :panel`, in
  `turbo_frame_tag "entity-panel"` (layout only outside a frame request); 404 for an unknown id. UI-4b reuses it.
- Contents: name, type, aliases, description, breadcrumb; observations by **trust** (no embedding, nothing to
  throttle), first 10 active, "Show obsolete" and paging; relations both ways grouped by type, first 20 each, linking
  to their panels; "Open in Explore". **Operator only:** "Open in Review" → `review_path(q: entity.name)` behind
  `can_write?`. **No edit links or forms for anyone.**

### P5. Stimulus
- `app/javascript/controllers/search_controller.js`: submit the form on chip/mode change (`form.requestSubmit()`),
  keep the selected result highlighted, `/` focuses the query box. No `innerHTML`, inline handlers or dialogs; CSP
  stays enforced with zero violations.

### P6. "Show as graph" (the smallest change UI-4b can build on)
- **API:** `Api::V1::GraphDataController#index` gains an `ids` branch, checked first: `ids=1,2,3` (comma-separated),
  each a positive integer, de-duplicated, at most `MAX_IDS = 100`; anything else → 422 JSON
  `"ids must be 1 to 100 comma-separated entity ids."`. Renders the existing entities plus relations **among them**
  through `render_graph_data` (no hop expansion), with `focus_entity_ids` in the options; unknown ids are skipped.
  Same authentication and guest rules as today (`graph_data#index` is already a guest read).
- **Canvas:** `graph_controller.js` reads `?ids=` after `scoped_entity_id` (34-42) into a `'search'` view ("From
  search" label, Back to root), and `api_client.js#fetchGraphData` passes `ids`. ~30 lines of JS; no Cytoscape
  config change. `PagesController#graph` is unchanged (it already allows guests).
- **Button:** on the results page, "Show as graph" is a plain link to `graph_path(ids: rows.map(&:id).join(","))`
  for the current page (≤ 100 ids because `per_page` ≤ 100), hidden when there are no results. Guests see it too.
- **Overlap with UI-4b (noted in both plans):** UI-4b keeps the `ids` parameter name and the `graph_data?ids=` branch
  for Explore's "from search" scope; when it deletes `/graph` it redirects `/graph?…` to `/explore?…` with the query
  string and points this button at `explore_path(ids:)`. §2.3's "via `SubgraphSearchService`" is replaced by the
  `graph_data` branch, because the canvas needs the Cytoscape format.

### P7. Specs (page, panel, graph)
- `spec/services/graph_search/page_spec.rb`: **page = tool** (same ids and order as `SearchTool#call` with no context,
  pages 1–2, without and with each filter); modes (`text` makes no embedding call; `semantic` uses `text: false`;
  `exact` on name and alias); legacy `strategy`; `match[]` → flags; snippets (top 2, perspective, obsolete, one query,
  counted with `ActiveSupport::Notifications`); a `"default"` bucket context doesn't reorder.
- `spec/requests/search_spec.rb` (new): blank query, results, each mode, filters kept in the form and links,
  invalid temporal/filter args → 422 with the message, unknown `mode` → auto, vector-unavailable state, old
  `/search?q=&strategy=vector` links, escaping (`<b>Synth</b>Widget`, a `<script>synth()</script>` observation, a token
  `amp` on text with `&`), the "Show as graph" href, guest gets the same results.
- `spec/requests/entities_panel_spec.rb` (new): operator sees "Open in Review"; guest gets 200 with no "Open in Review",
  no `form`, no edit link; 404; obsolete toggle; signed out → login.
- `spec/requests/api/v1/graph_data_spec.rb`: `ids` (nodes, relations among them only, unknown ids skipped, 0/101/non-
  integer → 422, guest 200).
- `spec/requests/role_matrix_spec.rb`: add `"GET /entities/:id/panel" => 404` (dummy id) to `guest_allowed`.
- `spec/requests/guest_search_throttle_spec.rb`: the page still counts once; the panel and `graph_data` don't.
- `spec/system/search_spec.rb`: query → chip → result → panel → "Open in Explore"; "Show as graph" → `/graph?ids=`
  renders those nodes (read `cy` through the controller); no CSP violations. `spec/system/escaping_spec.rb`: a Search
  case. Existing CSP, Home and navigation system specs stay green.

### P8. Docs and folded items
- `docs/mcp_tools.md` `search` (new arguments, `search_in_*` in both modes, errors, `retrieval.filters`),
  `skills/graph-mem-mcp-toolset/SKILL.md` "Recall" section (one line: narrow with `project_id` / `entity_types`),
  `docs/api/rest_api_reference.md`, `docs/guides/ui-guide.md` Search section (modes, filters, panel, Show as graph,
  guest differences), `docs/architecture.md` (`GraphSearch` + `SearchFilter` shared by tool, REST and page).
- **Folded:** the guest budget note (in `docs/mcp_access_control.md` after 264 and `docs/guides/ui-guide.md` 202, 232:
  the 300/min is shared, so one busy guest can use it up for everyone until the minute passes); `spec/support/system.rb:16`
  → `<<~'JS'` so `/\s+/` reaches the browser intact (P7's system spec relies on `wait_for_stimulus`).
- **Not folded:** F-1 (`ui-dashboard-plan.md` §6.F) rides along only if Steve asks for it.

### R. Release 1.60.0
- `lib/graph_mem/version.rb`, `skills/graph-mem-mcp-toolset/SKILL.md` (18) → **1.60.0**; `CHANGELOG.md`
  `## [1.60.0] - <merge date>`: **Added** the Search page, the entity panel, "Show as graph", and "`search` tool and
  `GET /api/v1/memory_entities/search`: optional `project_id` and `entity_types` filters, applied before ranking";
  **Changed** "`search_in_*` now also apply in summary mode (default true; omitting them changes nothing)", "the
  search tool's logic moved to `GraphSearch`", and the guest budget docs note. Leave recorded-run version lines in
  `docs/protocol_compat.md` / `script/mcp_compat/README.md` alone.

## Specs (summary)

| Area | New / changed |
|---|---|
| Gate | `graph_search_spec.rb` S1 examples, written against today's tool and never edited afterwards; `search_tool_spec.rb` existing examples unchanged. |
| Filters | `search_filter_spec.rb`, `graph_search_spec.rb` (F4), strategy specs, `search_tool_spec.rb` (+new examples), `memory_entities_spec.rb` (REST), re-recorded `spec/fixtures/mcp/snapshots/*.json`. |
| Page | `graph_search/page_spec.rb`, `requests/search_spec.rb`, `requests/entities_panel_spec.rb`, `api/v1/graph_data_spec.rb`, `role_matrix_spec.rb` (+1), `guest_search_throttle_spec.rb` (+2), `system/search_spec.rb`, `system/escaping_spec.rb` (+1). |

## Size and split

**One PR, as Steve decided.** Honest estimate: **~4–5 days of work and a ~2,800-line diff** (about 1,200 of it
specs and re-recorded snapshot JSON): S1–S3 ~450 lines, F1–F4 ~900, P1–P5 ~1,200, P6 ~200, docs and release ~150.
That's about twice UI-2b and the largest PR in the series so far, so review will take longer. To keep it reviewable,
work in **checkpoints**, pushing the branch and getting CI green at each before going on:
1. after **S3**: extraction done, S1 gate green, no behaviour change;
2. after **F4**: the agent-visible change (tool + REST filters, snapshots re-recorded);
3. after **P5**: the page and panel;
4. after **P6–R**: "Show as graph", docs and release.
Steve may ask for the PR to be opened as a draft at checkpoint 2 so the tool change is reviewed early; it stays one PR.

## Decided Oct 28 by Steve

1. **One PR** for all of UI-3 on `claude/ui-3-search`, `Search (1.60.0)`; the extraction and its gate spec come first.
2. **The Search page ignores agents' active context** (`ambient_context: false`); the Project filter is the explicit
   way to narrow.
3. **Project, type and "match in" are real filters of the MCP tool and the REST search endpoint**, applied inside the
   query (not a post-filter), with the page using the same code. "Match in" reuses the existing `search_in_*` flags,
   now in both modes, rather than adding a second set of field switches.
4. **"Show as graph" ships in this PR**, via `/graph?ids=` and `GET /api/v1/graph_data?ids=`, designed so UI-4b's
   Explore reuses both.

## Acceptance criteria

- With every new argument omitted, the tool, REST search and `GraphSearch` return exactly what they returned at
  `487804e` (S1 gate and existing specs green unchanged).
- The filters narrow every channel before ranking, page correctly, combine with perspective, temporal and
  `max_tokens`, and fail with the listed messages; the `tools/list` change is exactly the one in F3.
- The page gives the same entities in the same order as the tool for the same arguments; old `/search?q=&strategy=`
  links, Home's quick search and the `/graph` form still work; every filter is in the URL; snippets are escaped with
  `<mark>` highlights and cost no embedding call; Semantic is disabled with a reason when vectors aren't available.
- The panel is read-only; a guest sees no "Open in Review", form or edit link. "Show as graph" opens `/graph` with
  exactly the page's entities and the relations among them. Guest searches still count against the same budget; the
  panel and graph data don't. Zero CSP violations.
- Full suite green locally and on CI (rspec, rubocop, brakeman, lint, scan_ruby, scan_js); 0 rows left in the test
  DB; `git diff db/structure.sql` empty; synthetic data only; files under ~500 lines, methods under ~60.

## Stop and ask Steve if

- Any code above no longer matches its description (in particular `SearchTool#call`, `EntityRetrievalService.search`,
  `HybridSearchStrategy#search`, the vector queries, `GraphDataController#index` or `GuestSearchThrottle`).
- The S1 gate can't be made deterministic (ties), or any later commit needs an S1 example edited.
- With the new arguments omitted, any output differs, or the `tools/list` diff contains anything beyond F3's list.
- `EXPLAIN` shows either vector query using the `VECTOR KEY`, so a project/type `WHERE` could cut recall.
- A filter can't be applied inside a channel without a migration (e.g. a new index) or an extra embedding call.
- Snippets need a migration, more than one query per page, or an embedding call.
- The panel or page needs a write endpoint, or a guest would reach anything beyond `/search`, the panel and the
  existing graph reads.
- The `ids` branch needs more than relations among the given ids (e.g. hop expansion) to be useful.
- Enforced CSP needs an exception for anything on the page.
- The diff grows well past ~3,000 lines, or Steve wants F-1 folded in.
