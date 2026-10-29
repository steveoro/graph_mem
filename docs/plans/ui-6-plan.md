# UI-6 → graph_mem 1.62.0: Projects & Data (projects list, one scan form with a live path check, scan detail, imports with history, async exports), plus the #136 leftovers

**✅ DONE (Oct 29):** shipped in #137 as **1.62.0** (merged as `dddad69`, tagged `v1.62.0`). The one leftover from the #137 review (the "capped" hints show at exactly 500 roots, because the check is `>=`) is step **L** of `docs/plans/ui-7-plan.md`, and Decision 1's "UI-7 may move Background jobs under System" is that plan's Decision 1.

**Written 2026-10-29 (Europe/Rome)** for Claude, from `main` at `9e51dd9` (#136 merged as `05aa5c1`, **1.61.0 not
tagged yet**: Steve tags it). Every file:line in "What the code looks like today" was checked against that commit. If
a line has moved, find the code by the quoted text. If the code no longer matches the description, **stop and ask
Steve** instead of improvising. Only code was read while writing this plan. **No spec was run**: the PR is checked by
running the suite locally and by CI (CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-6 [Claude]: Projects & Data → 1.62.0"** and
§2.6, and it wins where they differ. It also carries the optional leftovers from the #136 review (step **L**). Scope:
Projects & Data replaces the scan, import and export parts of the Maintenance hub. It has the following parts:
- a projects list;
- one scan form (normal or guided) with a live `ScanRootPolicy` check;
- a scan detail page;
- imports (GraphMem export or Graphify `graph.json`) with a history;
- async exports with progress.

All of it is operator only. The dependencies (mcp plan PR-0 for `ScanRootPolicy`, and UI-1 for the shell and roles)
are done.

## Brief

| | |
|---|---|
| Branch / PR | `claude/ui-6-projects-data`, **one PR**, titled "Projects & Data (1.62.0)" |
| Commits | L → P1 … P6 → T → D → R, one commit per step (more is fine, fewer is not; L stays its own commit) |
| Scope | §2.6, minus what "Open decisions" changes, plus L |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, `Dir.mktmpdir` trees as scan roots); never a real graph, never a copy of one, never a real project folder |
| Read first | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `docs/plans/ui-dashboard-plan.md` §0.1, §2.6, §5; `docs/guides/ui-guide.md` "Projects & Data"; `docs/architecture.md` |

## What the code looks like today (verified at `9e51dd9`)

**#136 leftovers (L).**
- `app/services/entity_merge_preview.rb:159-160`: `subtree_size` reads
  `MemoryRelation.where(relation_type: "part_of", to_entity_id: frontier).limit(SUBTREE_CAP + 2 - seen.size).pluck(:from_entity_id)`.
  The `LIMIT` caps relation rows, not new ids. A child that is `part_of` two frontier parents, or that was seen at an
  earlier level, uses up the limit. The walk then goes on from a partial frontier, so the "N entities move" count can
  come out low and look exact. `ProjectSubtree` allows several parents.
- `app/controllers/api/v1/graph_data_controller.rb:109`: `neighbour_ids` is
  `MemoryRelation.where(from_column => frontier).distinct.limit(MAX_NODES + 1).pluck(to_column)`, with no `ORDER`.
  Which neighbours survive the cap depends on the access path. `docs/api/rest_api_reference.md:339` and
  `swagger/v1/swagger.yaml:1300` say every view keeps "the lowest ids".
- `app/views/entities/_add_observation.html.haml:15`: "Show it" links to `#observation-<id>`. The panel lists
  `EntityPanel::OBSERVATIONS_PER_PAGE = 10` per page (`app/services/entity_panel.rb:12`, ordered by
  `trust_score desc, confidence desc, id asc` at 47-48), so the anchor is dead when the duplicate is on another page.
  The pager links are `entity_panel_path(entity, page:, obsolete:)` (`entities/_panel.html.haml:40,42`).

**The Maintenance hub today.**
- Routes: `config/routes.rb:126` `get "maintenance"`; `:124` `resources :project_scans, only: [:create]`; `:125`
  `resources :project_scan_skills, only: [:create, :update]`; `:72-103` `resources :data_exchange` with `export`,
  `export_async`, `download_export`, `root_nodes`, `import_upload`, `import_review`, `import_execute`, `import_report`,
  `import_cancel`, `entity_search`, plus the cleanup and relation routes.
- `MaintenanceController#index` (`app/controllers/maintenance_controller.rb`, 12 lines) loads
  `ExportStrategy.new.root_nodes` and `MaintenanceDashboardSnapshot.call`.
- `app/views/maintenance/index.html.haml` (65 lines) has these sections:
  - the Export card (13-22: sync `GET export` with `ids[]`, `turbo: false`);
  - the Import card (29-35: `import_upload`, JSON only);
  - a Cleanup signpost (37-47);
  - `#background-jobs` (50-54: compactor and garbage-collector cards);
  - `#project-scans` (56-59: `_project_scans_card`, `_project_scan_skill_companion_card`);
  - `#mcp-clients` (61-62: `_agent_contexts_card`);
  - the report details (64-65).
- The sidebar links it once (`ui/_sidebar.html.haml:30`, group `ui.nav.groups.projects`).
- Other links to `maintenance_path`:
  - `home/_jobs.html.haml:35` (`anchor: "background-jobs"`);
  - `home/_clients.html.haml:18` (`anchor: "mcp-clients"`);
  - `home_snapshot/health.rb:74,76`;
  - every redirect in `operator/maintenance_controller.rb` (7-41), `project_scans_controller.rb` (8, 14, 28, 32) and
    `project_scan_skills_controller.rb` (10-69).
- `docs/guides/ui-guide.md:50,85,87-91,176-182` and `docs/dream_state.md:149,168,239` describe the hub.

**Scans.**
- `ProjectScansController#create` and `ProjectScanSkillsController#create/update` resolve the path with
  `ScanRootResolution#resolve_scan_root` → `ScanRootPolicy.resolve` (`app/services/scan_root_policy.rb:83`;
  `Result = Data.define(:ok, :path, :root, :code, :message, :warnings)` at 18). They enqueue `ProjectScanJob` or
  `ProjectScanSkillJob` under a fresh `SecureRandom.uuid`, then redirect to `maintenance_path(anchor: "project-scans")`.
- A live path check already exists: `GET /operator/settings/project_scans/check_path`
  (`routes.rb:180`, `Operator::SettingsController#check_scan_path` 97-100) renders the `scan-path-check` frame from
  `operator/settings/_scan_path_check.html.haml`.
- The two forms (`_project_scans_card.html.haml:10-29`, `_project_scan_skill_companion_card.html.haml:42-50`) repeat
  root, name and aliases. Both render `maintenance/_scan_folders_hint`.
- A scan's "Details" link opens the raw JSON API (`_project_scans_card.html.haml:69`, `api_v1_scan_project_path`).
- Each scan writes an `OperationProgress` (`operation_type` `project_scan` / `project_scan_skill`). Its `details` hold
  `project_root`, `project_name`, `mode` and `dry_run` (`app/jobs/project_scan_job.rb:40`), plus `project_entity_id`
  on completion (`:157`).
- `app/javascript/controllers/operation_progress_controller.js` follows one operation over `OperationProgressChannel`.

**Imports.**
- `DataExchangeController#import_upload` (96-144): `MAX_UPLOAD_BYTES = 64.megabytes`. It parses JSON and runs
  `ImportMatchingStrategy#match`, which accepts only a `root_nodes` export
  (`app/strategies/import_matching_strategy.rb:101-103`). It stores an `ImportSession` keyed by
  `session[:import_session_id]`.
- Every error redirects to `root_path` (99, 105, 117, 135, 138, 142, 153, 175, 219, 238), i.e. Home, not back to the
  upload.
- `import_execute` (170-212) runs the import **inside the request** and records an `OperationProgress` with
  `operation_type: "import"` and no details. `import_report` shows only the last report of the session.
- Graphify `graph.json` is imported only by rake: `lib/tasks/graphify.rake` `translate` / `import` run
  `GraphifyImporter.new(json, project_name:).translate` and check the file's folder with `ScanRootPolicy.resolve`.
- The views are `data_exchange/import_review.html.haml` (161 lines) and `import_report.html.haml` (59 lines).

**Exports.**
- `ExportJob` (`app/jobs/export_job.rb`, 152 lines) writes `tmp/exports/export_<id>.json`, an `OperationProgress`
  (`operation_type: "export"`) and `ExportProgressChannel` broadcasts.
- `ExportJob.cleanup_old_exports(max_age: 1.hour)` exists at 143, but nothing calls it: `config/recurring.yml` doesn't
  schedule it.
- `export_async` and `download_export` answer JSON. Nothing in the UI calls them.
- `ExportStrategy#root_nodes` (`app/strategies/export_strategy.rb:31-39`) plucks every `part_of` / `depends_on`
  child id (unbounded) and then runs `where.not(id: …)`.

**Roles.** `RoleAuthorization` is deny-by-default (`allow_guest` opts in). `spec/requests/role_matrix_spec.rb` walks
every route, so new routes are covered as long as no controller calls `allow_guest`.

**Version.** `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` say `1.61.0`. `CHANGELOG.md`
has `## [1.61.0] - 2026-10-28` on top.

## Steps

### L. #136 leftovers (own commit, first)
- `subtree_size`: change the read to
  `.where(relation_type: "part_of", to_entity_id: frontier).where.not(from_entity_id: seen).distinct.limit(SUBTREE_CAP + 2 - seen.size).pluck(:from_entity_id)`,
  so every row is a new id. The `NOT IN` list stays at most 2,001 ids. Spec in `spec/services/entity_merge_preview_spec.rb`:
  stub `SUBTREE_CAP` small, and make a child `part_of` two moving parents plus enough rows to reach the limit. The count
  is then exact below the cap and "N+" above it.
- `neighbour_ids`: add `.order(to_column)` before `limit`, so a capped neighbourhood keeps the lowest ids, as the docs
  say. Spec in `spec/requests/api/v1/graph_data_spec.rb`: a hub with spokes created in descending id order and a
  stubbed `MAX_NODES` keeps the lowest ids. If the query plan turns this into a full filesort of a hub's relations
  that you can't bound, reword `rest_api_reference.md:339`, `swagger.yaml:1300` and the comment at
  `graph_data_controller.rb:112` instead ("a neighbourhood keeps up to 2,000 of its neighbours"), and say which one you
  chose in the PR.
- "Show it": compute the duplicate's page with the panel's own ordering (count the active observations ahead of it in
  `trust_score desc, confidence desc, id asc`). Link to `entity_panel_path(entity, page: n, anchor: "observation-<id>")`
  inside the panel frame. If it's on the current page, keep the plain anchor. Request spec in
  `spec/requests/explore/observations_spec.rb`: a duplicate on page 2 links to `page=2`.

**Checkpoint 1:** L pushed; full suite, rubocop, brakeman and the three Actions jobs green. **Open the PR as a draft
now.**

### P1. Routes, `Projects::BaseController`, nav
- Add `get "projects", to: "projects#index"` and `namespace :projects` with the following:
  - `scans` (`index`, `new`, `create`, `show` by `operation_id`, plus `get :check_path, on: :collection`);
  - `scan_skills` (`update`: continue / stop);
  - `imports` (`index`, `new`, `create` = upload, `show` = review, `execute` member, `report` member, `destroy` =
    cancel);
  - `exports` (`index`, `create`, `show` = progress, `download` member).
- No controller calls `allow_guest`. `Projects::BaseController` sets the layout section.
- Sidebar: the `projects` group gets "Projects", "Scans", "Imports" and "Exports" (`nav-projects`, `nav-scans`,
  `nav-imports`, `nav-exports`) instead of "Maintenance". Locale keys go in a new `config/locales/projects.en.yml`.
- Redirects (301, kept until §6.D-6):
  - `GET /maintenance` → `/projects`, except the `#background-jobs` / `#mcp-clients` targets (see Decision 1);
  - `GET /data_exchange/import_review` / `import_report` → the new import routes.
  - The old `POST` routes stay working until D-6, and their redirects point at the new pages.

### P2. Projects list (`ProjectsController#index`)
- Show one row per Project root (`entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE`), paginated (50 per page),
  each with the following:
  - the last scan (one query over `OperationProgress` for `project_scan` / `project_scan_skill`, newest per
    `details->project_entity_id`, falling back to `project_name`);
  - the last import;
  - the pending scan-review group count (one grouped count on `MaintenanceReportRow` by `project_id`, linking to
    `review_path(view: "scan", project_id:)`);
  - "Open in Explore" (`explore_path(project_id:)`).
- Use a fixed number of queries (a query-count spec).
- An empty state links to "New scan" and "Import".

### P3. One scan form with a live check; scan detail
- `Projects::ScansController#new` renders one form, with the following:
  - the path;
  - a live check: `path_check_controller.js`, debounced, hits `GET /projects/scans/check_path`, which renders the
    existing `_scan_path_check` partial, moved to `projects/scans/_path_check`. The Settings tab renders the moved
    partial, so there's one partial with two callers.
  - the allowed folders as clickable chips (from `ScanRootPolicy.status`);
  - name, aliases, mode, globs and dry run;
  - a "Guided (step by step)" toggle that shows the depth checkboxes.
- `create` keeps both jobs exactly as the two old controllers enqueue them. Move the shared code into a
  `ProjectScanLauncher` service (`call(params) → Result(operation_id, warnings)`), so the old controllers become thin
  wrappers until D-6.
- Redirect to the detail page.
- `show` (`/projects/scans/:operation_id`) shows the following:
  - status, phase, progress (`operation_progress_controller.js`) and counters (including `skipped_outside_root` and
    `skipped_denylisted` when present);
  - the fallback reason and the error;
  - Continue / Stop for a guided scan;
  - its scan-review groups (links into Review).
- An unknown id is a 404 page.
- `index` lists scans newest first (25 per page).
- A path that fails the check is re-rendered with the policy's message (422), not redirected with a flash.

### P4. Imports with history
- Move `import_*` into `Projects::ImportsController`. **Keep the services** (`ImportMatchingStrategy`,
  `ImportExecutionStrategy`, `ImportSession`, `GraphifyImporter`).
- Every error re-renders the upload form (422) with the message. Nothing redirects to Home any more.
- Graphify `graph.json`: detect it (top-level `nodes` and `links`/`edges`, no `root_nodes`), ask for the project name
  (pre-filled from the file name), translate with `GraphifyImporter.new(json, project_name:).translate`, then go
  through the same review. Execute seeds the ambiguous relations, as today.
- Execute records `details` on its `OperationProgress`: file name, producer (`graph_mem` / `graphify`), project name,
  and the report summary (created, matched, skipped, errors count). `import_report` becomes `imports/:operation_id`,
  so any past import's report can be opened again.
- History (`imports#index`) lists `operation_type: "import"` rows newest first, including the rake imports. Rows
  without `details` show "imported from the command line".
- Restyle the review and report pages with the UI-1 components (`ui/_card`, `ui/_badge`, …). No raw Tailwind page
  styles.
- Execute stays synchronous (Decision 3).

### P5. Async exports
- `exports#index`: the root picker shows Project roots first, then other roots. `ExportStrategy#root_nodes` becomes
  one query (`NOT EXISTS` subquery instead of the unbounded pluck), and the list is paginated or capped at 500 with a
  filter field.
- `create` starts `ExportJob` and redirects to `exports/:operation_id`. That page follows progress over
  `OperationProgressChannel` (the same Stimulus controller as scans). `ExportProgressChannel` stays until D-6.
- `download` sends the file when it exists, or answers 410 with "This export has expired".
- `index` lists past exports from `OperationProgress`.
- Schedule `ExportJob.cleanup_old_exports` in `config/recurring.yml` (nothing does today), under `development:` and
  `production:`. It's a class method, not a job, so use the recurring task's `command:` form, or add a small job.
- The sync `GET /data_exchange/export` stays for scripts.

### P6. Retire the Maintenance hub
- Delete `app/views/maintenance/index.html.haml`, `_project_scans_card`, `_project_scan_skill_companion_card` and
  `_scan_folders_hint` (moved under `projects/`).
- Move the background-job cards and the MCP clients table as Decision 1 says, and repoint the following:
  - `home/_jobs.html.haml:35`;
  - `home/_clients.html.haml:18`;
  - `home_snapshot/health.rb:74,76`;
  - the redirects in `operator/maintenance_controller.rb`.
- `MaintenanceController` becomes the redirect, or is deleted if the route uses `redirect`.
- `MaintenanceDashboardSnapshot` keeps only what its remaining caller needs.

**Checkpoint 2:** P1-P6 pushed. Every scan, import and export is reachable from Projects & Data. `/maintenance`
redirects. CI is green.

### T. Specs (beyond the ones listed per step)
- Request specs, guest 403 everywhere, signed-out → login:
  - `spec/requests/projects_spec.rb` (list, empty state, query count);
  - `spec/requests/projects/scans_spec.rb`:
    - path check: ok, outside the filter, denylisted, not mounted;
    - normal and guided create;
    - a bad path → 422;
    - detail 200 / 404;
  - `spec/requests/projects/imports_spec.rb`:
    - upload → review → execute → report under the new routes;
    - a Graphify file → translate → review;
    - errors re-render;
    - history shows rake rows;
  - `spec/requests/projects/exports_spec.rb` (create, progress page, download, expired → 410).
- Change the existing `maintenance_hub_spec`, `project_scans_spec`, `project_scan_skills_spec`, `data_exchange_spec`
  and `data_exchange_csrf_spec` to cover the redirects and new targets. Don't delete coverage of the services.
- `role_matrix_spec`: no entry added to `guest_allowed`.
- A system spec, `spec/system/projects_spec.rb`: new scan of a `Dir.mktmpdir` root with dry run → detail page progress,
  using a stubbed job and a broadcast `OperationProgress` update. Also: an export → progress → download link.
- Extend `navigation_spec` and the CSP system spec to `/projects`, `/projects/scans/new` and `/projects/imports/new`.

### D. Docs
- `docs/guides/ui-guide.md`:
  - "Projects & Data" (176-182) rewritten;
  - the nav table (50);
  - the "controls that used to be on Home" paragraph (87-91);
  - the guest 403 list (220).
- `docs/dream_state.md:149,168,239`: the new location of the compactor controls.
- `docs/architecture.md`: `ProjectScanLauncher`, the import history from `OperationProgress.details`.
- `docs/plans/ui-dashboard-plan.md`: row 21 ✅ with the PR number.

### R. Release 1.62.0
- `lib/graph_mem/version.rb` → `1.62.0`, and `skills/graph-mem-mcp-toolset/SKILL.md:18` →
  `graph-mem-version: "1.62.0"`.
- CHANGELOG: add `## [1.62.0] - <date>`, with:
  - a one-line summary: "Projects & Data: projects, scans, imports and exports in one place, with history";
  - Added;
  - Changed (the Maintenance hub's parts moved, import errors stay on the upload page);
  - Removed (the Maintenance hub page);
  - Fixed (L).
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** R pushed; everything in "Acceptance criteria" holds. Mark the PR ready for review.

## Security checklist (against the #106 baseline)
- **Auth:** every `Projects::` action is operator only (no `allow_guest`). The role matrix proves it.
- **CSRF:** on for every write: scan create, import upload/execute/cancel, export create, scan-skill continue/stop.
- **Path safety:** every path, the Graphify upload's included, goes through `ScanRootPolicy.resolve`. Uploaded files
  are read in memory under `MAX_UPLOAD_BYTES` and never written to a user-chosen path. Export downloads resolve only
  `ExportJob.download_path(operation_id)` after checking that the id is a UUID that exists in `OperationProgress`
  (no path from params).
- **XSS / CSP:** HAML escaping; no `html_safe` / `raw`; no inline scripts. The path check result reaches the DOM as a
  Turbo Frame.
- **DoS:** the path check is debounced client-side and does only `realpath` / `stat` server-side. Every list is
  paginated or capped. `root_nodes` is one bounded query.

## Specs (summary)

| Area | File | New / changed |
|---|---|---|
| L | `spec/services/entity_merge_preview_spec.rb`, `spec/requests/api/v1/graph_data_spec.rb`, `spec/requests/explore/observations_spec.rb` | changed |
| projects | `spec/requests/projects_spec.rb` | new |
| scans | `spec/requests/projects/scans_spec.rb`, `spec/services/project_scan_launcher_spec.rb` | new |
| imports | `spec/requests/projects/imports_spec.rb` | new |
| exports | `spec/requests/projects/exports_spec.rb`, `spec/jobs/export_job_spec.rb` | new / changed |
| old routes | `maintenance_hub_spec`, `project_scans_spec`, `project_scan_skills_spec`, `data_exchange_spec`, `data_exchange_csrf_spec`, `operator/maintenance_spec`, `operator/settings_spec` | changed |
| system | `spec/system/projects_spec.rb`, `navigation_spec.rb`, `content_security_policy_spec.rb` | new / changed |

## Size and split

About **2,600-3,200 changed lines** (about 45% specs): L ~150, P1 ~200, P2 ~300, P3 ~600, P4 ~700, P5 ~350, P6 ~200
(mostly deletions), T ~600 on top of the per-step specs, D ~120, R ~30. Plan on one PR, worked in the three
checkpoints with CI green at each. If the diff passes ~4,000 lines, stop and ask Steve; the natural split is after P3
(scans), with imports and exports as a second PR.

## Open decisions (each with a recommendation; Claude follows the recommendation unless Steve says otherwise)

1. **Where the Maintenance hub's other cards go** (the compactor, the garbage collector, relation repair, the full MCP
   clients table). They aren't Projects & Data, and Review › Generate was never built.
   *Recommendation:* a **"Background jobs"** page under Projects & Data (`/projects/jobs`) for the compactor, garbage
   collector and relation-repair cards as they are. Put the full MCP clients table on System › Telemetry (it's about
   clients). Then `/maintenance` can redirect and the hub really goes. UI-7 may move "Background jobs" under System
   later.
2. **Graphify `graph.json` upload in the UI.** Today it's rake only. *Recommendation:* yes, as P4 describes, with the
   same review as a GraphMem export and the project name asked for up front.
3. **Async import execute.** Today `import_execute` runs in the request. *Recommendation:* keep it synchronous in UI-6
   (the 64 MB cap bounds it) and record the run in the history. An async execute with progress is a follow-up, if a
   real import ever times out.
4. **One scan controller or two.** *Recommendation:* one `Projects::ScansController` and a `ProjectScanLauncher`
   service. The two old controllers become thin wrappers that redirect to the new detail page, until D-6 removes them.
5. **Old URLs.** *Recommendation:* 301s for the `GET` pages (`/maintenance`, `import_review`, `import_report`). Keep
   the old `POST`/`PATCH` routes working (they redirect to the new pages) until §6.D-6, like `/graph` in UI-4b.
6. **`L`'s `ORDER BY`.** *Recommendation:* add `.order(to_column)` (true "lowest ids", as documented). Fall back to
   rewording the docs only if the query plan is unbounded on a hub (see L).

## Acceptance criteria
- The Maintenance hub page is gone (`/maintenance` → 301). Every scan, import and export is reachable from Projects &
  Data, with history (scans, imports and exports listed from `OperationProgress`).
- One scan form (normal + guided) with a live path check that shows the same result as Settings' check. A refused
  path never enqueues a job.
- Import errors stay on the upload page. A Graphify `graph.json` imports through the same review.
- Exports run async with progress, and downloads expire cleanly (410).
- The guest gets 403 from every new route. No CSP violations. No `alert()` / `confirm()` added.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) are green. The
  `OLLAMA_URL=http://127.0.0.1:9` suite is green. The test DB is left with 0 rows. `git diff db/structure.sql` is
  empty (no migration: history lives in `OperationProgress.details`). Synthetic data only.

## Stop and ask Steve if
- A quoted line no longer matches the code.
- Any step needs a migration, a new gem or importmap pin, or a CSP change.
- Import history can't be built from `OperationProgress` without a schema change.
- Moving a `maintenance/` partial breaks a caller not listed above (a doc, a skill file, an MCP tool's text).
- The diff passes ~4,000 lines, or a file passes ~500 lines and can't be split cleanly.
- Decision 1's split doesn't fit (for example, a card needs data that only `MaintenanceDashboardSnapshot` builds and
  can't be shared).
