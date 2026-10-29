# UI-4b → graph_mem 1.61.0: Explore (canvas + editable panel, merges with a preview, every edit undoable), plus F-1, F-2 and the UI-3 leftovers

**✅ DONE (Oct 29):** shipped in #136 as **1.61.0** (merged as `05aa5c1`; **tag pending**, Steve tags it). The optional follow-ups left from the #136 review are none of them blocking, and they are step **L** of `docs/plans/ui-6-plan.md`: `EntityMergePreview#subtree_size` limits relation rows, not new ids (`entity_merge_preview.rb:159-160`); the capped neighbourhood read in `graph_data` has no `ORDER` (`graph_data_controller.rb:109`); and the panel's "Show it" link is dead when the duplicate is on another panel page (`_add_observation.html.haml:15`).

**Written 2026-10-28 (Europe/Rome)** for Claude, from `main` at `9c8d3bc` (1.60.0 tagged, #135 merged as `5e17353`).
Every file:line in "What the code looks like today" was checked against that commit. If a line has moved, find the
code by the quoted text; if the code no longer matches the description, **stop and ask Steve** instead of improvising.
Only code was read while writing this plan. **No spec was run**: the PR is checked by running the suite locally and by
CI (CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-4b [Claude]: Explore → 1.61.0"**, §2.4
(Explore), §5.1-§5.4 (guardrails, confirm levels, change sets, role matrix) and wins where they differ. It also
carries three small items that Steve folded into this PR on Oct 28: §6.F **F-1** (handled errors never reach the
log), §6.F **F-2** (GitHub Actions can't set up Ruby) and the optional leftovers listed at the top of
`docs/plans/ui-3-plan.md`. Scope: Explore replaces the `/graph` page. One canvas for the operator and the guest, the
UI-3 entity panel on the right, operator edits that each run in a change set (UI-4a) with a 10-minute undo toast, a
merge dialog with a server-side preview and a digest check, "Propose deletion" instead of delete, and no browser call
to an `/api/v1` write endpoint any more.

## Brief

| | |
|---|---|
| Branch / PR | `claude/ui-4b-explore`, **one PR**, title "Explore (1.61.0)" |
| Commits | F-2 → F-1 → L → E1 … E5 → W1 … W7 → T → D → R, one commit per step (more is fine, fewer is not: F-2, F-1 and L stay separate commits) |
| Scope | §2.4 exactly, minus what "Decided" below changes; plus F-1, F-2 and the UI-3 leftovers |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, `Dir.mktmpdir`); never a real graph, never a copy of one |
| Read first | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `docs/plans/ui-dashboard-plan.md` §0.1, §2.4, §5; `docs/plans/ui-4a-plan.md` "Decisions"; `docs/architecture.md` "Change sets and undo (UI-4a, 1.57.0)" (line 224) |

## What the code looks like today (verified at `9c8d3bc`)

**F-2 (Ruby pin).** `.github/workflows/ci.yml` jobs `scan_ruby` (9-23), `scan_js` (25-39), `lint` (41-54) install Ruby
with `ruby/setup-ruby@v1` and `ruby-version: .ruby-version` (19, 35, 50); a commented-out test job sits at 56-80. Ruby
`3.4.1` is pinned in: `.ruby-version:1`; `.versions.conf:1` (`ruby=ruby-3.4.1`, **missing from the §6.F list**);
`Dockerfile:10` (`ARG RUBY_VERSION=3.4.1`, base `docker.io/library/ruby:$RUBY_VERSION-slim`); `.circleci/config.yml:7`
(`cimg/ruby:3.4.1`) and `:50` (`cimg/ruby:3.4.1-browsers`); `bin/mcp_graph_mem_runner.sh:61`
(`EXPECTED_RUBY_VERSION`); `.cursor/install.sh:11`; `.cursor/environment.json:9`; `AGENTS.md:3,24,79`;
`README.md:7,69,261,373`; `docs/development.md:11`; `docs/troubleshooting.md:291-292`; `script/mcp_compat/clients.sh:11,20,21`,
`rsdk_client.rb:11`, `rsdk_server.rb:12`, `README.md:32,50,51,96`; `config/deploy.yml:85` (commented). On Oct 28 these
tags existed: `cimg/ruby:3.4.12` and `cimg/ruby:3.4.12-browsers` (the newest 3.4 tag), `ruby:3.4.12-slim`, and the
`ruby-3.4.12` source tarball on ruby-lang.org.

**F-1 (error log).** `lib/graph_mem/official_mcp.rb:10-12`: `EXCEPTION_REPORTER = lambda { |exception, context|
Rails.error.report(exception, handled: true, context: { mcp: context.to_h }) }`. `rg -n "Rails.error.subscribe" app lib
config` finds nothing. `app/controllers/pages_controller.rb:16-30` (`home_section`) calls `Rails.error.report(e,
handled: true, context: { home_section: section })` and then, with the comment "Rails.error has no subscriber here, so
log it too", `Rails.logger.error("Home widget #{section} failed: #{e.class}: #{e.message}")` (25-27).
`spec/requests/pages_spec.rb:158-168` stubs `Rails.logger.error` and expects `"Home widget digest failed:
ActiveRecord::StatementInvalid: synthetic failure"`.

**UI-3 leftovers.** `app/services/graph_search/page.rb` (183 lines): `MAX_PAGE = 50` (22), `EXACT_SCAN_LIMIT = 1_000`
(25), `@page = [ params[:page].to_i, 1 ].max` (65), `exact_hits` (134-151): one query `LOWER(name) = needle OR
LOWER(aliases) LIKE …` with `.limit(EXACT_SCAN_LIMIT)` (142-143) and the `sanitize_sql_like` pattern at 141, then the
alias re-check in Ruby (`alias_list`, 154-156). With more than 1,000 alias candidates ahead of it in the order, an
exact-name match can fall off the scan. `spec/services/graph_search/page_spec.rb:120-131` pins only `%` and `_` in the
escaped pattern; `spec/requests/search_spec.rb:84-87` (above `MAX_PAGE` → 422) and `97-100` (last page) cover the upper
bound, nothing covers `page=0`, `-3` or `abc`. `memory_entities` has no index on `name` alone (the unique one is
`(project_scope, name)`); the column collation is `utf8mb4_general_ci`, so `where(name: q)` already compares
case-insensitively.

**The `/graph` page.** `config/routes.rb:108` `get "graph", to: "pages#graph"`; `PagesController` `allow_guest :home,
:graph` (4), `graph` (31-33) only sets `@vector_available`. `app/views/pages/graph.html.haml` renders its own copy of
`search/form` (line 6) and `pages/_graph_explorer`, whose root is `data: { controller: "graph",
graph_read_only_value: !can_write? }`. Links to `graph_path`: `search/_result.html.haml:22`,
`search/results.html.haml:24` ("Show as graph", `ids=`), `entities/panel.html.haml:21` ("Open in Explore",
`scoped_entity_id:`), `ui/_sidebar.html.haml:20` (`nav-explore`), `audit_logs_helper.rb:42`,
`data_exchange/import_report.html.haml:59`, `maintenance/index.html.haml:47`,
`maintenance/_agent_contexts_card.html.haml:35`, `maintenance/_project_scans_card.html.haml:58`. Specs that visit it:
`spec/requests/pages_spec.rb:222-231`, `spec/system/navigation_spec.rb:40,106,161`,
`spec/system/content_security_policy_spec.rb:48,62`, `spec/requests/content_security_policy_spec.rb:33`,
`spec/system/escaping_spec.rb:42-153` (four graph sinks driven through
`getControllerForElementAndIdentifier(container, 'graph')`), `spec/system/search_spec.rb:47`,
`spec/requests/search_spec.rb:35,175`, `spec/requests/changes_spec.rb:69-71`, `spec/requests/entities_panel_spec.rb:37`,
`spec/requests/operator/guest_login_spec.rb:46-48`, `spec/requests/sessions_spec.rb:159-166`,
`spec/helpers/ui_helper_spec.rb:34,52`.

**The canvas JS.** `config/importmap.rb:7` pins `cytoscape` 3.31.4; `:10` `pin_all_from "app/javascript/graph", under:
"graph"`. `app/javascript/controllers/graph_controller.js` (211 lines): `static values = { readOnly: Boolean }` (16);
`connect` (18-52) builds `ContextMenuManager` and `DragDropManager` and reads `scoped_entity_id` / `ids` from the URL
(35-51); `fetchDataAndRenderGraph` (139-147) writes a static error string with `innerHTML` (145, also 173); handlers at
180-210 (mouseover tooltip, dblclick → subgraph, `cxttap` node/edge menus). `graph/cytoscape_config.js` (103):
`GRAPH_STYLES`, `LAYOUT_OPTIONS` (`cose`) **keep**. `graph/api_client.js` (202) calls `/api/v1` **writes** from the
browser: `updateEntity` PATCH (48), `deleteEntity` DELETE (61), `mergeEntities` `merge_into` (72), `createRelation`
(83), `deleteDuplicateObservations` (124), `addTargetNameAsAlias` (136), and `/data_exchange` `update_relation` (98),
`delete_relation` (107), `delete_duplicate_relations` (116). `graph/context_menu.js` (403): node menu (33-43) ends with a
hard **Delete**; edge menu (92-98) Edit Type / Delete Relation; `#visible` read-only filter (199-202); `alert()` /
`confirm()` at 156, 195, 209-226, 274-311, 369-400. `graph/drag_drop_manager.js` (264): overlap detection (40-78),
action menu Merge Nodes / Create Relation / Cancel (100-120), `confirm()` (162), merge (203-215), create relation
(235-260). `graph/modal_manager.js` (41) and `graph/observation_renderer.js` (57, incl. `renderDuplicateWarning`) are
the observation modal the panel replaces. `lib/dom.js` has `escapeHtml`, `text`, `br`, `el`.

**`GET /api/v1/graph_data`** (`app/controllers/api/v1/graph_data_controller.rb`, 137 lines, guest-readable through
`ApiAuthentication::GUEST_READ_ACTIONS` 19-26): `MAX_IDS = 100` (7); `render_ids_graph` (33-41, the only branch with
`includes(:from_entity, :to_entity)`); `parse_ids` (44-52, `/\A[1-9]\d{0,18}\z/`); `render_full_graph` (54-58,
**unbounded**: every entity and every relation); `render_root_graph` (60-65); `render_scoped_subgraph` (67-80, direct
`part_of` children only); `render_subgraph` (82-98, one hop); `render_graph_data` (100-134) loads
`active_memory_observations` per node just to call `.size` and reads `from_entity&.name` / `to_entity&.name` per edge
(N+1 outside the `ids` branch).

**The panel (UI-3).** `config/routes.rb:107` `get "entities/:id/panel", to: "entities#panel", as: :entity_panel`;
`app/controllers/entities_controller.rb` (17 lines, `allow_guest :panel`, `layout false` for frame requests, 404 renders
`missing`); `app/services/entity_panel.rb` (75): `@page = [ page.to_i, 1 ].max` with **no upper bound** (a huge `page`
becomes a huge `OFFSET`); `app/views/entities/panel.html.haml` (71): frame `entity-panel`, "Open in Explore" (21),
"Open in Review" behind `can_write?` (23-25), paged observations, relations grouped by type. No edit affordance yet, and
no "recent changes" section.

**Change sets and undo (UI-4a).** `app/models/change_set.rb` (95): `KINDS` (15-19); `KIND_PATTERNS = [
/\Apolicy\.[a-z_]+\z/, /\Aexplore\.[a-z_]+\z/ ]` (21, "Reserved for UI-5 policy runs and UI-4b Explore actions"), so no
model change is needed for `explore.*` kinds; `WINDOWS = { "merge" => 7.days, "audit" => 30.days }` (24);
`ChangeSet.record(kind:, summary:, subject:, actor: Current.actor, undo_of:)` (57-63) joins an open set and opens no
transaction or lock. `CompactionReviewService::ChangeRecording#undo_handle(context)`
(`app/services/compaction_review_service/change_recording.rb:62-65`) turns a context into `{ change_set_uuid, undoable,
not_undoable_reason }`. `ChangesController#undo` (`app/controllers/changes_controller.rb`, 39 lines; route
`config/routes.rb:133-135`) answers ok / 409 / 422 / 404 / 503 and re-renders `#toasts` for Turbo Stream requests, else
`redirect_back`. `ChangeSetUndo` re-syncs memberships after an audit undo (`app/services/change_set_undo/audit_inverse.rb:25,143-147`).
The undo toast: `app/views/layouts/_flash_messages.html.haml:2-12` renders `flash[:undo] = { "uuid", "label" }` as a
`button_to undo_change_path` and never times out; `app/javascript/controllers/toast_controller.js` (25) dismisses
notices after 6000 ms and keeps alerts and undo toasts. The pattern to copy for a write controller is
`app/controllers/concerns/review_responses.rb` (`respond_with_review` 25-42, `review_undo` 68-72, `NOT_UNDOABLE` 11-14,
`rescue_from ProjectMembership::LockTimeout`). `ui-4a-plan.md` Decision 2 moved `EntityMergePreview`,
`EntityMergeService` and the digest check here, and Decision 12 made the 10-minute toast a UI-4b concern.

**Merge.** `app/strategies/node_operations_strategy.rb` (426): `merge_into(source_id, target_id, change_set_kind:
"merge")` (95-116, retries), `merge_into_once` (118-186: membership lock, transaction, `.lock` ordered by id, checks
not found / `PROJECT_ROOT_PROTECTED_ERROR` / "Cannot merge entities of different types", `ChangeSet.record(kind:
change_set_kind, subject: target, summary: "merged 'A' into 'B'")`, `EntityMergeSnapshot.capture_before` / `complete`,
returns `change_set_uuid`), `merge_locked!` (263-284), alias merge (~290-303), `transfer_observations!` (305-314, every
observation of the source, any status), `reassign_outgoing_relations!` (324-337) and `reassign_incoming_relations!`
(342-362: drops a relation when the target already has the same triple, re-syncs reparented `part_of` children),
`cleanup_duplicate_relations` (366-400). `EntityMergeEvidence.pick_survivor(left, right)`
(`app/services/entity_merge_evidence.rb:36-50`) returns `[source, survivor]`. `EntityMergeSnapshot` (71):
`capture_before` (18-27), `complete` (33-47). `app/services/entity_merge_preview.rb` and
`app/services/entity_merge_service.rb` **don't exist**. The group-digest pattern to copy:
`app/services/review_group_actions.rb:42` (`status: :conflict`, "The group changed since the preview: review it
again") and `:153` (`Digest::SHA256.hexdigest`).

**Move.** `NodeOperationsStrategy#move_to_parent(node_id, parent_id)` (33-83): cycle and "already a child" checks,
`ProjectMembership.with_membership_lock`, a transaction that replaces the `part_of` edge, `ProjectMembership.sync!`.
It has **no project-root guard** (§2.4 says roots can't move) and opens no change set. `ProjectMembership.sync!`
(`app/services/project_membership.rb:93`) moves the subtree with `update_all` (129).

**Edits.** `GraphEditService#update_entity` (`app/services/graph_edit_service.rb:117-150`: name, type, aliases,
description, `save!`) has **no project-root protection**; `#update_observation` (152-180) supersedes (`supersede: true`)
or `update_active!`. `MemoryObservation`: `MUTABLE_FIELDS` incl. `perspective` (11), `validates :perspective,
inclusion: { in: PERSPECTIVES }` (47), `mark_obsolete!(reason:)` (78-88), `supersede!` (97-115).
`GraphWriteService#create_observation` (291-316), `#create_relation` (318-, a duplicate triple fails; the DB also has
`UNIQUE KEY index_memory_relations_uniqueness (from_entity_id, to_entity_id, relation_type)`).
`RelationSemantics.validate_create!` (`app/services/relation_semantics.rb:39-58`: self-relation, cycle, single parent).
`GraphVocabulary::RELATION_TYPES` and `ENTITY_TYPES` (`app/lib/graph_vocabulary.rb:74-75`).
`ImportObservationDuplicateDetector#find_duplicate(entity:, content:)`: exact first, then semantic, which raises
`UnavailableError` without embeddings. `MemoryEntity` validates name uniqueness per project, case-insensitive (24).

**Propose deletion.** `CompactionReviewService.seed_report(report_type: "scan_review", source: "operator", items: [ {
kind: "delete_entity", entity_id:, entity_name:, entity_type:, reason: } ])` (`app/services/compaction_review_service.rb:117`;
item shape as in `graphify_rescan.rb:262-272`); `delete_entity` is in `SCAN_KINDS` and `DESTRUCTIVE_KINDS`
(`review_row_classifier.rb:19,26`), and a pending row with the same signature is not seeded twice.

**Roles and guards.** `ApplicationController#set_current_actor` (35-45, `operator:<user>@<ip>`), `authenticate!`,
`authorize_role!`; `RoleAuthorization.allow_guest` (deny by default). `spec/requests/role_matrix_spec.rb` walks every
dispatcher route (41-53, so new write routes are covered automatically) and lists the guest's allowed pages in
`guest_allowed` (12-24: `"GET /graph" => 200`, `"GET /entities/1/panel" => [200, 404]`). CSP
(`config/initializers/content_security_policy.rb`) is enforced: `script-src 'self'` + nonce, `style-src 'self'
'unsafe-inline'` (Cytoscape), `connect-src 'self'`, `form-action 'self'`, `frame-ancestors 'none'`. CSRF is on
everywhere, `/data_exchange` included (`spec/requests/data_exchange_csrf_spec.rb`; the dashboard's "CSRF skipped" note
is stale). Activity: there is no Activity page yet (System › Activity is UI-7); `HomeSnapshot#activity`
(`app/services/home_snapshot.rb:66-68`) lists the latest change sets on Home.

**Version.** `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` say `1.60.0`; `CHANGELOG.md`
starts at `## [1.60.0] - 2026-10-28`.

## Steps

### F-2. Ruby 3.4.12 (first commit, so Actions turn green)
- Replace `3.4.1` with `3.4.12` in every file listed above, `.versions.conf` and the two docs included. In `README.md`
  change only the version on line 373, nothing else on that line. In `script/mcp_compat/README.md` leave the
  recorded-run lines as they are (§6.F F-2). Leave the commented `config/deploy.yml:85` alone unless it names a Ruby
  version (it doesn't today).
- No `Gemfile` / `Gemfile.lock` change (no `ruby` line, no `RUBY VERSION` section).
- CHANGELOG `[Unreleased]` → **Changed**: "Ruby 3.4.12 (GitHub Actions' runners no longer offer 3.4.1). Re-create local
  RVM gemsets for the new version."
- **Check:** the three Actions jobs green on the PR's first push, CircleCI green, `docker build .` works (say in the PR
  whether you ran it).

### F-1. A `Rails.error` subscriber
- New `lib/graph_mem/error_log_subscriber.rb` (`GraphMem::ErrorLogSubscriber#report(error, handled:, severity:, context:,
  source: nil)`) and `config/initializers/error_logging.rb` (`Rails.error.subscribe(GraphMem::ErrorLogSubscriber.new)`),
  exactly as §6.F F-1 "Fix (preferred)" says: handled reports only; one `error` line with class, message, `source` and
  the reduced context; `context[:mcp]` reduced to the JSON-RPC `method` and the tool `name` (never `arguments`); the rest
  through `ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)`; truncated to 500 chars;
  never raises (rescue → one fixed `Rails.logger.error` line).
- Remove the explicit `Rails.logger.error` and its comment from `PagesController#home_section` (25-27; keep the
  `Rails.error.report`). Update `pages_spec.rb:158-168` to expect the subscriber's line (it must contain
  `ActiveRecord::StatementInvalid`, `synthetic failure` and `home_section`), still exactly once.
- Specs: `spec/lib/graph_mem/error_log_subscriber_spec.rb` with the four cases in §6.F F-1 (MCP context keeps
  `tools/call` and `search`, drops `SynthWidget`; `token: "synth-secret"` → `[FILTERED]`; `handled: false` writes
  nothing; a failing logger doesn't raise) plus one through `GraphMem::OfficialMcp::EXCEPTION_REPORTER.call`.
- CHANGELOG **Fixed**: "Errors reported to `Rails.error` (MCP internal errors, a failing Home widget) are logged."

### L. UI-3 leftovers
- **Exact-name lookup.** In `GraphSearch::Page#exact_hits` run the name match as its own query,
  `filtered_scope.where(name: query).select(ROW_COLUMNS)` (collation already ignores case; re-check
  `name.casecmp?(query)` in Ruby to stay exact), and keep the alias `LIKE` query with `EXACT_SCAN_LIMIT` for aliases
  only (`LOWER(aliases) LIKE …`, without `OR LOWER(name) = …`). Union in Ruby, dedupe by id, keep today's order. The
  name query is bounded by the per-project uniqueness (at most one row per project scope). Keep the method under ~60
  lines; split a `name_hits` / `alias_hits` pair if needed.
- Specs in `page_spec.rb`: 1,001 synthetic entities whose aliases contain `SynthWidget` and sort before it, plus one named
  `SynthWidget` (create them with `insert_all`, the test DB must still end with 0 rows) → the exact hit is found; a query
  with a backslash (`q = 'a\\b'` in Ruby) produces the doubled backslash in the `LIKE` pattern and matches a synthetic
  alias `a\b` literally.
- Request specs in `search_spec.rb`: `page=0`, `page=-3` and `page=abc` render page 1 (200, the first result, no
  "Previous").
- CHANGELOG **Fixed**: "Exact search finds an exact name even when more than 1,000 aliases match first."

**Checkpoint 1:** F-2, F-1, L pushed; full suite, rubocop, brakeman, and the three Actions jobs green.

### E1. `graph_data` for Explore (read side, all callers)
- `render_graph_data`: count active observations without loading them (one grouped `COUNT` query for the node ids, e.g.
  `MemoryObservation.active.where(memory_entity_id: ids).group(:memory_entity_id).count`); load relations with
  `includes(:from_entity, :to_entity)` in **every** branch (or read names from the node hash). The JSON shape doesn't
  change.
- Node cap (Decision 1): `MAX_NODES = 2_000` on the full, scoped and neighbourhood branches. Over the cap, return the
  first 2,000 by id, only relations among them, and `"truncated": true, "total": N` next to `elements` (absent when not
  truncated, so existing clients see the same JSON).
- Depth: `entity_id=` accepts `depth=1|2` (default 1; anything else → 422 with a fixed message). Depth 2 is two hops,
  under the same cap.
- `project_id=` scope: the project root plus its `part_of` subtree via `ProjectSubtree.resolve(project_id,
  max_entities: MAX_NODES)` (`app/services/project_subtree.rb:18`), plus the relations among those entities.
- Specs (`spec/requests/api/v1/graph_data_spec.rb`, extend): query count constant as entities grow (count with
  `ActiveSupport::Notifications`, as in `review_digest_spec`); the cap and `truncated`; depth 1 vs 2; `depth=3` → 422;
  guest read still 200; project scope.

### E2. `/explore` page and route; `/graph` goes away
- `get "explore", to: "explore#show", as: :explore`; `ExploreController#show` with `allow_guest :show`. It reads only
  integer-validated params (`project_id`, `entity_id`, `ids` via the same rule as `GraphDataController#parse_ids`,
  `depth`) and passes them to the view as data values. Invalid values are ignored (fall back to the root view), not 500.
- `app/views/explore/show.html.haml`: toolbar (scope picker: project · root · full · "from search"; layout: cose /
  breadthfirst / concentric / grid, all built into Cytoscape; depth 1/2; entity-type and relation-type filters; fit),
  canvas (~65%), and the panel frame `turbo_frame_tag "entity-panel"` (~35%). No search form on this page (the duplicated
  one goes with `/graph`); a link to Search instead. Data for the toolbar (project roots, types) comes from the server
  as data attributes, not inline JSON in a script tag.
- Remove `PagesController#graph`, `allow_guest :graph`, `pages/graph.html.haml`, `pages/_graph_explorer.html.haml`.
  Route `get "graph", to: redirect { |_params, request| "/explore#{"?#{request.query_string}" if request.query_string.present?}" }, status: 301`
  so old links (`scoped_entity_id=`, `ids=`) keep working; `ExploreController` maps `scoped_entity_id` to `entity_id`.
  The redirect is a transition shim, so §6.D-6 removes it.
- Repoint every `graph_path` user listed above to `explore_path` (sidebar `nav-explore`, "Show as graph", "Open in
  Explore", the maintenance cards, the audit helper, the import report). Keep the `ui.nav.explore` label.
- Specs: `spec/requests/explore_spec.rb` (operator and guest 200; bad params → root view; `/graph?ids=1,2` → 301 to
  `/explore?ids=1,2`); role matrix: replace `"GET /graph" => 200` with `"GET /explore" => 200`; update every spec in the
  list above that visits `/graph`.

### E3. `explore_controller.js` (canvas, read side)
- New `app/javascript/controllers/explore_controller.js` from `graph_controller.js` (delete the old one). Values:
  `readOnly`, `scope`, `entityId`, `projectId`, `ids`, `depth`. It owns the Cytoscape instance (`this.cy`, kept as a
  public field: the system specs drive it), keeps `GRAPH_STYLES` and the layouts, and writes the current scope to the
  URL with `history.replaceState`, so a reload (and the undo toast's full-page redirect) lands on the same view.
- Selecting a node dispatches `entity:selected` (`{ id }`) and sets the panel frame's `src` to
  `entity_panel_path(id)`; double-click opens the neighbourhood (depth from the toolbar). Filters hide elements locally
  (`cy.elements(...).style("display", …)`); no request. A truncated response shows "Showing 2,000 of N; pick a project"
  as text.
- It listens for `graph:changed` (E5 sends it) and then refetches the current scope, keeping the positions of the nodes
  that remain and laying out only new ones; removed ids disappear.
- `api_client.js` keeps **reads only** (`fetchGraphData` and the panel/search reads). Delete every write method listed
  above, and delete `modal_manager.js` and `observation_renderer.js` (the panel replaces the modal). Error states use
  `textContent` / `lib/dom.js`, never `innerHTML` (today's static strings at 145 and 173 included).
- Keep `tooltip.js` and `cytoscape_config.js`; the escaping specs for the tooltip move to the new controller name.

**Checkpoint 2:** read-only Explore replaces `/graph` for both roles; no write path in the JS yet (the context menu and
drag menu show read items only for now); suite, CSP spec and escaping specs green.

### W1. Write plumbing (`Explore::` controllers, `ExploreResponses`, the 10-minute toast)
- `app/controllers/explore/base_controller.rb` (`< ApplicationController`, operator only: no `allow_guest`) and
  `app/controllers/concerns/explore_responses.rb`, modelled on `ReviewResponses`: one `respond_with_explore(result,
  entity:)` that answers Turbo Stream (update `toasts`, replace `entity-panel` with the fresh panel, and a
  `graph_changed` stream action) or HTML (`redirect_to explore_path(...)` with the flash); 422 with the message on
  validation errors, 409 on a conflict, 404 on a missing record, 503 on `ProjectMembership::LockTimeout`.
- `graph_changed` is a custom Turbo Stream action registered in `explore_controller.js`
  (`StreamActions.graph_changed`): it reads `{ "removed": [ids], "changed": [ids] }` from the stream's `<template>` as
  text (`JSON.parse(template.content.textContent)`) and dispatches `graph:changed`. No inline script, no HTML from the
  payload.
- New `app/services/explore_edits.rb` (split into `app/services/explore_edits/*.rb` if it passes ~300 lines): one
  method per edit, each wrapping the existing service or model call in `ChangeSet.record(kind: "explore.…", subject:,
  summary:)` and returning `{ success:, status:, error:, change_set_uuid:, undoable:, not_undoable_reason: }` (reuse the
  `undo_handle` logic: extract it to `ChangeSet::Context#undo_handle` or a small module rather than copying it). Kinds:
  `explore.entity_edit`, `explore.observation_add`, `explore.observation_edit`, `explore.observation_retire`,
  `explore.relation_add`, `explore.relation_remove`, `explore.move`, `explore.merge` (all match `KIND_PATTERNS`).
- The toast: `flash[:undo] = { "uuid", "label", "until" => 10.minutes.from_now.iso8601 }` for Explore edits only.
  `_flash_messages.html.haml` puts `until` on the undo toast as a data attribute; `toast_controller.js` removes the Undo
  button (and leaves "Undo it later from Home › Recent activity") when the time passes. Review's undo toasts carry no
  `until` and behave as today. The server-side window stays `ChangeSet::WINDOWS`.

### W2. Entity edits (`Explore::EntitiesController#update`)
- `PATCH /explore/entities/:id`: name, entity_type, aliases, description through `GraphEditService#update_entity`
  inside `explore.entity_edit`. **Project roots: rename only** (and description): a type or alias change on a root →
  422 "Project roots can only be renamed." Enforce it in `ExploreEdits`, not in `GraphEditService` (the MCP tool keeps
  its behaviour).
- Name uniqueness errors come back as 422 with the model's message, rendered in the panel form.
- `POST /explore/entities/:id/propose_deletion` (W7).

### W3. Observations (`Explore::ObservationsController`)
- `POST /explore/entities/:entity_id/observations` (content ≤ the model's limit, perspective from
  `MemoryObservation::PERSPECTIVES` or blank): exact duplicate → 422 "This observation already exists" with a link to
  it; a semantic match → re-render the form with "Similar to: …" (as text) and an **Add anyway** submit (`force=1`);
  embeddings unavailable → skip the semantic check and say so in the toast (Decision 3). Create with
  `MemoryObservation.create!` (same attributes as `GraphWriteService#create_observation`) in `explore.observation_add`.
- `PATCH /explore/observations/:id`: text/perspective through `GraphEditService#update_observation` with
  `supersede: true` (history kept via `superseded_by`); an inactive observation → 422.
- `POST /explore/observations/:id/retire`: `mark_obsolete!(reason:)`; already inactive → 422.

### W4. Relations and moves (`Explore::RelationsController`, `Explore::MovesController`)
- `GET /explore/relations/new?from_id=&to_id=` renders the type picker into the `explore-dialog` frame:
  `GraphVocabulary::RELATION_TYPES`, suggestions first, and the canonical direction as text ("SynthWidget part_of Alpha
  Service"), with a swap button. `POST /explore/relations`: `RelationSemantics.validate_create!` then create in
  `explore.relation_add`; duplicate triple → 422 (rescue `ActiveRecord::RecordNotUnique` too); self / cycle → 422.
- `DELETE /explore/relations/:id` in `explore.relation_remove` (audit strategy, so undo re-creates the original id).
  Confirm with `turbo_confirm`, the app's convention.
- `GET /explore/moves/new?node_id=&parent_id=`: the confirm card (subtree size via the same descendant walk the
  strategy uses, capped at `MAX_NODES` and shown as "2,000+"; current and new project; "moves N entities from project X
  to Y" in amber when the project changes). Project roots → the card says why and has no button.
  `POST /explore/moves`: root guard (422 "Project roots can't be moved."), then `NodeOperationsStrategy#move_to_parent`
  inside `explore.move`. Add the root guard in the Explore path, not in the strategy (`/data_exchange/move_node` keeps
  its behaviour until UI-6).

### W5. The editable panel
- `entities/panel.html.haml` keeps its URL and controller (Decision 2) and gains, behind `can_write?` only: inline
  edit forms (name / type / aliases / description; project roots show only name and description), "Add observation",
  per-observation Edit / Retire, per-relation Remove (`button_to` with `turbo_confirm`), "Merge into…" (opens the merge
  dialog with an entity picker limited to the same type, using `GraphSearch::Page` with the type filter), "Propose
  deletion", and **Recent changes** (the last 5 change sets with `subject` = this entity: time, kind, summary, Undo
  while `undoable?`; operator only, Decision 4). Every form is a normal Rails form (CSRF token), `data-turbo-stream`.
- Bound `EntityPanel`'s page: clamp to the last page (or `MAX_PAGE`, same as Search) so `page=999999999` doesn't issue a
  huge `OFFSET`. Keep `page=0`, negatives and non-numbers → 1, with a spec.
- Keep the file under ~500 lines: split partials (`entities/_edit_*.html.haml`, `entities/_recent_changes.html.haml`).

### W6. Merge: `EntityMergePreview`, `EntityMergeService`, the dialog
- `app/services/entity_merge_preview.rb`: `EntityMergePreview.new(source_id, target_id).call` → read-only struct with
  the same lookups as `merge_into_once`/`merge_locked!`: observations that move (count + first 5, any status, like
  `transfer_observations!`), relations re-pointed (out/in, by type), relations dropped (duplicates of an existing target
  triple, A↔B edges), aliases B gains (extract the alias merge from the strategy into one public pure method both use),
  `part_of` children reparented and the project change (entities that change project), open review rows that reference
  A (informational: UI-4a Decision 9 says merges don't close them), blockers (not found, same id, different
  `entity_type`, either side a project root), the `pick_survivor` hint, and `digest` = SHA-256 of the sorted id lists
  (observations, re-pointed, dropped, children) plus the target's aliases. Writes nothing.
- Guard inside the lock: add an optional `before_merge:` callable to `merge_into` / `merge_into_once`, called with
  `(source, target)` after the row locks and the existing checks and before `ChangeSet.record`; when it returns an error
  string, the merge returns `{ success: false, status: :conflict, error: }` and writes nothing. Default `nil`, so every
  existing caller is unchanged.
- `app/services/entity_merge_service.rb`: `EntityMergeService.call(source_id:, target_id:, digest:, actor:)` sets
  `Current.actor`, calls `merge_into(source_id, target_id, change_set_kind: "explore.merge", before_merge: ->(s, t) {
  EntityMergePreview.new(s.id, t.id).call.digest == digest ? nil : CONFLICT_MESSAGE })`, and returns the result with the
  undo handle. `CONFLICT_MESSAGE = "The graph changed since the preview, review it again."` The preview inside the lock
  must read through the same connection (it does: same thread, same transaction).
- `Explore::MergesController#new` (`GET /explore/merges/new?source_id=&target_id=`, renders
  `explore/merges/_dialog.html.haml` in the `explore-dialog` frame: header "Merge **A** (source, will be removed) into
  **B** (survivor)", Swap direction (a link to `new` with the ids swapped), the hint, the preview lists, blockers with the
  button disabled, the digest in a hidden field) and `#create` (`POST /explore/merges`: 409 on a stale digest, 422 on a
  blocker, then the toast "Merged A into B · Undo" and `graph_changed` with `removed: [A]`).
- The dialog is a `<dialog>` opened by a small Stimulus controller (`explore_dialog_controller.js`), closed with Esc and
  a Cancel button; focus moves into it and back.

### W7. Context menu, drag menu, Propose deletion
- `graph/context_menu.js`: node menu = header, Edit in panel, Merge into…, Propose deletion, plus the read items (toggle
  relations / observations, open neighbourhood); edge menu = Remove relation. **No** hard delete, no dedupe, no
  `alert()` / `confirm()`. With `readOnly` the write items are not built at all (not only hidden).
- `graph/drag_drop_manager.js`: on drop over a node, a menu "Add relation… · Move under … · Merge A into B…" (merge only
  when the types match; "Move under" hidden for project roots); each item opens the matching `new` URL in the
  `explore-dialog` frame. With `readOnly` dragging only moves the node locally.
- The only JS write path is `app/javascript/lib/turbo_form.js#submitTurboForm(action, method, fields, { confirm })`: it
  builds a real `<form>` with the CSRF token from `<meta name="csrf-token">`, `data-turbo-stream`, optional
  `data-turbo-confirm`, and calls `requestSubmit()`. Used for Remove relation from the edge menu; everything else goes
  through server-rendered forms.
- Propose deletion (`POST /explore/entities/:id/propose_deletion`, optional reason ≤ 500 chars): `seed_report` with
  `source: "operator"` and a `delete_entity` item; the toast links to the new row (`review_row_path`); a pending row
  with the same signature → toast "Already proposed" with a link to the existing row. No change set (nothing in the
  graph changes); the seeded report is the record.

**Checkpoint 3:** every §2.4 edit works for the operator from the panel, the context menu and the drag menu; guest
sees none of them and every write route answers 403; suite, CSP and escaping specs green.

### T. Specs (beyond the ones listed per step)
- `spec/requests/explore/{entities,observations,relations,moves,merges,deletion_proposals}_spec.rb`: per endpoint:
  validation errors (422), the audit row with the operator actor and the change set, the Turbo Stream response (toast,
  panel, `graph_changed`), project-root protections, duplicate relation → 422, missing CSRF token → 422 (one example
  per controller with `allow_forgery_protection` on), guest → 403 and nothing written.
- `spec/requests/explore/merges_spec.rb`: preview renders the counts; stale digest → 409 and nothing written; different
  types → 422; success creates an `explore.merge` change set (strategy `merge`) and the toast; undo through
  `POST /changes/:uuid/undo` restores A.
- `spec/services/entity_merge_preview_spec.rb`: the preview matches the merge's effects on a synthetic graph
  (observations moved, relations re-pointed and dropped, children reparented, project change) and writes nothing (no
  audit rows, no change sets); `spec/services/entity_merge_service_spec.rb`: a change between preview and create (an
  observation added to A) → conflict.
- `spec/services/explore_edits_spec.rb`: each edit opens one change set of its kind; undo of each restores the before
  state (relation remove → same id back; observation edit → old one active again; move → old parent and project).
- `spec/strategies/node_operations_strategy_spec.rb`: `before_merge:` returning an error writes nothing; `nil` default
  keeps every existing example green.
- System specs (`spec/system/explore_spec.rb`; drive Cytoscape through the controller's `cy`, because canvas drags are
  flaky headless): select node → panel; add observation → toast → Undo → gone; drop node on node → Add relation →
  created; context menu Merge into… → dialog → Merge → toast → Undo; the undo button disappears after 10 minutes (travel
  or stub the clock in JS); guest sees the canvas and panel, right-click shows no write items, drag moves locally only.
- Escaping: move the four graph sinks in `spec/system/escaping_spec.rb` to `/explore` and the `explore` identifier, drop
  the `renderObservationCards` / `renderDuplicateWarning` case with the files, and add the merge dialog, the type
  picker, the move card and the panel's recent changes (an entity named `<img src=x onerror=alert(1)>` renders as text).
- CSP: `/explore` for both roles, plus one with the merge dialog open, in the CSP system spec's page lists; zero
  violations.
- Role matrix: `"GET /explore" => 200` for the guest; the walk covers every `explore/*` write route with 403.

### D. Docs
- `docs/guides/ui-guide.md` "Explore" (line 116) and the guest section (206-212): the new layout, the edits, the
  merge dialog, Propose deletion, the 10-minute undo; drop the hard-delete and dedupe text. Replace
  `explore-context-menu.png` / `explore-drag-drop.png` only if you can take synthetic screenshots; otherwise say so in
  the PR and leave them.
- `docs/architecture.md` "Change sets and undo": the `explore.*` kinds, `EntityMergePreview` / `EntityMergeService`
  and the digest guard.
- `docs/plans/ui-dashboard-plan.md`: row 20 ✅ with the PR number; mark F-1, F-2 and the UI-3 leftovers done.

### R. Release 1.61.0
- `lib/graph_mem/version.rb` → `1.61.0`; `skills/graph-mem-mcp-toolset/SKILL.md:18` → `graph-mem-version: "1.61.0"`;
  CHANGELOG `[Unreleased]` → `## [1.61.0] - <date>` with a one-line summary ("Explore: edit the graph from the canvas
  and the panel, merge with a preview, undo every change"), Added / Changed / Removed (the `/graph` page, the hard
  delete and dedupe items, the browser's `/api/v1` write calls) / Fixed (F-1, L) / Security (graph_data cap, panel page
  bound). Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 4:** R pushed; everything in "Acceptance criteria" holds.

## Security checklist (against the #106 baseline)

- **Auth / guest:** `ExploreController#show` and `EntitiesController#panel` are the only guest-allowed Explore actions;
  `Explore::BaseController` has no `allow_guest`, so every write is 403 for the guest by default (the role matrix walk
  proves it). Edit affordances are not rendered for the guest (not hidden by CSS). Signed-out → login redirect.
- **CSRF:** on for every Explore write (Rails forms, `button_to`, `turbo_form.js` reads the meta token); one spec per
  controller with forgery protection enabled.
- **CSP:** no inline scripts or handlers; JSON reaches JS only as data attributes or a stream `<template>` read as text;
  the CSP system spec covers `/explore` for both roles and the open dialog.
- **XSS:** names, aliases, observation text and relation types go to the DOM through `textContent` / `lib/dom.js`; HAML
  escapes by default; no `html_safe` / `raw`; no `innerHTML` with data in the Explore JS.
- **SQLi:** ids parsed as integers (the `parse_ids` rule); relation types checked against `GraphVocabulary`; no string
  interpolation in SQL; `sanitize_sql_like` stays for the alias `LIKE`.
- **DoS:** `graph_data` capped at 2,000 nodes (Decision 1); depth ≤ 2; `ids` ≤ 100 (unchanged); panel page bounded;
  move subtree count capped; observation and reason lengths bounded; merge preview queries bounded by the entity's
  own rows.
- **N+1:** grouped observation counts and relation `includes` in `graph_data`; the panel's recent changes is one query
  with `limit(5)`; a query-count spec on `graph_data` and on the panel.
- **Destructive actions:** no entity delete and no bulk delete from Explore (§5.1); merges only through the preview and
  digest; every edit in a change set with the operator actor (`operator:<user>@<ip>`).

## Specs (summary)

| Area | File | New / changed |
|---|---|---|
| F-1 | `spec/lib/graph_mem/error_log_subscriber_spec.rb`, `spec/requests/pages_spec.rb` | new / changed |
| L | `spec/services/graph_search/page_spec.rb`, `spec/requests/search_spec.rb` | changed |
| graph_data | `spec/requests/api/v1/graph_data_spec.rb` | changed |
| page, redirect | `spec/requests/explore_spec.rb` | new |
| writes | `spec/requests/explore/*_spec.rb` | new |
| merge | `spec/services/entity_merge_preview_spec.rb`, `spec/services/entity_merge_service_spec.rb`, `spec/strategies/node_operations_strategy_spec.rb` | new / changed |
| edits | `spec/services/explore_edits_spec.rb` | new |
| panel | `spec/requests/entities_panel_spec.rb` | changed (edit sections for operator only, page bound) |
| system | `spec/system/explore_spec.rb`, `escaping_spec.rb`, `content_security_policy_spec.rb`, `navigation_spec.rb`, `search_spec.rb` | new / changed |
| roles | `spec/requests/role_matrix_spec.rb` | changed |
| `/graph` users | the request and helper specs listed in "What the code looks like today" | changed |

## Size and split

About **3,800-4,300 changed lines** (≈ 45% specs): F-2 ~60, F-1 ~150, L ~120, E1 ~250, E2-E3 ~900 (mostly JS, with
deletions), W1-W7 ~1,600, T ~900 on top of the per-step specs, D ~150, R ~30. The largest PR in the series; one PR as
Steve decided, worked in the four checkpoints above with CI green at each. Files under ~500 lines, methods under ~60.
If the diff passes ~4,500 lines, stop and ask Steve (a split point exists after Checkpoint 2).

## Decided Oct 28 by Steve

- F-1, F-2 and the three UI-3 leftovers go into this PR (1.61.0), each in its own commit, F-2 first.
- F-2 is Fix A with **Ruby 3.4.12** (the tags were checked on Oct 28).
- Already settled elsewhere, not reopened here: `/data_exchange` endpoints stay until UI-6/UI-5 (dashboard §1.4); the
  `/api/v1` writes stay for agents, the browser stops calling them (§5.1); the `/graph` redirect lives until §6.D-6;
  deletes stay proposals (§2.4); the merge preview, service and digest belong here (ui-4a Decision 2); the 10-minute
  toast belongs here (ui-4a Decision 12).

## Open decisions (each with a recommendation; Claude follows the recommendation unless Steve says otherwise)

1. **Node cap on `graph_data`.** The full graph is unbounded today and guest-readable. *Recommendation:* `MAX_NODES =
   2_000` on the full, scoped, project and neighbourhood branches for every caller (only the browser uses this
   endpoint, §1.4), with `truncated` / `total` added only when the cap applies.
2. **Where the editable panel lives.** *Recommendation:* keep `GET /entities/:id/panel` and `EntitiesController#panel`
   (UI-3's, already guest-allowed and in the role matrix, reused by Search) and add the edit partials behind
   `can_write?`; only the writes live under `Explore::`. The alternative, an `explore/entities#panel` copy, gives two
   URLs for the same frame.
3. **"Similar observation" check without embeddings.** The import detector raises when vectors are unavailable.
   *Recommendation:* the exact duplicate always blocks (422); the semantic match is a warning with "Add anyway"; with
   vectors unavailable Explore skips the semantic part and says "similarity not checked" in the toast, instead of
   refusing the edit.
4. **Who sees the panel's "Recent changes".** Actors include the operator's user and IP and agent names.
   *Recommendation:* operator only, like Home's activity widget; the guest panel stays as UI-3 shipped it.

## Acceptance criteria

- Explore can't delete an entity or bulk-delete anything; the browser makes no request to an `/api/v1` write endpoint
  or to `/data_exchange` `update_relation` / `delete_relation` / `delete_duplicate_relations` (assert with
  `rg` in the PR description, and a system spec that records `fetch` URLs).
- Every edit, merges included, creates one change set with the operator actor, appears in Home › Recent activity and
  the panel's Recent changes, and can be undone from the toast for 10 minutes (and through `ChangeSetUndo` within its
  window afterwards).
- A merge never does more than its preview showed (stale digest → 409, nothing written).
- The guest sees the canvas, toolbar and panel, no write affordance, and gets 403 from every write route.
- `/graph` and `/graph?…` redirect (301) to `/explore` with the query string.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) green; `OLLAMA_URL=http://127.0.0.1:9`
  suite green; 0 rows left in the test DB; `git diff db/structure.sql` empty (no migration in this PR); zero CSP
  violations; synthetic data only.

## Stop and ask Steve if

- A quoted line no longer matches the code, or `ChangeSetUndo` can't undo one of the `explore.*` kinds (for example a
  move whose membership change it doesn't restore).
- The digest guard can't run inside `merge_into_once`'s lock without changing what existing callers do.
- Any step needs a migration, a new gem or importmap pin, or a CSP change.
- Removing `/graph` breaks something not listed above (a link from outside the app, an MCP doc, a skill file).
- Ruby 3.4.12 fails anywhere (a gem that doesn't build, the Docker image, a cimg tag) — don't fall back to Fix B on your
  own.
- The diff passes ~4,500 lines, or a file passes ~500 lines and can't be split cleanly.
