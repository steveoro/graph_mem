# UI-7 → graph_mem 1.63.0: System (health, one settings schema, backups with a typed restore, access, activity, jobs), plus the #137 leftover

**Status (Oct 29): DONE.** Shipped as UI-7a (#138) and UI-7b (#140, split at S4 and merged into #138), merged to `main` as `501f5d5` and tagged **1.63.0**. The only leftover is §6.D-6 (drop the transition shims, UI-7's included; listed in `ui-dashboard-plan.md` §6.D-6), a separate PR after 1.63.0. Next: fact supersede, `docs/plans/fact-supersede-plan.md` (1.64.0).

**Written 2026-10-29 (Europe/Rome)** for Claude, from `main` at `dddad69` (#137 merged and **tagged 1.62.0**). Every
file:line in "What the code looks like today" was checked against that commit. If a line has moved, find the code by
the quoted text. If the code no longer matches the description, **stop and ask Steve** instead of improvising. Only
code was read while writing this plan. **No spec was run**: the PR is checked by running the suite locally and by CI
(CircleCI: rspec, rubocop, brakeman; Actions: lint, scan_ruby, scan_js).

Context: this file expands `docs/plans/ui-dashboard-plan.md` §6 **"UI-7 [Claude]: System → 1.63.0"** and §2.7, and it
wins where they differ. It also carries the one small leftover from the #137 review (step **L**) and what earlier
plans left for UI-7:
- moving "Background jobs" under System (`ui-6-plan.md` Decision 1);
- moving the guest-access toggle to System › Access (`ui-1-plan.md`), with the MCP access panel (`ui-2-plan.md`);
- System › Activity (`ui-4a-plan.md`, `ui-4b-plan.md`);
- deleting `dashboard.css` (`ui-1-plan.md`, §2.8 "migrate page by page").

**Not in UI-7: §6.D-6** (drop the transition shims). The dashboard plan schedules it "one release after UI-7", so it
stays a separate PR after 1.63.0 (Decision 2). UI-7 adds its own `/operator/*` → `/system/*` shims and lists them
for D-6. The `dm-*` rules in `graph.css` are §6.D-4, also not here.

All of System is operator only (§5.4: guest 403). The dependency (UI-1: shell, design system, roles) is done.

## Brief

| | |
|---|---|
| Branch / PR | `claude/ui-7-system`, **one PR**, titled "System (1.63.0)" |
| Commits | L → S1 … S7 → T → D → R, one commit per step (more is fine, fewer is not; L stays its own commit) |
| Scope | §2.7 and §6 UI-7, minus what "Open decisions" changes, plus L |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, `Dir.mktmpdir` folders as backup and scan roots); never a real graph, a real backup file, a real project folder or real credentials |
| Read first | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `docs/plans/ui-dashboard-plan.md` §0.1, §2.7, §5.2, §5.4; `docs/guides/ui-guide.md` "System" and "The read-only guest"; `docs/app_settings_reference.md`; `docs/mcp_access_control.md` |

## What the code looks like today (verified at `dddad69`)

**#137 leftover (L).** The "capped" hints show when the list holds exactly 500 roots, though nothing was cut:
- `app/views/projects/exports/index.html.haml:23`: `- if @roots.size >= ExportStrategy::ROOT_NODES_LIMIT`;
- `app/views/projects/imports/show.html.haml:63`: `- if @available_parents.size >= ExportStrategy::ROOT_NODES_LIMIT`
  (loaded at `projects/imports_controller.rb:39`);
- `ExportStrategy#root_nodes(query: nil, limit: ROOT_NODES_LIMIT)` (`app/strategies/export_strategy.rb:29,38-45`)
  ends in `.limit(limit).to_a`.

**Routes** (`config/routes.rb`):
- `:3-6` `/api-docs` under `OperatorSessionConstraint`; `:15` `get "up"`.
- `:132` `get "jobs"` inside `namespace :projects` (Background jobs, from #137).
- `:174-204` `namespace :operator`:
  - login/logout `:175-177` (they stay where they are);
  - `maintenance/compaction/start`, `/pause`, `garbage_collection/run`, `relations/repair` `:179-182`;
  - `audit_logs` + `prune` `:184-185`; `telemetry` + `prune` `:187-188`;
  - `embeddings` and its `test_connection`, `backfill`, `regenerate`, `add_indexes`, `drop_indexes` `:190-195`;
  - `settings` (index) and `settings/bulk_update` (PATCH) `:197-198`;
  - `settings/backup/run`, `restore`, `destroy` `:199-201`;
  - `settings/project_scans/check_path` `:202` and `legacy_roots` (DELETE) `:203`.
- `:206` `mount MissionControl::Jobs::Engine, at: "/operator/jobs"`. Its base controller is
  `Operator::JobsDashboardController` (`config/application.rb:41`, `app/controllers/operator/jobs_dashboard_controller.rb`).

**Settings** (`app/controllers/operator/settings_controller.rb`, 286 lines):
- `group_settings_by_category` (145-190) is the only list of groups: `feature_flags` (149, including
  `enable_guest_access`), `database_backup` (153), `embeddings` (157-160), `summaries` (164-167), `imports` (171),
  `project_scans` (175), `telemetry` (179), `review_policies` (`ReviewPolicySettings::KEYS`, 183), `mcp_access`
  (`McpAccessSettings::KEYS`, 187).
- `bulk_update` (16-93) runs one `validate_*_settings` per tab (20-54, bodies 192-260), then the review-policy and MCP
  checks (56-62, 422 on error). It then saves **every** posted key that `AppSettings.defined_fields` knows (66-78),
  whichever tab it came from.
- Backups: `run_backup` / `restore_backup` / `destroy_backup` (110-137) call `BackupFileService`. Restore also runs
  `GraphMem::OfficialMcp.refresh_access!(transports: true)` (122). Restore takes `params[:filename]` with no typed
  confirmation.
- `check_scan_path` (97-100) renders `projects/scans/_path_check`, the same partial as `GET /projects/scans/check_path`.
- `AppSettings` (`app/models/app_settings.rb`) defines 41 fields. Not in any group: `enable_contradiction_detection`
  (10; **unreachable from the UI**), `project_scan_validation_batch_size` (48; rendered by `_project_scans_panel.html.haml:81-90`
  but not listed in the group) and `project_scan_roots` (46; legacy, ignored since 1.54, cleared by `legacy_roots`).
- Labels and help live in `config/locales/operator_settings.en.yml` under `operator.settings.fields` (77-186).
  `enable_contradiction_detection` and `enable_stale_memory_scan` have no entry (the view falls back to `humanize`).
- `app/views/operator/settings/index.html.haml` (136 lines) holds the tabs (8-14), an `if/elsif` over six bespoke
  partials (20-31), the generic field loop (33-87) and the backup actions and table (89-136, `turbo_confirm` at 97,
  124, 132). The partials are `_embeddings_panel` (98), `_summaries_panel` (90), `_imports_panel` (32),
  `_project_scans_panel` (125), `_review_policies_panel` (36) and `_mcp_access_panel` (45).

**Other operator pages.** `operator/embeddings_controller.rb` (70), `telemetry_controller.rb` (56),
`audit_logs_controller.rb` (34), `maintenance_controller.rb` (57; every action redirects to `projects_jobs_path`, 7-41).
Confirms today: `embeddings/index.html.haml:90` (regenerate), `:100` (add indexes), `:108` (drop indexes),
`audit_logs/index.html.haml:47` (prune), `telemetry/index.html.haml:93` (prune), all `turbo_confirm`.
§5.2 wants **typed** confirmation for backup restore, drop indexes, regenerate all embeddings and prune audit log.
Nothing in `app/javascript/controllers/` does typed confirmation yet.

**Background jobs.** `Projects::JobsController#index` (`app/controllers/projects/jobs_controller.rb`, 15 lines; its
comment at 5 says "UI-7 may move the page under System") loads `MaintenanceDashboardSnapshot.call` (100 lines) and
renders `projects/jobs/index.html.haml` with `_dream_state_compactor_card`, `_garbage_collector_card` and
`_reports_details`.

**Health.** `HomeSnapshot::Health` (`app/services/home_snapshot/health.rb`, 140 lines) builds Home's pills: database,
embeddings (with a 1 s probe, 27-37), summaries, jobs (`queue_stats` 50-57), backup (`last_backup_at` 60-64,
fresh 36 h / stale 7 d), scans (`ScanRootPolicy.status`), MCP (`access_policy.describe`) and guest
(`GuestCredentials#status`: `:not_configured`, `:conflict`, `:disabled`, `:available`, `lib/graph_mem/guest_credentials.rb:88-94`).
Its hrefs point at `operator_*` paths (74-137). There is no health page and no JSON.

**Access.** Session lifetimes are constants in `app/controllers/concerns/session_authentication.rb:9-12` (operator 24 h
idle / 7 d absolute, guest 2 h / 24 h). The production fallback-password check is
`Operator::SessionsController#production_fallback_credentials?` (87). The MCP token state is
`GraphMem::OfficialMcp.access_policy` (`lib/graph_mem/mcp_access_policy.rb:73` `token_required?`, `:121` `describe`).

**Activity.** `HomeSnapshot#activity` (`app/services/home_snapshot.rb:66-67`) shows the latest `ChangeSet`s; there is
no full list. `ChangesController#undo` (`app/controllers/changes_controller.rb:12`) is the one undo endpoint.
Review › Policies already lists the policy runs with Undo (`app/views/review/_view_policies.html.haml`, linking to
Settings at 5).

**Links into the old paths** (outside `operator/`): `ui/_sidebar.html.haml:37,40-46`; `home/_jobs.html.haml:36`
(`"/operator/jobs"`); `home/_activity.html.haml:21`; `home/_clients.html.haml:18`; `projects/index.html.haml:7`;
`projects/scans/_folders.html.haml:10,19`; `review/_view_policies.html.haml:5`; `home_snapshot/health.rb` (8 hrefs).
Docs: `docs/guides/ui-guide.md:55-60,195-202`, `docs/operator/embeddings.md`, `docs/summarization.md`,
`docs/garbage_collector.md`, `docs/mcp_access_control.md`, `docs/app_settings_reference.md`, `docs/development.md`,
`README.md`.

**`dashboard.css`** (`app/assets/stylesheets/dashboard.css`, 1,202 lines) is loaded by `layouts/_head.html.haml:13`.
Its `dashboard-*` classes are still used by every `operator/` view, the three `projects/jobs/` partials,
`projects/scans/_path_check.html.haml`, `app/helpers/{dashboard,audit_logs,summarization,embeddings}_helper.rb`,
`app/helpers/operator/telemetry_helper.rb` and `operation_progress_controller.js:58-65` (`dashboard-badge--*`).
Pages built since UI-1 use the `ui-*` components (`app/assets/tailwind/application.css`) plus one file per area
(`home.css`, `search.css`, `explore.css`, `projects.css`, imported at 2-5).

**Roles.** `RoleAuthorization` is deny-by-default (`allow_guest` opts in). `spec/requests/role_matrix_spec.rb` walks
every route. It hardcodes Mission Control at `"/operator/jobs…"` (59, 176).

**Version.** `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` say `1.62.0`. `CHANGELOG.md`
has `## [1.62.0] - 2026-10-29` on top.

## Steps

### L. #137 leftover (own commit, first)
- Fetch one more than the cap, show at most the cap, and show the hint only when something was cut. Both callers pass
  `limit: ExportStrategy::ROOT_NODES_LIMIT + 1`, keep `first(ROOT_NODES_LIMIT)` and set `@roots_capped` /
  `@parents_capped` from `size > ROOT_NODES_LIMIT`. Leave the strategy's default `limit` and the JSON
  `data_exchange#root_nodes` caller as they are.
- Specs (stub `ROOT_NODES_LIMIT` to 3): exactly 3 roots → no hint; 4 → 3 listed and the hint
  (`spec/requests/projects/exports_spec.rb`, `spec/requests/projects/imports_spec.rb`).

**Checkpoint 1:** L pushed; full suite, rubocop, brakeman and the three Actions jobs green. **Open the PR as a draft
now.**

### S1. `System::` namespace, routes, nav, shims
- `namespace :system` with `System::BaseController` (operator only, no `allow_guest`, a `nav_section` like
  `Projects::BaseController`):
  - `GET /system` → 301 to `/system/health`;
  - `health` (show, `.json`), `settings` (show with `?tab=`, `update`), `backups` (index, create = run now,
    `restore`, `destroy`), `access` (show, update), `activity` (index), `audit_log` (index, prune),
    `telemetry` (index, prune), `embeddings` (index + the five actions), `jobs` (index + compaction start/pause,
    garbage collection run, relations repair).
- Move the controllers: `Operator::{Embeddings,Telemetry,AuditLogs,Maintenance}Controller` →
  `System::{Embeddings,Telemetry,AuditLog,Jobs}Controller`; `Projects::JobsController` → `System::JobsController`
  (Decision 1). Views move with them. Keep `Operator::SessionsController` (login/logout stay at `/operator/login`).
- Mission Control: mount at `/system/queue` and rename its base controller `System::QueueDashboardController`
  (Decision 1). Update `config/application.rb:41`.
- Sidebar: the System group lists Health, Settings, Backups, Access, Activity, Audit log, Telemetry, Embeddings,
  Background jobs, Queue (Mission Control, `turbo: false`) and API docs. Projects & Data loses "Background jobs".
  `testid`s `nav-system-*`; keep `nav-settings`, `nav-embeddings`, `nav-telemetry`, `nav-audit-logs`, `nav-jobs` and
  `nav-api-docs` with the same meaning. Locale keys go in a new `config/locales/system.en.yml`.
- Shims (kept until §6.D-6; Decision 2):
  - `GET` 301s: `/operator/settings` (keeping `tab`), `/operator/embeddings`, `/operator/telemetry`,
    `/operator/audit_logs`, `/projects/jobs`, `/operator/jobs(/*rest)` → `/system/queue/*rest`;
  - the old `POST`/`PATCH`/`DELETE` routes stay, routed to the new actions (no copy of the code), so an open old tab
    still works;
  - list every shim in a comment block in `routes.rb` headed "until §6.D-6".
- Repoint every link listed under "Links into the old paths" to the new helpers.

### S2. `SettingsSchema`: one source for every field
- `app/services/settings_schema.rb`: a frozen, ordered list of groups. Each group has a key, a title key, a page
  (`:settings`, `:backups` or `:access`) and its fields. Each field has: key, type (from `AppSettings.get_field`),
  label and help (i18n keys under `system.settings.fields.<key>`), the validation (read from `AppSettings`'
  `validates:`, plus a per-field validator for the checks that live in the controller today), `readonly`, and an
  optional `partial` for a field that needs a custom input.
- Groups (Decision 4): feature flags (`enable_dream_state_compactor`, `enable_garbage_collector`,
  `enable_stale_memory_scan`, `enable_contradiction_detection`), embeddings, summaries, imports, project scans (with
  `project_scan_validation_batch_size`), telemetry & retention, review policies (Settings page); backups (Backups
  page); access (`enable_guest_access` + the three MCP allowlists; Access page).
- `SettingsSchema::LEGACY_KEYS = %w[project_scan_roots]`: in no group, never rendered, never written by `update`.
- Move the `validate_*_settings` bodies (`settings_controller.rb:192-260`) into the schema's validators, unchanged in
  behaviour (same messages, same normalising of `project_scan_subfolders`). `ReviewPolicySettings` and
  `McpAccessSettings` stay as concerns and are called through the schema.
- `update` accepts **only the keys of the posted group** (today it saves any defined key, 66-78). Any invalid key →
  422 with the form re-rendered and nothing saved (today it is a redirect with a flash for four tabs and a 422 for two).
- Labels: move `operator.settings.fields.*` to `system.settings.fields.*`, and add the two missing entries
  (`enable_contradiction_detection`, `enable_stale_memory_scan`) with a one-line help each.

### S3. Settings page, rendered from the schema
- `System::SettingsController#show` renders the tabs and the active group from `SettingsSchema`. One generic
  `system/settings/_field.html.haml` per type: boolean switch, integer/float with its range shown, string,
  read-only. Use `ui-*` form components.
- The bespoke tab partials shrink to the live state they show **around** the fields (Decision 4): embeddings
  (provider status, dims warning), summaries (the client status), project scans (mounts, the path check frame via
  `GET /projects/scans/check_path`, the legacy-roots clear button), review policies (the §2.5.3 table, linking to
  Review › Policies for the runs). Fields inside them render through `_field`. Imports and telemetry need no partial.
- After a save, the same side effects as today: `EmbeddingService.reset_instance!` (`settings_controller.rb:84`),
  `SummaryGenerationClient.reset_instance!` (85), the review-policy audit rows (80) and
  `apply_mcp_access_changes` (81).
- Delete `operator/settings/index.html.haml` and the six partials once their content has moved.

### S4. Backups page with a typed restore
- `System::BackupsController`: the backup settings (schema group), "Run backup now", the files table (name, size,
  date), Restore and Delete per file.
- Typed confirmation (Decision 5): Restore opens a confirm card (`ui-card`, no `confirm()`) that asks to type the
  file name. The server checks `params[:confirmation] == params[:filename]` and answers **422** with the card
  re-rendered when it doesn't match; nothing is restored. A small `typed_confirm_controller.js` enables the button
  only when the text matches (cosmetic; the server check is the guard). Delete keeps `turbo_confirm`.
- Keep `BackupFileService` as it is: `SAFE_BACKUP_FILENAME` (`backup_file_service.rb:9`) and `resolve_safe_path!` (65)
  stay the only way to a file. Keep the `refresh_access!` call after a restore (`settings_controller.rb:122`).
- Use the same typed-confirm card for **drop indexes** ("DROP"), **regenerate all embeddings** ("REGENERATE") and
  **prune audit log** (the number of rows to prune), each checked server-side with 422 on a mismatch. Telemetry prune
  and add indexes keep `turbo_confirm` (§5.2 doesn't list them).

### S5. Health page and JSON
- `SystemHealth` (`app/services/system_health.rb`) reuses `HomeSnapshot::Health` (no second probe code) and adds:
  - the embedding probe latency (time the existing `embedding_reachable?` call);
  - vector readiness (`EmbeddingStatusSnapshot.call[:vector_search_ready]`);
  - Solid Queue backlog and failed count (`queue_stats`);
  - the last backup age;
  - each scan root and whether it is mounted read-only (`ScanRootPolicy.status[:hard_roots]`);
  - the MCP access mode (`describe`);
  - the app version and whether migrations are pending
    (`ActiveRecord::Base.connection_pool.migration_context.needs_migration?`).
- `GET /system/health` shows one `ui-card` row per check with status in words (never colour alone), and a collapsed
  **"Raw snapshots"** section with `MaintenanceDashboardSnapshot`, `EmbeddingStatusSnapshot` and
  `ScanRootPolicy.status` as escaped, pretty-printed JSON (this is §2.7's "Diagnostics"; Decision 3).
- `GET /system/health.json`: `{ "version", "status" (worst of the checks), "generated_at", "checks": [{ "key",
  "status", "value" }] }`. No paths, URLs, hostnames or setting values in the JSON. Operator only, like the page
  (monitors use `/up`).
- Disk free is left out (Decision 6).
- Home's pills link to the new pages (S1); their logic doesn't change.

### S6. Access, Activity, Background jobs
- **Access** (`System::AccessController`):
  - status rows: operator credentials (configured / the production fallback is refused, using the sessions
    controller's check moved into a small `OperatorCredentials` helper both call), guest
    (`GuestCredentials#status`, each of the four states in words), MCP token required or not, the session
    lifetimes (from the constants);
  - the guest toggle and the three MCP allowlists, from the schema's access group; `update` runs the same MCP checks
    and `apply_mcp_access_changes` as today. The toggle and every write are operator only (guest 403).
  - `enable_guest_access` leaves Settings › Feature flags.
- **Activity** (`System::ActivityController#index`): `ChangeSet`s newest first, 50 per page, each with its summary,
  actor, time and Undo (`undo_change_path`, only when `undoable?`). Home's "audit log" link goes to Activity, which
  links to the Audit log.
- **Background jobs** (`System::JobsController`): the page and its three cards as they are, plus a link to Queue.
  The compaction/GC/repair actions move here and redirect to `system_jobs_path`.

### S7. Restyle and delete `dashboard.css`
- Move every remaining `dashboard-*` user to `ui-*` components plus a new `app/assets/tailwind/system.css`
  (`system-*` classes), imported in `application.css`: the moved embeddings, telemetry, audit log, jobs and settings
  views, `projects/scans/_path_check.html.haml`, the five helpers and `operation_progress_controller.js` (rename the
  badge classes to the `ui-badge` modifiers; keep the controller's behaviour).
- Delete `app/assets/stylesheets/dashboard.css` and its `stylesheet_link_tag` (`layouts/_head.html.haml:13`). Rename
  `DashboardHelper` if nothing "dashboard" is left in it.
- Check: `rg -n "dashboard-" app` → nothing.

**Checkpoint 2:** S1-S7 pushed. Every page in §2.7 is reachable under `/system`, the old URLs redirect, and
`dashboard.css` is gone. CI is green.

### T. Specs (beyond the ones listed per step)
- Request specs under `spec/requests/system/`, one per page, each with guest 403 and signed-out → login:
  - `settings_spec.rb`: every tab renders; a save per type; an out-of-range value → 422 and nothing saved; a key
    posted under another group's tab is ignored; the side effects (embedding/summary client reset, review audit
    rows, MCP refresh);
  - `backups_spec.rb`: run, list, delete; restore with the typed name → `BackupFileService#restore!` called;
    a wrong or missing confirmation → 422 and not called; a path-like filename refused;
  - `health_spec.rb`: page 200; the JSON shape (keys, status values from `HomeSnapshot::Health::STATUSES`, no path
    or URL in the body);
  - `access_spec.rb`: guest state shown for not configured / available / turned off (and conflict); the toggle saves
    for the operator; a guest `PATCH` → 403;
  - `activity_spec.rb`: paginated list, Undo shown only for an undoable set;
  - `embeddings_spec.rb`, `audit_log_spec.rb`: typed confirmation for drop indexes, regenerate and prune (422 on a
    mismatch);
  - `jobs_spec.rb`: the page, the four actions redirect to `/system/jobs`.
- `spec/services/settings_schema_spec.rb`: every `AppSettings.defined_fields` key is in **exactly one** group or in
  `LEGACY_KEYS`; every field has a label and help in the locale file; every validator matches the old behaviour
  (the cases from the current `operator/settings_spec.rb`).
- Move the existing `spec/requests/operator/{settings,embeddings,telemetry,audit_logs,maintenance,mcp_access_settings,review_policy_settings}_spec.rb`
  to the new paths, and keep a short redirect/alias spec per old route. Don't delete coverage.
- `role_matrix_spec`: Mission Control under `/system/queue`; no entry added to `guest_allowed`.
- Extend `navigation_spec` and the CSP system spec to `/system/health`, `/system/settings`, `/system/backups` and
  `/system/access`. A system spec for the typed restore card (button disabled until the name matches).

### D. Docs
- `docs/guides/ui-guide.md`: the nav table (55-60), "System" (195-202) rewritten, the guest 403 list, the "Turning it
  on/off" steps (guest toggle now on System › Access).
- `docs/app_settings_reference.md`: group names as in the schema; the two new labels.
- Repoint `/operator/*` paths in `docs/operator/embeddings.md`, `docs/summarization.md`, `docs/garbage_collector.md`,
  `docs/mcp_access_control.md`, `docs/development.md` and `README.md`.
- `docs/architecture.md`: `SettingsSchema`, `SystemHealth`, the typed confirmation.
- `docs/plans/ui-dashboard-plan.md`: row 22 ✅ with the PR number; append UI-7's shims to §6.D-6.

### R. Release 1.63.0
- `lib/graph_mem/version.rb` → `1.63.0`, and `skills/graph-mem-mcp-toolset/SKILL.md:18` →
  `graph-mem-version: "1.63.0"`.
- CHANGELOG: add `## [1.63.0] - <date>`, with:
  - a one-line summary: "System: health, one settings schema, backups with a typed restore, access and activity";
  - Added (Health + JSON, Backups, Access, Activity, typed confirmations);
  - Changed (operator pages moved under `/system` with 301s, Background jobs moved, Mission Control at
    `/system/queue`, settings saves only the posted group, 422 on invalid values);
  - Removed (`dashboard.css`);
  - Fixed (L; `enable_contradiction_detection` reachable).
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** R pushed; everything in "Acceptance criteria" holds. Mark the PR ready for review.

## Security checklist (against the #106 baseline)
- **Auth:** every `System::` action is operator only (no `allow_guest`), Mission Control included. The role matrix
  proves it. The health JSON is operator only.
- **CSRF:** on for every write (settings, backups, access, prunes, embeddings, jobs). The aliased old routes keep it.
- **Typed confirmation is server-side:** a missing or wrong `confirmation` → 422 and no side effect, whatever the JS
  does.
- **Path safety:** backup files only through `BackupFileService#resolve_safe_path!`; no path from params reaches
  `File` or a shell anywhere else.
- **No secret on any page or JSON:** credentials show as configured / not configured, never their value or length;
  the MCP token likewise; the health JSON carries no paths, URLs or hostnames.
- **Mass assignment:** `update` writes only the posted group's schema keys; `LEGACY_KEYS` and read-only fields are
  never written.
- **XSS / CSP:** HAML escaping; the raw snapshots are escaped JSON in `<pre>`; no `html_safe` / `raw`; no inline
  scripts; no `alert()` / `confirm()`.

## Specs (summary)

| Area | File | New / changed |
|---|---|---|
| L | `spec/requests/projects/exports_spec.rb`, `spec/requests/projects/imports_spec.rb` | changed |
| schema | `spec/services/settings_schema_spec.rb` | new |
| pages | `spec/requests/system/{settings,backups,health,access,activity,embeddings,audit_log,telemetry,jobs}_spec.rb` | new (moved from `operator/` where they exist) |
| health | `spec/services/system_health_spec.rb` | new |
| old routes | the redirect/alias specs, `spec/requests/projects/jobs` coverage, `role_matrix_spec.rb` | changed |
| system | `navigation_spec.rb`, `content_security_policy_spec.rb`, a typed-restore spec | new / changed |

## Size and split

About **3,400-4,200 changed lines**, of which ~1,200 are the deleted `dashboard.css` and ~600 moved specs: L ~60,
S1 ~350, S2 ~450, S3 ~500, S4 ~350, S5 ~300, S6 ~400, S7 ~1,500 (mostly the CSS deletion and class renames),
T ~600 on top of the per-step specs, D ~150, R ~30. Plan on one PR, worked in the three checkpoints with CI green at
each. If the diff passes ~5,000 lines (counting the CSS deletion), stop and ask Steve; the natural split is after S4
(namespace, schema, settings, backups as UI-7a; health, access, activity, restyle and the CSS deletion as UI-7b, with
the release in UI-7b).

## Open decisions (each with a recommendation; Claude follows the recommendation unless Steve says otherwise)

1. **Background jobs and Mission Control.** *Recommendation:* move Background jobs to `/system/jobs` (it is System,
   not Projects & Data; `ui-6-plan.md` Decision 1 left this to UI-7), and mount Mission Control at `/system/queue`
   with a 301 from `/operator/jobs(/*rest)`. If the engine's own redirects or assets break under the new mount, keep
   the mount at `/operator/jobs`, label it "Queue" in the System group, and say so in the PR.
2. **§6.D-6 (drop the shims).** It is scheduled "one release after UI-7", so it is **not** in UI-7.
   *Recommendation:* keep it a separate PR after 1.63.0 that removes all the shims at once: the `/graph`,
   `/maintenance`, `/data_exchange/compaction_review` and UI-6 redirects, the old `data_exchange` `export_async` /
   `download_export` endpoints, the old `project_scans` / `project_scan_skills` routes, `ExportProgressChannel`, the
   legacy `session[:operator_signed_in]` read (`session_authentication.rb:22`, `api/v1/base_controller.rb:34`), and
   UI-7's `/operator/*` aliases. UI-7 appends its shims to the D-6 list. Pulling D-6 into UI-7 would break the
   one-release grace period for UI-7's own redirects.
3. **Policies and Diagnostics pages.** §6 lists `system/{policies,diagnostics}_controller.rb`. *Recommendation:* no
   separate pages. The policy toggles are the Settings › Review policies group; the runs stay on Review › Policies
   (already built in UI-5, with Undo). Diagnostics is the collapsed "Raw snapshots" section on Health. Two fewer
   controllers, nothing lost.
4. **How generic the settings rendering gets.** *Recommendation:* every field renders through the schema's `_field`
   partial. Tabs that show live state (embeddings, summaries, project scans, review policies) keep a slim partial
   **around** the fields; imports, telemetry and feature flags have none. Backups and Access are their own pages but
   read the same schema.
5. **Typed confirmation mechanism.** *Recommendation:* a `ui-card` confirm form with a text field, checked on the
   server (422 on a mismatch), plus `typed_confirm_controller.js` to enable the button (picked up by the existing
   `pin_all_from "app/javascript/controllers"`, so no new pin). Restore types the file name; drop indexes types
   "DROP"; regenerate types "REGENERATE"; audit-log prune types the row count shown.
6. **Disk free on Health** (§7 lists it). Ruby has no portable `statvfs`, and a shell-out or a new gem is out of
   scope. *Recommendation:* leave it out; show whether the backup folder exists and is writable instead. Add disk
   free later if Steve wants it.
7. **Settings validation errors.** Today four tabs redirect with a flash and two answer 422. *Recommendation:* all
   answer 422 with the form re-rendered and the bad field marked, nothing saved.

## Acceptance criteria
- Every `AppSettings` field is reachable from exactly one place (Settings, Backups or Access), except the documented
  legacy key. `enable_contradiction_detection` is reachable.
- `/system/health` and `/system/health.json` exist, operator only, with the JSON shape above.
- Backup restore, drop indexes, regenerate all embeddings and audit-log prune need typed confirmation, checked
  server-side (422). Other confirms follow §5.2.
- Access shows guest state for not configured / conflict / turned off / available; only the operator can change it.
- Embeddings, Telemetry, Audit log, Settings and Background jobs live under `/system`; the old `GET` URLs 301; the old
  writes still work until §6.D-6.
- `dashboard.css` is deleted and `rg -n "dashboard-" app` finds nothing.
- The guest gets 403 from every `/system` route and Mission Control. No CSP violations. No `alert()` / `confirm()`
  added.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) are green. The
  `OLLAMA_URL=http://127.0.0.1:9` suite is green. The test DB is left with 0 rows. `git diff db/structure.sql` is
  empty (no migration). Synthetic data only.

## Stop and ask Steve if
- A quoted line no longer matches the code.
- Any step needs a migration, a new gem or importmap pin, or a CSP change.
- Mission Control doesn't work under `/system/queue` and keeping `/operator/jobs` doesn't fit either (Decision 1).
- A settings validator can't move into the schema without changing what a stored value means.
- Moving a page breaks a caller not listed above (a doc, a skill file, an MCP tool's text).
- The diff passes ~5,000 lines, or a file passes ~500 lines and can't be split cleanly.
