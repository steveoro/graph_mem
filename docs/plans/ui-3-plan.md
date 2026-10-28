# UI-3 → graph_mem 1.60.0: Search (one page, every mode, shared with the MCP `search` tool)

**Written 2026-10-28 (Europe/Rome)** for Claude, from `main` at `07edfbf` (1.59.0 tagged, #134 merged, F-1 recorded).
Every file:line in "What the code looks like today" was checked against `07edfbf`. If a line has moved, find the code
by the quoted text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.
Only code was read while writing this plan. **No spec was run**: the PRs are checked by running the suite locally and
by CI (CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-3 [Claude]: Search → 1.60.0"** and §2.3
(Search) and wins where the two differ. The scope is unchanged: one Search page for the operator and the guest, all
modes, filters in the URL, results with snippets, a read-only entity panel, and a `GraphSearch` service extracted
from `SearchTool#call` so the page and agents get the same results. Steve's earlier decisions stay as they are: the
guest is read-only and server-side enforced (§0.2 decisions 1 and 8, §2.1), guest searches are throttled (UI-1b:
60/min per IP, 300/min across all guests), and **ranking doesn't change in this PR** (§6 UI-3 Risks).

## Brief

| | |
|---|---|
| **Branches / PRs** | **Two PRs** (Decision 1), UI-3b off `main` after UI-3a merges. **UI-3a** `claude/ui-3a-graph-search`, title `Search: GraphSearch shared by the search tool and the page (no release)`: steps S1–S3, no version bump (`## [Unreleased]`). **UI-3b** `claude/ui-3-search`, title `Search (1.60.0)`: steps P1–P7 + release R. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | UI-3a: **S1** `GraphSearch` extraction, **S2** retrieval options (defaults unchanged), **S3** specs + `[Unreleased]` line. UI-3b: **P1** page query, **P2** controller + routes, **P3** views + highlight helper + CSS, **P4** entity panel, **P5** Stimulus controller, **P6** specs, **P7** docs and folded items, **R** release. Review fixes go in new commits; no force-push after review starts. |
| **Scope** | UI-3a: no change to the `search` tool's description, arguments, response envelope or ranking; `spec/mcp/tools_list_snapshot_spec.rb` stays unchanged; REST `api/v1/memory_entities#search` untouched. UI-3b: exactly `ui-dashboard-plan.md` §2.3 and §6 UI-3, minus "Show as graph" (Decision 4). No migration, no new embedding calls, no write endpoint, no change to `GuestSearchThrottle`'s limits. |
| **Data** | Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Gadget Project`, temp dirs). Never real data, real credentials or a production dump. Specs must not reach a real embedding service: stub `EmbeddingService` / `VectorSearchStrategy` (the outbound HTTP guard fails any example that tries). |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (spec hygiene, test-DB truncate, done criteria), §2.1, §2.3, §5.4; `docs/mcp_access_control.md` (guest section); `spec/tools/search_tool_spec.rb`. |

## What the code looks like today (verified at `07edfbf`)

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

## UI-3a: `GraphSearch` (no release)

### S1. Extract `GraphSearch` from `SearchTool#call`
- New `app/services/graph_search.rb`: `GraphSearch.call(query:, include: [], page: nil, per_page: nil, limit: nil,
  search_in_name: true, search_in_type: true, search_in_aliases: true, search_in_observations: true,
  occurred_after: nil, occurred_before: nil, as_of: nil, max_tokens: nil, perspective: nil, context_scope:,
  logger: Rails.logger)` returns **exactly** the hash `SearchTool#call` returns today (catalog, summary, subgraph) and
  raises the same `GraphMem::InvalidArgumentsError` messages. Move `normalized_paging`, `normalize_projections`,
  `summary_result`, `subgraph_result` and `build_temporal_window` with it (as private methods; keep the file under
  ~300 lines, splitting the token-budget block into `graph_search/summary.rb` if needed).
- `SearchTool#call` keeps its signature, `description`, `arguments` and `mcp_metadata`, and becomes
  `GraphSearch.call(**args, context_scope: graph_mem_context.scoped_entity_scope, logger: logger)` inside the existing
  `rescue` blocks (102-108). The error mapping stays in the tool.

### S2. Two retrieval options for the page (defaults unchanged)
- `EntityRetrievalService.search(..., ambient_context: true)`: `false` skips the line-11 fallback, so the page isn't
  boosted by an agent's context (Decision 2). Every existing caller keeps the default.
- `HybridSearchStrategy#search(..., text: true)`: `false` skips the text channel (56) so the page's Semantic mode is
  vector-only through the same fusion and boosts. With `text: true` the code path is byte-for-byte today's.
- `GraphSearch.call` gains `ambient_context: true` and `text: true`, passed through; the tool never sets them.

### S3. Specs (UI-3a) and the CHANGELOG line
- `spec/services/graph_search_spec.rb`: **parity** with `SearchTool#call` on a synthetic graph (entities, aliases,
  observations with both perspectives, dated facts, a Project root with members): same `entity_id`s in the same
  order and the same envelope for catalog mode, summary mode (pages 1–2, `per_page` 5 and 20), a temporal phrase in
  the query ("in October 2026"), `occurred_after`/`as_of`, `perspective`, `max_tokens`, subgraph mode with each
  `search_in_*` flag off, and with an active context; the same error messages for each invalid argument.
  Vectors: stub `VectorSearchStrategy#search`/`#search_observations` with fixed synthetic results so the semantic
  channels take part without HTTP.
- `spec/services/entity_retrieval_service_spec.rb`: with a context set on the `"default"` bucket,
  `ambient_context: false` gives the unboosted order and `true` (default) the boosted one.
- `spec/strategies/hybrid_search_strategy_spec.rb` (new or extended): `text: false` returns only vector-channel hits;
  the default equals today's result for the same stubs.
- `spec/tools/search_tool_spec.rb` and `spec/mcp/tools_list_snapshot_spec.rb` **unchanged** and green.
- `CHANGELOG.md`: add `## [Unreleased]` › Changed: "The MCP `search` tool's logic moved to `GraphSearch`, shared with
  the Search page in the next release; results are unchanged."

## UI-3b → 1.60.0: Search

### P1. The page query: `GraphSearch::Page`
- New `app/services/graph_search/page.rb`, `GraphSearch::Page.call(params, per_page: 20)` → a result object with
  `rows`, `page`, `next_page?`, `capped?`, `mode`, `filters`, `error`. Each row: the entity, `relevance_score`,
  `matched_fields`, up to 2 snippets, the project name and the relation count.
- **Modes** (`mode=`): `auto` (default) → `GraphSearch.call` summary mode, `semantic: true`, as the tool does;
  `text` → the same with `semantic: false` (no embedding call); `semantic` → `text: false`, **disabled with a reason**
  when `EmbeddingService.vector_enabled?` is false (reuse the existing hint text); `exact` → entities whose `name`
  equals `q` (DB collation, case-insensitive) or whose aliases contain `q` as a whole alias (split as
  `EntitySearchStrategy` does), ordered by name, no ranking call. Legacy `strategy=text` → `text`, `strategy=vector` →
  `semantic` (old `/search?q=&strategy=` links and the `/graph` form keep working). Unknown values → `auto`.
- **Parity rule:** `auto` with no project/type/match-in filter calls `GraphSearch.call(query:, page:, per_page: 20,
  occurred_after:, occurred_before:, as_of:, perspective:, context_scope: nil, ambient_context: false)`, i.e. the
  tool's own arguments and `limit`, so page N of the page = page N of the tool with no active context. `next_page?`
  = the page is full (no total count; the tool has none).
- **Tool-supported filters** pass straight through: `perspective` (`world`|`experience`|both), `occurred_after`,
  `occurred_before`, `as_of` (ISO 8601; `as_of` with either bound → the tool's error, shown inline with status 422,
  nothing else on the page breaks).
- **Page-only filters** (Decision 3): `project_id` (Project roots, from one `MemoryEntity.where(entity_type: "Project",
  project_id: nil)` query; the project itself or its members), `types[]` (entity types, multi; options from a
  `distinct.pluck(:entity_type)` capped at 50), `match[]` (`name`, `aliases`, `type`, `observations`; all on = no
  filter). They apply **after** ranking: fetch `GraphSearch.call(..., page: 1, per_page: 100)` and the next page up
  to `CANDIDATE_CAP = 200`, keep the rows that pass, then page through them. `match[]` maps onto `matched_fields`:
  `name` ← `name` or `semantic`, `aliases` ← `aliases`, `type` ← `entity_type`, `observations` ←
  `observation_semantic` or a lexical snippet hit. When the cap was reached, `capped?` is true and the page says
  "Filtered from the top 200 matches; refine the query to see more."
- **`include_obsolete`** affects only snippets and the panel (the entity ranking has no observation-status input; the
  observation-vector channel already reads active rows only). Default off.
- **Snippets:** for the page's entity ids, **one** query over `memory_observations` (active unless
  `include_obsolete`, the `perspective` filter applied) matching any query token (`QueryTokenizer.tokenize`) with
  `LIKE`, ranked per entity by `QueryTokenizer.overlap_score` then trust, top 2 per entity (a `ROW_NUMBER() OVER
  (PARTITION BY memory_entity_id …)` window or a capped Ruby group-by over at most 25 × 20 rows). **No embedding
  call:** never `ObservationRankingService.rank(mode: "relevance")` here. Semantic-only hits may have no snippet; then
  show the entity description.
- **Breadcrumb and counts:** project names in one query (`where(id: rows.map(&:project_id))`), relation counts with two
  grouped counts (as `apply_structural_boost` does). No per-row queries.

### P2. Controller and routes
- `SearchController#results` (same route, `/search`) becomes a thin adapter: `@search = GraphSearch::Page.call(search_params)`
  (permitted: `q mode strategy project_id perspective occurred_after occurred_before as_of include_obsolete page`,
  `types: []`, `match: []`), 422 when `@search.error`. Delete `perform_search`, `text_search`, `vector_search`
  (34-68) and `RESULTS_PER_PAGE`. Keep `include GuestSearchThrottle`, `allow_guest :results` and
  `throttle_guest_search :results` exactly. A blank `q` renders the empty page (no search call), as today.
- No `index` action is needed (§6 named one; `/search` already serves both the empty and the results page). If you
  add one, `allow_guest` and throttle it the same way and add it to the role matrix.

### P3. Views, highlight helper, CSS
- `app/views/search/results.html.haml` rewritten in the UI shell (`content_for :title`, `ui_page_header`), with
  `_filters.html.haml` (one GET form: query box, mode switch as radio buttons, filter chips; all state in the URL),
  `_result.html.haml` (name → panel link, type badge, project breadcrumb, score + matched fields, relation count,
  up to 2 `_snippet`s, "Open in Explore" → `graph_path(scoped_entity_id:)`) and `_snippet.html.haml`. Results and
  the panel sit side by side; the panel is a `turbo_frame_tag "entity-panel"`, and each result link has
  `data: { turbo_frame: "entity-panel" }` and a real `href` (works without JS).
- `app/helpers/search_helper.rb#highlight_snippet(text, tokens)`: split the **raw** text on a regex of the escaped
  tokens (case-insensitive), `ERB::Util.html_escape` every segment, wrap matched segments in `<mark>`, join, and mark
  the result safe; truncate around the first hit (~240 chars). It's the only `html_safe` in the PR. Never escape
  after inserting `<mark>`, and never match tokens against escaped text (a token like `amp` must not break `&amp;`).
- Keep `search/_form.html.haml` for `/graph` (its `strategy` radios still map, P1); UI-4b deletes it with the page.
  New styles go in a new `app/assets/tailwind/search.css` (`@layer components`, imported from `application.css`
  like `home.css`; `.search-page__*` classes over the `.ui-*` tokens); leave the old `search-*` rules in `graph.css` for `/graph` until UI-4b.
- Locale strings in `config/locales/search.en.yml`.

### P4. Read-only entity panel
- New `EntitiesController#panel` (`GET /entities/:id/panel`, `as: :entity_panel`), `allow_guest :panel`; renders
  `app/views/entities/_panel.html.haml` inside `turbo_frame_tag "entity-panel"` (layout only when it isn't a frame
  request). 404 for an unknown id.
- Contents: name, type, aliases, description, project breadcrumb; observations ranked by **trust** (no query, so no
  embedding call and nothing to throttle), first 10 active plus a "Show obsolete" link (`include_obsolete=1`) and
  "Show all" paging; relations grouped by type in both directions, first 20 each, each other end linking to its own
  panel; "Open in Explore" (`graph_path(scoped_entity_id:)`). **Operator only:** "Open in Review" →
  `review_path(q: entity.name)`, behind `can_write?`. **No edit links or forms for anyone** (Explore edits are UI-4b).
- Not throttled: it makes no embedding call. If it ever ranks by `?q=`, add it to `QUERY_GATED_ACTIONS`-style
  throttling first (stop and ask).

### P5. Stimulus
- `app/javascript/controllers/search_controller.js`: submit the filter form on chip/mode change
  (`form.requestSubmit()`), keep the focused result highlighted when the panel loads, `/` focuses the query box.
  No `innerHTML`, no inline handlers, no `alert()`/`confirm()`; CSP stays enforced with zero violations.

### P6. Specs (UI-3b)
- `spec/services/graph_search/page_spec.rb`: **parity** (auto, no filters: same ids/order as `SearchTool#call` with
  no context, pages 1–2); each mode (`text` makes no embedding call: `expect(EmbeddingService.instance).not_to
  receive(:embed)`; `semantic` uses `text: false`; `exact` on name and alias, case-insensitive); legacy `strategy`
  mapping; each filter (project incl. the root itself, multiple types, each `match[]` value, perspective, temporal,
  `include_obsolete`); the 200 cap and `capped?`; snippets: top 2, perspective and obsolete rules, one query (count
  queries with `ActiveSupport::Notifications`); no ambient context (a `"default"` bucket context doesn't reorder).
- `spec/requests/search_spec.rb` (new): blank query, results, each mode, a filter in the URL is kept in the form and
  the panel links, invalid temporal args → 422 with the message, unknown `mode` → auto, the vector-unavailable state
  (`vector_enabled?` false → Semantic disabled with the hint, auto still answers), old `/search?q=&strategy=vector`
  links, escaping (`<b>Synth</b>Widget` names and a `<script>synth()</script>` observation render as text; the
  snippet's `<mark>` is the only markup; a token `amp` on content with `&`), guest gets the same results.
- `spec/requests/entities_panel_spec.rb` (new): operator sees "Open in Review"; **guest** gets 200, no "Open in
  Review", no `form`, no edit link; 404 for an unknown id; obsolete toggle; signed out → login.
- `spec/requests/role_matrix_spec.rb`: add `"GET /entities/:id/panel" => 404` to `guest_allowed` (the dummy id) and an
  explicit guest 200 case on a real synthetic entity in the panel spec.
- `spec/requests/guest_search_throttle_spec.rb`: the new page still counts once per request; the panel isn't counted.
- `spec/system/escaping_spec.rb`: add a Search case (a hostile synthetic name and observation on the results page
  and in the panel).
- `spec/system/search_spec.rb`: query → filter chip → result → panel → "Open in Explore" lands on
  `/graph?scoped_entity_id=`; no CSP violations (`csp_console_errors` empty). Existing CSP, Home and navigation
  system specs stay green.

### P7. Docs and folded items
- `docs/guides/ui-guide.md` Search section (modes, filters, the 200-candidate note for page-only filters, the panel,
  guest differences), `README.md` page list if it names the old search, `docs/architecture.md` (`GraphSearch`
  shared by the tool and the page).
- **Folded (they touch Search code):**
  - The guest budget note: in `docs/mcp_access_control.md` (after 264) and `docs/guides/ui-guide.md` (202, 232), say
    that the 300/min is shared by all guests, so one busy guest can use it up for everyone until the minute passes.
    Optionally, the throttled page's text (`ui.en.yml:43`) mentions both limits.
  - `spec/support/system.rb:16`: use `<<~'JS'` (non-interpolating) so `/\s+/` reaches the browser intact. It's in
    scope because P6's system spec relies on `wait_for_stimulus` with the new controller.
- **Not folded by default:** F-1 (the `Rails.error` log subscriber, `ui-dashboard-plan.md` §6.F) can ride along in
  UI-3b only if Steve asks for it; otherwise it stays a separate patch.

### R. Release 1.60.0
- `lib/graph_mem/version.rb`, `skills/graph-mem-mcp-toolset/SKILL.md` (18) and the CHANGELOG to **1.60.0**: turn
  `## [Unreleased]` (UI-3a's line) into `## [1.60.0] - <merge date>` and add the Search page, the panel and the docs
  note. Leave recorded-run version lines in `docs/protocol_compat.md` / `script/mcp_compat/README.md` alone.

## Specs (summary)

| PR | New / changed |
|---|---|
| UI-3a | `graph_search_spec.rb` (parity with the tool, every mode and error), `entity_retrieval_service_spec.rb` (`ambient_context`), `hybrid_search_strategy_spec.rb` (`text: false`); `search_tool_spec.rb` and `tools_list_snapshot_spec.rb` unchanged. |
| UI-3b (1.60.0) | `graph_search/page_spec.rb`, `requests/search_spec.rb`, `requests/entities_panel_spec.rb`, `role_matrix_spec.rb` (+1 row), `guest_search_throttle_spec.rb` (+2), `system/search_spec.rb`. |

## Size and split

| PR | Version | Estimate | Diff size (guess) |
|---|---|---|---|
| UI-3a | none (`[Unreleased]`) | ~0.5 day | ~450 lines, mostly moved code and parity specs |
| UI-3b | **1.60.0** | ~1.5–2 days | ~1,300 lines (views, panel, page query, specs) |

UI-3a goes first so the extraction of the busiest MCP tool is reviewed on its own, with the parity specs as the gate,
before any page code depends on it. One PR (`Search (1.60.0)` with S1–S3 as its first commits) also works if Steve
prefers (Decision 1).

## Decisions for Steve (defaults in bold; Steve may change any)

1. **Split:** **two PRs, UI-3a (extraction, no bump) then UI-3b `Search (1.60.0)`**, like UI-1a/1b, UI-5a/5b and
   UI-2a/2b. Alternative: one PR with S1–S3 as its first commits.
2. **Agents' context on the page:** **the Search page ignores agents' active context** (`ambient_context: false`);
   the Project filter is the explicit way to narrow. Today `EntityRetrievalService` falls back to the shared
   `"default"` bucket, so an agent without an `X-MCP-Client` header would reorder the operator's results.
   Alternative: keep the fallback, as REST `memory_entities#search` does.
3. **Filters the tool doesn't have** (project, entity type, match-in): **page-only post-filters over the top 200
   ranked candidates; the MCP tool and REST API stay unchanged** (no new tool arguments, no `tools/list` change).
   Alternative: add them to `GraphSearch` and the tool as real filters, an agent-visible change with its own spec
   and SKILL.md update.
4. **"Show as graph"** (§2.3, `/explore?ids=`): **deferred to UI-4b**, which builds `/explore`; today's `/graph` takes
   only `?scoped_entity_id=`, which "Open in Explore" uses. Alternative: teach `/graph` an `ids=` list now (JS change
   in `graph_controller.js` and `api_client.js`, thrown away by UI-4b).

## Acceptance criteria

- UI-3a: `GraphSearch.call` returns what `SearchTool#call` returned for every spec'd argument set; the tool's
  description, arguments and `tools/list` snapshot are unchanged; all existing specs green.
- UI-3b (1.60.0): `auto` with no page-only filter gives the same entities in the same order as the MCP `search` tool
  (no context, same page/per_page); old `/search?q=&strategy=` links, Home's quick search and the `/graph` form still
  work; every filter is in the URL; snippets are escaped with `<mark>` highlights and cost no embedding call; Semantic
  is disabled with a reason when vectors aren't available and auto still answers; the panel is read-only, and a
  guest sees no "Open in Review", no form and no edit link; guest searches still count against the same budget, the
  panel doesn't; zero CSP violations.
- Both: full suite green locally and on CI (rspec, rubocop, brakeman, lint, scan_ruby, scan_js); 0 rows left in the
  test DB; `git diff db/structure.sql` empty (no migration); CHANGELOG entries; synthetic data only; files under ~500
  lines and methods under ~60.

## Stop and ask Steve if

- Any code above no longer matches its description (in particular `SearchTool#call`, `EntityRetrievalService.search`
  line 11, `HybridSearchStrategy#search` or `GuestSearchThrottle`).
- A parity spec can only pass by changing ranking, the tool's envelope, its arguments, its description or the
  `tools/list` snapshot.
- Snippets need a migration (e.g. a FULLTEXT index on observations), more than one query per page, or an embedding
  call to be usable.
- The panel or the page needs a write endpoint, or a guest would reach anything beyond `/search` and the panel.
- `match[]` can't be expressed from `matched_fields` plus the lexical snippet hit without touching the strategies.
- The 200-candidate cap makes a realistic filtered search (synthetic graph of ~2,000 entities) miss obvious matches.
- Enforced CSP needs an exception for anything on the page.
- Steve wants F-1 folded in, or "Show as graph" now (Decision 4).
