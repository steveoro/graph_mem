# D-6 cleanup + audit actor → graph_mem 1.65.0: drop the transition shims, and record who wrote what through MCP

**Written 2026-10-30 (Europe/Rome)** for Claude, from `main` at `089ae2d` (#141 merged, **tagged `v1.64.0`**). Every
file:line in "What the code looks like today" was checked against that commit. If a line has moved, find the code by
the quoted text. If the code no longer matches the description, **stop and ask Steve** instead of improvising. Only
code was read while writing this plan. **No spec was run.**

Context: two independent pieces in one PR, each in its own commits.
- **Part A, §6.D-6** (`ui-dashboard-plan.md` §6.D-6, `ui-7-plan.md` Decision 2): the redirects and old endpoints kept
  "one release" after UI-4b, UI-5b, UI-6 and UI-7 are now overdue. Remove them all at once.
- **Part B, the audit actor** (found Oct 30 on a running instance): every write made through MCP shows no Actor
  and no Reason on System › Audit log, and Home › Recent activity shows every MCP change as `unknown: Graph.write`.
  The agents are not at fault: they already send `source` in the documented `"<client>/<model>: <task>"` form. The
  server never sets the actor for MCP calls, and only writes a reason for deletes.

## Brief

| | |
|---|---|
| Branch / PR | `claude/d6-cleanup`, **one PR**, titled "D-6 cleanup + audit actor (1.65.0)" |
| Commits | A1 → A2 → A3 → B1 … B6 → T → D → R, one commit per step (more is fine, fewer is not) |
| Version | **1.65.0** (default, Decision 1): a migration plus removed routes is more than a patch |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, client ids like `synth-client-a`, `Dir.mktmpdir` folders); never a real graph, a copy of one, a real project folder or a real host or user name |
| Read first | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`; `docs/plans/ui-dashboard-plan.md` §6.D-6; `docs/plans/ui-7-plan.md` Decision 2; `docs/architecture.md` "Change sets and undo" |
| Depends on | 1.64.0 on `main` ✅ (it is the "one release after UI-7" that D-6 waited for) |
| MCP surface | **unchanged**: no new tool, no new or changed tool argument; default `/mcp` stays at **12**, readonly 9, maintenance 22, 22 classes; `spec/fixtures/mcp/snapshots/*.json` byte-identical |

## Goal
- Old URLs answer 404 (routing error) instead of 301; the old POST/PATCH/DELETE endpoints, their controllers and
  their only-for-shims code are gone; the legacy `session[:operator_signed_in]` key no longer signs anyone in.
- Every audit row and change set written by an MCP tool has an actor (`mcp:<tool>`), a **claimed** identity (what the
  client and the model say about themselves, recorded and shown as "claimed", never trusted for authorization), and,
  where one exists, a reason.
- Home › Recent activity and System › Activity show `mcp:graph_write` instead of `unknown`.
- Existing rows inside the retention window can be backfilled by a manual rake task.

## What the code looks like today (verified at `089ae2d`)

### Part A: the shims
Routes (`config/routes.rb`):
- `:108` comment, `:124` `get "graph"` → 301 `/explore` (UI-4b).
- `:125-127` `resources :project_scans, only: [ :create ]`, `resources :project_scan_skills, only: [ :create, :update ]`
  (the Maintenance hub's scan forms; UI-6). Controllers: `app/controllers/project_scans_controller.rb` (16 lines),
  `app/controllers/project_scan_skills_controller.rb` (27 lines), both headed "kept until §6.D-6".
- `:128-130` `get "maintenance"` → 301 `/projects` (UI-6), plus the anchor forwarder on the Projects page:
  `app/views/projects/index.html.haml:4-6` (`data-controller="legacy-anchor"`) and
  `app/javascript/controllers/legacy_anchor_controller.js` (12 lines).
- `:149-151` `get "data_exchange/compaction_review"` → 301 `/review` or `/review?view=scan` (UI-5b).
- `:224-260` the **UI-7 block** ("UI-7 shims, until §6.D-6 (drop them all in that PR)"): `keep_query` (`:230`),
  `legacy_settings_pages` (`:231`), GET 301s for `/operator/settings` (`:232-234`, incl. `tab=database_backup` →
  `/system/backups`, `tab=mcp_access` → `/system/access`), `/operator/settings/project_scans/check_path` (`:235`),
  `/operator/embeddings` (`:236`), `/operator/telemetry` (`:237`), `/operator/audit_logs` (`:238`), `/projects/jobs`
  (`:239`), `/operator/jobs(/*rest)` → `/system/queue/*rest` (`:240-242`); and the old writes under `/operator`
  routed to the System actions (`:243-260`: compaction start/pause, GC run, relations repair, audit/telemetry prune,
  five embeddings actions, `patch settings`, backup run/restore/destroy, legacy scan roots).
- **Keep** `:177-181` (`/operator/login`, `/operator/logout`): they are the live sign-in routes, not shims.
- **Keep** `:184` (`get "system"` → `/system/health`): a live alias, not a shim.

Old `data_exchange` endpoints (`config/routes.rb:72-99`, `app/controllers/data_exchange_controller.rb`):
- Shims, "kept until §6.D-6" (`data_exchange_controller.rb:88-89`): `import_upload` (`:92`), `import_review` (`:101`,
  301), `import_execute` (`:108`), `import_report` (`:119`, 301), `import_cancel` (`:125`).
- `export_async` (`:28`) and `download_export` (`:49`): JSON, "Nothing in the UI calls them" (`ui-6-plan.md:108`),
  listed for D-6 in `ui-7-plan.md` Decision 2, with `app/channels/export_progress_channel.rb` (74 lines; "stays until
  D-6", `ui-6-plan.md:211`). `ExportJob` broadcasts to it at `app/jobs/export_job.rb:122/130/134`.
- **Keep** (live): `export`, `root_nodes`, `entity_search` (called by
  `app/javascript/controllers/review_entity_picker_controller.js:22`), `orphan_nodes`, `move_node`, `merge_node`,
  `delete_node`, `duplicate_relations`, `delete_duplicate_relations`, `create_relation`, `update_relation`,
  `delete_relation`. They are not in the D-6 list; leave them alone.
- `app/services/import_flow.rb:5-7` says it is shared with "the old /data_exchange endpoints (until §6.D-6)": reword.

Settings and session shims:
- `System::SettingsController::LEGACY_TABS` (`app/controllers/system/settings_controller.rb:12-13`, used at `:48`).
- `SettingsGroupUpdate#elsewhere_notice` (`app/controllers/concerns/settings_group_update.rb:32`, `:36-43`): the "Not
  saved from this tab" notice for a stale tab's key (Decision 3).
- Legacy session key `operator_signed_in`: `app/controllers/concerns/session_authentication.rb:20-22`,
  `app/controllers/api/v1/base_controller.rb:34` (`!session[:operator_signed_in]` in the CSRF skip),
  `app/constraints/operator_session_constraint.rb:9`, `app/channels/application_cable/connection.rb:22-23`.
  Note: the **method** `operator_signed_in?` (`session_authentication.rb:28`, helper at `:15`) is live and stays; only
  the session **key** goes.

Specs that exist only for the shims:
- `spec/requests/system/legacy_routes_spec.rb` (46 lines, whole file).
- `spec/requests/maintenance_hub_spec.rb` (59 lines, whole file).
- `spec/requests/project_scans_spec.rb` (83), `spec/requests/project_scan_skills_spec.rb` (111), whole files.
- `spec/channels/export_progress_channel_spec.rb` (77), whole file; `spec/jobs/export_job_spec.rb:27-28, 60-61,
  74-76, 111-114, 138-139` stub or expect `ExportProgressChannel`.
- `spec/requests/explore_spec.rb:81-92` (the `/graph` redirect).
- `spec/requests/review_spec.rb:211-216` and `:253` (the old review URL).
- `spec/requests/data_exchange_spec.rb`: `import_upload` (`:130`), `import_review` (`:199`), `import_execute`
  (`:263`, the largest block, to `:564`), `import_report` (`:565`), `import_cancel` (`:610`), `export_async`
  (`:814`), `download_export` (`:835`). `:638` also hits `import_review`.
- `spec/requests/system/backups_spec.rb:137-147`, `spec/requests/system/access_spec.rb:94`, `:117-126`,
  `spec/requests/system/settings_spec.rb:164` (`tab: "database_backup"`).
- `spec/channels/application_cable/connection_spec.rb:22-` (legacy key).

Docs that name the old paths (outside `docs/plans/`): `docs/guides/ui-guide.md:96` (`/maintenance` redirects),
`:126` (the old `/graph`), `:215` (the old `/operator/*` and `/projects/jobs` URLs); `docs/app_settings_reference.md:119`
("`/operator/jobs` redirects until §6.D-6").

### Part B: actor and reason
- Table `audit_logs` (`db/structure.sql:45-59`): `actor varchar(255) NULL`, `reason varchar(255) NULL`,
  `changed_fields` JSON, `change_set_id`. Model `app/models/audit_log.rb`: exact-match `with_actor` (`:18`),
  `MAX_AGE_DAYS = 90` (`:21`).
- `app/models/current.rb:3-8`: `Current` attributes `actor`, `deletion_reason`, `change_set`.
- `app/models/concerns/auditable.rb`: callbacks `:7-9` → `write_audit` (`:33`) writes `actor: Current.actor` (`:39`)
  and `reason: action == "delete" ? Current.deletion_reason : nil` (`:41`). Create/delete rows snapshot all attributes
  but `embedding`, so an observation's `source` is in `changed_fields`; update rows hold only the changed keys.
- `ChangeSet.record(kind:, summary: nil, subject: nil, actor: Current.actor, undo_of: nil)` (`app/models/change_set.rb:57`).
  MCP writes open `graph.write` (`app/services/graph_write_service.rb:80`, `:186`), `graph.edit`
  (`graph_edit_service.rb:26`, `:43`), `graph.delete` (`graph_delete_service.rb:71`, `:132`), with no summary.
- **Root cause.** `ApplicationTool#call` (`app/tools/application_tool.rb:101-104`) is the only place MCP sets
  `Current.actor = "mcp:#{tool_name}"`, but every tool defines its own `call` without `super`
  (`graph_write_tool.rb:102`, `graph_edit_tool.rb:69`, `graph_delete_tool.rb:31`, and all others), so it never runs:
  `call_with_schema_validation!` calls `call(**normalized)` (`:75`) straight into the subclass. `/mcp` is Rack
  middleware (`config/initializers/mcp.rb:27-29`), so `ApplicationController#set_current_actor`
  (`app/controllers/application_controller.rb:10`, `:35-45`) never applies either. `Current.actor = nil` in the
  `ensure` (`:98`) stays. The spec at `spec/tools/application_tool_spec.rb:319-327` calls the base method through
  `bind_call`, which hides the bug. The pattern dates from the fast-mcp days, so no MCP write has ever had an actor.
- The web UI (`operator:<user>@<ip>`, `guest:…`) and REST (`api:<X-MCP-Client>`, else `<ip|local>:<controller>`)
  already fill the actor through `set_current_actor`. REST has one shared bearer token (`GRAPH_MEM_MCP_TOKEN`,
  `app/controllers/concerns/api_authentication.rb:74-83`), so there is no token name to record.
- Identity the server has for an MCP call but doesn't use:
  - `X-MCP-Client` → `RequestContext::Context.client_id` (`lib/graph_mem/official_mcp/request_context.rb:51`) →
    `ApplicationTool#current_client_id` (`application_tool.rb:110-116`); used for `AgentContext` and telemetry only.
  - The MCP `initialize` `clientInfo` (`{ name:, version: }`): the `mcp` gem 1.8.2 stores it per session
    (`MCP::ServerSession#store_client_info`) and exposes it as `MCP::ServerContext#client_info`. graph_mem's wrapper
    receives that `server_context` (`lib/graph_mem/official_mcp/tool_wrapper.rb:40-41`) but only reads its
    `auth_info` claims (`request_context.rb:38-42`). Over stdio, or a client that sends none, it is nil.
  - `set_context` (`app/tools/set_context_tool.rb`) stores only the active project, no identity.
- What the agents are told: `graph_write` `source` "Who/what this came from, e.g. \"claude-code/opus: release task\""
  (`graph_write_tool.rb:59`); the persist prompt says `source ("<client>/<model>: <task>")`
  (`app/prompts/persist_prompt.rb:23`). `graph_edit` has `reason` (`graph_edit_tool.rb:54`) for supersede, stored in
  `obsolescence_reason`; `graph_delete` passes a per-operation `reason` to `with_deletion_reason`
  (`graph_delete_service.rb:325-329`), but its soft delete (`mark_obsolete!`, `:235`) is an update, so the audit
  `reason` column stays empty there too.
- Display: Audit log `app/views/system/audit_log/index.html.haml:60` (reason), `:62` (actor);
  `app/helpers/audit_logs_helper.rb:50-55` show "—" (`config/locales/operator_audit_logs.en.yml:43`) when blank.
- **Recent activity.** Home's widget `app/views/home/_activity.html.haml:11` builds
  `"#{set.actor || 'unknown'}: #{set.summary.presence || set.kind.humanize}"` from `HomeSnapshot#activity`
  (`app/services/home_snapshot.rb:66-68`, the latest change sets). A nil actor gives the hard-coded `'unknown'`
  (not a locale key, and `||` not `.presence`), and an MCP set has no summary, so `"graph.write".humanize` gives
  `Graph.write`: hence `unknown: Graph.write`. The meta line (`:16`) repeats the raw kind. System › Activity
  (`app/views/system/activity/index.html.haml:24-26`) has the same shape, with the locale fallback
  `system.activity.unknown_actor: "unknown"` (`config/locales/system.en.yml:93`). Same root cause.
- **Review credit side effect.** `ChangeRecording.resolver_for(actor)`
  (`app/services/compaction_review_service/change_recording.rb:21-27`) maps `operator:` → `operator`,
  `mcp:`/`api:` → `agent`, `policy:<name>` → itself, anything else (incl. nil) → `generator`. With a nil actor, a
  review row applied or dismissed through `apply_maintenance_review` / `dismiss_maintenance_review` is credited to
  `generator` instead of `agent` (`:68`).

## Design (Part B)

### Trust levels
1. **Channel and tool** (`mcp:graph_write`): a server fact. Goes in `actor`.
2. **`X-MCP-Client`**: client configuration. Any LAN client can set any value, but the model can't change it mid-task.
3. **`clientInfo` name/version**: self-reported by the client software.
4. **`source` prefix**: free text written by the model; content can steer it (prompt injection).
2-4 go in a new `actor_claim` column, shown as "claimed: …". Nothing reads `actor_claim` for authorization, review
credit, filtering defaults or policy decisions. `resolver_for` keeps reading `actor` only.

### Formats
- `actor` = `mcp:<tool_name>` (Decision 2), e.g. `mcp:graph_write`, `mcp:apply_maintenance_review`.
- Transport claim (per call) = parts joined by ` · `, each omitted when absent: `client=<X-MCP-Client>` (omitted when
  it is `GraphMemContext::DEFAULT_CLIENT_ID`, "default"), `<clientInfo.name>/<clientInfo.version>`. Example:
  `client=synth-client-a · claude-code/2.1.0`.
- Row claim (audit rows of records with a `source`) = transport claim + ` · ` + the `source` prefix when it parses.
  Example: `client=synth-client-a · claude-code/2.1.0 · claude-code/opus`.
- `source` parse: `\A(?<who>[A-Za-z0-9._-]+\/[A-Za-z0-9._:@-]+):\s+(?<why>\S.*)\z` on a single line. `project_scan:…`,
  `docs:…` or `operator` sources don't match (no slash before the colon), so they give no claim and no reason.
- Sanitize every part: strip control characters and newlines, squeeze spaces, truncate the whole value to 255.

### Reason fallback order (Decision 4)
For an audit row, the first present of:
1. delete: `Current.deletion_reason` (unchanged);
2. update whose `changed_fields` include `obsolescence_reason` (supersede, soft delete): its new value;
3. a record with `source` that parses: `why`;
4. nil (shown as "—").
Entities and relations have no `source`, so their create and update rows keep "—"; that is expected.

### Labels after the fix
- Audit log, Actor column: `mcp:graph_write`, with a second line `claimed: client=synth-client-a · claude-code/2.1.0 ·
  claude-code/opus` (Decision 3). Reason column: `fact supersede review` for a create whose source is
  `claude-code/opus: fact supersede review`.
- Home › Recent activity: `mcp:graph_write: Graph write` (Decision 7), with the claim in the row's `title` tooltip
  only (the widget is two short lines). Rows that really have no actor show the locale fallback, not a literal.
- System › Activity: actor cell `mcp:graph_write`, claim on a second line in `.system-hint`.

## Steps

### A1. Routes and controllers (Part A)
- Delete `config/routes.rb:124` (`/graph`), `:125-127` (`project_scans`, `project_scan_skills`), `:128-130`
  (`/maintenance`), `:149-151` (`data_exchange/compaction_review`), the whole UI-7 block `:224-260`, and the
  `import_upload`, `import_review`, `import_execute`, `import_report`, `import_cancel`, `export_async`,
  `download_export` lines in `:72-99`. Drop the "until §6.D-6" comments (`:108`, `:125`, `:128`, `:149`, `:224-229`).
- Delete `app/controllers/project_scans_controller.rb`, `app/controllers/project_scan_skills_controller.rb`, the seven
  `DataExchangeController` actions and anything only they use (check with `rg` before deleting a private method).
- `app/views/projects/index.html.haml:4-6`: drop the `legacy-anchor` controller and its values; delete
  `app/javascript/controllers/legacy_anchor_controller.js` (controllers are auto-registered; `rg legacy.anchor app` → nothing after).
- `app/services/import_flow.rb:5-7`: it is now used only by `Projects::ImportsController`.
- Delete `app/channels/export_progress_channel.rb` and the three broadcasts in `app/jobs/export_job.rb:122-134`
  (progress goes through `OperationProgress` / `OperationProgressChannel` since UI-6; confirm first that nothing in
  `app/javascript` subscribes to `ExportProgressChannel`, `rg -n ExportProgress app/javascript` → nothing).

### A2. Settings and session shims
- `System::SettingsController`: delete `LEGACY_TABS` (`:12-13`); `:48` becomes `SettingsSchema.group(tab) || …first`.
- `SettingsGroupUpdate#elsewhere_notice`: remove it and its call (`:32`) (Decision 3 default).
- Legacy session key: `session_authentication.rb:22` → `return "operator" if session[:role] == "operator"`;
  `api/v1/base_controller.rb:34` drop `&& !session[:operator_signed_in]`; `operator_session_constraint.rb:9` and
  `application_cable/connection.rb:22-23` read `role` only. Update the `:20` comment.

### A3. Specs for Part A
- Delete the shim-only spec files listed above and the listed examples.
- **Coverage guard:** `data_exchange_spec.rb:130-643` is the deepest import coverage in the suite. Before deleting a
  block, check that `spec/requests/projects/imports_spec.rb` (or `spec/services/import_flow_spec.rb` /
  the strategy specs) covers the same case; port the missing ones to `projects/imports_spec.rb` against the new
  routes, same synthetic files. List the ported cases in the PR. Same for `project_scans_spec.rb` /
  `project_scan_skills_spec.rb` vs `spec/requests/projects/scans_spec.rb`.
- New `spec/requests/removed_shims_spec.rb`: a table of every removed path and verb (GET `/graph`, `/maintenance`,
  `/data_exchange/compaction_review`, `/data_exchange/import_review`, `/data_exchange/import_report`, every UI-7 GET,
  POST `/project_scans`, POST/PATCH `/project_scan_skills…`, POST `/data_exchange/import_upload`, `import_execute`,
  `export_async`, DELETE `import_cancel`, GET `download_export`, and every old `/operator/*` write), signed in as
  operator, each answering **404**. Plus: `/operator/login`, `/system` and `/data_exchange/entity_search` still work.
- A session with only `operator_signed_in: true` is signed out: a request spec (redirect to login) and the cable
  connection spec (rejected) replace `connection_spec.rb:22-`.
- `spec/requests/role_matrix_spec.rb` walks the route table: re-run it, it must pass with no new exemptions.

**Checkpoint 1:** A1-A3 pushed, CI green, **open the PR as a draft**. `rg -n "D-6" app config lib spec` → nothing.
Stop for Steve's review of the removed list.

### B1. Set the actor for MCP calls
- `ApplicationTool#call_with_schema_validation!`: set `Current.actor = "mcp:#{tool_name}"` right before
  `raw_result = call(**normalized)` (`:75`). Delete the dead `def call(...)` override (`:101-104`). Keep the reset in
  `ensure` (`:98`), and reset the new `Current` attributes there too.
- `ChangeSet.record` already defaults `actor:` to `Current.actor` (`change_set.rb:57`), so MCP change sets get it with
  no change there.
- Replace `spec/tools/application_tool_spec.rb:319-327` with an example through `call_with_schema_validation!`.

### B2. The claim: migration, plumbing, model
- One migration: nullable `actor_claim varchar(255)` on **`audit_logs` and `change_sets`**, **no index**
  (Decision 6). `git diff db/structure.sql` shows only those two columns.
- `Current`: add `actor_claim` (the transport claim).
- `OfficialMcp::ToolWrapper`: in the generated `call`, read `server_context.client_info` when it responds to it
  (guard nil, and a Hash with `:name`/`"name"`), and pass it to `invoke` → `RequestContext::Context` gains
  `client_info` (or `invoke` takes it as a keyword). `ApplicationTool` builds the transport claim from
  `current_client_id` and it, and sets `Current.actor_claim` next to `Current.actor`. A small PORO
  `ActorClaim` (`app/models/actor_claim.rb` or `app/services/actor_claim.rb`): `.transport(client_id:, client_info:)`,
  `.source_parts(source) → [who, why] | nil`, `.join(*parts)` with the sanitizing rules.
- `ChangeSet.record` / `ChangeSet::Context`: take `actor_claim: Current.actor_claim` and persist it like `actor`.
- `Auditable#write_audit`: `actor_claim:` = transport claim + the row's `who` when the record responds to `source`.
- REST and web UI: leave `actor_claim` nil (their actor is already server-derived). Do not parse `source` for them.

### B3. The reason
- `Auditable#write_audit`: `reason:` follows the order in "Reason fallback order". For updates, read
  `obsolescence_reason` from the `changes` hash it already builds; for `source`, use the record's current value.
- Keep the delete path exactly as it is.

**Checkpoint 2:** B1-B3 pushed with their specs, CI green. A request spec over `POST /mcp` (`tools/call`
`graph_write`, `X-MCP-Client: synth-client-a`, an `initialize` with `clientInfo { name: "synth-agent", version:
"0.0.1" }`, an observation with `source: "synth-agent/model-x: synthetic task"`) shows the audit row with
`actor = "mcp:graph_write"`, `actor_claim = "client=synth-client-a · synth-agent/0.0.1 · synth-agent/model-x"`,
`reason = "synthetic task"`, and its change set with `actor = "mcp:graph_write"`. Stop for review.

### B4. Review credit
- No code change expected: with B1, `resolver_for` sees `mcp:apply_maintenance_review` and returns `agent`.
- Spec: apply and dismiss a synthetic review row through the MCP tool path (`call_with_schema_validation!` on the
  maintenance profile) and assert `resolved_by == "agent"`; the same through the operator UI stays `operator`.

### B5. UI
- Audit log (`index.html.haml:62`): under the actor, `claimed: <actor_claim>` in a `.system-hint` when present
  (Decision 3). New locale key `operator.audit_logs.claimed: "claimed: %{claim}"`. Keep the "—" fallbacks.
- System › Activity (`activity/index.html.haml:26`): same second line; `set.actor.presence || t(...)`.
- Home (`home/_activity.html.haml:11`): `set.actor.presence || t("home.activity.unknown_actor")` (new key, value
  "unknown"), the claim appended to the `title` only. Kind label (Decision 7): a `change_set_kind_label(kind)` helper
  (`app/helpers/change_sets_helper.rb`, like `ReviewHelper#review_kind_label`) with locale
  `change_sets.kinds.<kind>` and a default of `kind.tr("._", "  ").capitalize` (`graph.write` → "Graph write"); use
  it on Home (`:11`) and System › Activity (`:24`). The raw kind stays in the meta line and `.system-hint`.
- Audit log filter: the Actor filter stays an exact match on `actor` (`audit_log.rb:18`); `mcp:graph_write` works.
  Don't filter on `actor_claim`.

### B6. Backfill (manual rake task)
- `lib/tasks/audit.rake`, `rake audit:backfill_actors` (Decision 5): **dry run by default** (prints counts per table
  and per kind), `APPLY=1` writes. Idempotent: it only touches rows whose `actor IS NULL`, in batches of 500, one
  transaction per batch, and no callbacks (`update_columns` / `update_all`) so it writes no new audit rows.
- Change sets: `kind IN ('graph.write','graph.edit','graph.delete')` and `actor IS NULL` →
  `mcp:graph_write` / `mcp:graph_edit` / `mcp:graph_delete`. These kinds are opened only by the MCP tools at that
  level (Explore wraps its edits in `explore.*`, REST in `api.write`, and a nested `ChangeSet.record` joins the
  outer set), so the mapping is exact. Other nil-actor sets (`review.*` and the rest) are ambiguous between MCP and
  jobs: leave them.
- Audit rows: those whose `change_set_id` points at a set fixed above get the same `actor`. For
  `MemoryObservation` create/delete rows, parse `changed_fields["source"]`: `actor_claim` = `who` (prefixed
  `backfilled · `; `clientInfo` and `X-MCP-Client` can't be recovered) and, when `reason` is nil, `reason` = `why`.
  Update rows: only when `changed_fields` holds `obsolescence_reason` (its `to`) or `source` (its `to`); never infer
  from the observation's current row.
- Window: everything still present (audit rows are pruned after `AuditLog::MAX_AGE_DAYS` = 90; change sets by
  `ChangeSetPruneJob`). Expect hundreds of rows, not millions.
- Home and System › Activity read change sets, so after `APPLY=1` they show `mcp:graph_write` for old entries too.
- Review rows already credited `generator` are **not** rewritten (there is no reliable way to tell MCP from jobs);
  say so in the task's output.

### T. Specs (beyond the ones per step)
- `spec/models/concerns/auditable_spec.rb`: actor and claim from `Current`; claim with and without a parsable
  `source`; `project_scan:` source → no claim and no reason; the reason order (delete, `obsolescence_reason`, `why`,
  nil); control characters and a 300-char source are sanitized and truncated.
- `spec/models/actor_claim_spec.rb` (or services): the parse table, incl. `docs:README`, `operator`, empty, a
  multi-line value, a colon without a slash.
- `spec/lib/graph_mem/official_mcp/tool_wrapper_spec.rb` (or the existing official MCP spec): `client_info` nil
  (stdio), a Hash, a non-Hash.
- `spec/requests/mcp_official_spec.rb`: the Checkpoint 2 example; and the `Current` reset between two calls
  (the second call's actor is its own tool, never the first's).
- Recent activity: `spec/requests/pages_spec.rb` (the `home/:section` `activity` frame) and
  `spec/requests/system/activity_spec.rb`: an MCP-made set renders `mcp:graph_write: Graph write`, the claim in the
  `title` (Home) and on the second line (System › Activity); a set with a nil actor renders "unknown" from the
  locale.
- `spec/requests/system/audit_log_spec.rb`: Actor with the "claimed:" line; Reason from the source.
- `spec/tasks/audit_backfill_spec.rb`: dry run writes nothing; `APPLY=1` fills `graph.*` sets and their rows, parses
  `source` on create/delete, leaves `review.*` sets, `operator:` rows and non-nil actors untouched, writes no audit
  row, and a second run changes 0 rows.
- REST and web UI: an existing request spec each still shows `api:…` / `operator:…` and `actor_claim` nil.
- MCP surface: `mcp_tool_registry_spec.rb`, `mcp_official_spec.rb`, `mcp_structured_output_stdio_spec.rb` counts
  unchanged (22 / 12 / 9 / 22); `spec/mcp/tools_list_snapshot_spec.rb` green **without** re-recording; `git diff
  spec/fixtures/mcp/snapshots` empty.

### D. Docs
- `docs/guides/ui-guide.md:96`, `:126`, `:215`: drop the old-URL sentences (the old URLs are gone). Add a sentence
  to the Audit log section: Actor is what the server knows (`mcp:<tool>`, `operator:…`, `api:…`); "claimed" is what
  the client and agent say about themselves, not verified.
- `docs/app_settings_reference.md:119`: drop "(`/operator/jobs` redirects until §6.D-6)".
- `docs/architecture.md` "Change sets and undo": actor and `actor_claim`, the trust levels, the reason order.
- `docs/mcp_tools.md` (`graph_write` section): one line restating the `source` convention
  `"<client>/<model>: <task>"` and that the audit log reads its prefix as a claim and its suffix as the reason.
  Do **not** change any tool description or schema string (snapshots stay unchanged).
- `docs/plans/ui-dashboard-plan.md`: the D-6 row ✅ with the PR number; §6.D-6 marked done.
- Generic paths only (`<project root>`, `/path/to/…`), no host or user names.

### R. Release
- `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` (`graph-mem-version:`) → **1.65.0**.
- `CHANGELOG.md` `## [1.65.0] - <merge date>`, summary "Drop the transition shims; MCP writes record who made them":
  - **Removed:** the 301 redirects for `/graph`, `/maintenance`, `/data_exchange/compaction_review`,
    `/data_exchange/import_review`, `/data_exchange/import_report`, `/operator/settings` (all tabs),
    `/operator/settings/project_scans/check_path`, `/operator/embeddings`, `/operator/telemetry`,
    `/operator/audit_logs`, `/operator/jobs(/*rest)` and `/projects/jobs`; the old write endpoints under `/operator/*`,
    `/project_scans`, `/project_scan_skills` and `/data_exchange` (`import_upload`, `import_execute`, `import_cancel`,
    `export_async`, `download_export`); `ExportProgressChannel`; the legacy `operator_signed_in` session key
    (a session cookie from before the 1.53.0 login hardening must sign in again). Old URLs now answer 404.
  - **Added:** `actor_claim` on audit rows and change sets (migration), shown as "claimed: …"; `rake
    audit:backfill_actors` (dry run by default).
  - **Fixed:** MCP writes had no actor (audit log and Recent activity showed none / "unknown"), and reviews applied
    through MCP were credited to "generator"; create and update audit rows now take a reason from `source` or
    `obsolescence_reason`.
  - **Changed:** Recent activity labels change set kinds ("Graph write").
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** T, D, R pushed, CI green; mark the PR ready for review.

## Security checklist
- **Trust:** `actor_claim` is display-only. No code path authorizes, credits, filters by default or decides a policy
  from it. `resolver_for` reads `actor` only.
- **Injection:** the claim and the derived reason are model-controlled text: sanitized, truncated, HAML-escaped,
  never `html_safe`, never interpolated into SQL or a log format string.
- **Session:** removing the legacy key signs out only cookies older than the 1.53.0 login hardening (UI-0 / F3); no new way in.
- **Routes:** the removed endpoints were operator only; `role_matrix_spec.rb` must still pass, with no new exemption.
- **Backfill:** dry run by default, nil-only, batched, no callbacks, no deletes.

## Size and split
About **1,000-1,300 changed lines**, more than half deletions. Part A ~500-700 (mostly deleted code and specs, plus
the ported import cases and the 404 table), Part B ~450-600 (B1 ~40, B2 ~150 incl. migration, B3 ~40, B5 ~80, B6
~100, specs ~250), D ~40, R ~20. **If the diff passes ~1,500 lines, stop and ask Steve.** The natural split is
Part A and Part B as two PRs (Part A with no bump, Part B with 1.65.0).

## Decisions (open, with the recommended default)
1. **Version.** *Default:* **1.65.0**: a migration plus removed routes and a session format change. Alternative:
   1.64.1 if Steve treats it as a pure fix release.
2. **Actor format.** *Default:* `mcp:<tool>`: stable, filterable with the existing exact-match filter, matches
   `resolver_for` and the existing spec fixtures; the client id goes in the claim. Alternative: `mcp:<client_id>/<tool>`
   (the client in the column itself, but the Actor filter then needs a prefix match).
3. **Show the claim in the UI.** *Default:* yes, as a second "claimed: …" line on Audit log and System › Activity, and
   in the `title` on Home. Alternative: store it only (visible in the DB and Changes JSON).
4. **Reason fallback order.** *Default:* delete reason → changed `obsolescence_reason` → `source` suffix → nil.
   Alternative: `source` suffix before `obsolescence_reason` (the agent's task over the supersede reason).
5. **Backfill mechanism.** *Default:* a manual rake task, dry run by default, `APPLY=1` to write. Alternative: a data
   migration (runs on every deploy and in CI, harder to dry-run; not recommended).
6. **Index on `actor_claim`.** *Default:* no; it is display-only and never filtered on.
7. **Change set kind label** (optional). *Default:* yes, a small helper with locale overrides (`graph.write` →
   "Graph write") on Home and System › Activity. Alternative: keep `kind.humanize` ("Graph.write").
8. **Shim removal timing.** *Default:* remove now, as planned (1.64.0 is the release D-6 waited for). Alternative:
   keep one more release and log a deprecation line (`Rails.logger.warn "[D-6] legacy route …"`) on each hit.
9. **`elsewhere_notice`.** *Default:* remove with `LEGACY_TABS` (only a stale pre-UI-7 tab can post such a key).
   Alternative: keep it as a general guard for any misplaced key.

## Acceptance criteria
- Every removed path answers 404 for an operator; `/operator/login`, `/system`, `/data_exchange/entity_search` and
  the other live `data_exchange` actions still work. A session holding only `operator_signed_in` is not signed in.
- No import, scan or export case lost coverage (ported cases listed in the PR).
- A `graph_write` over `/mcp` writes audit rows and a change set with `actor = "mcp:graph_write"`, the claim and the
  reason from `source`; Home › Recent activity shows `mcp:graph_write: Graph write`; System › Audit log shows Actor,
  "claimed: …" and Reason.
- A review row applied through `apply_maintenance_review` is `resolved_by: "agent"`.
- Web UI and REST actors are unchanged and their `actor_claim` is nil.
- `rake audit:backfill_actors` is a no-op without `APPLY=1`, idempotent with it, and leaves ambiguous rows alone.
- MCP: 22 classes, default 12, readonly 9, maintenance 22; tool schemas and `spec/fixtures/mcp/snapshots/*.json`
  unchanged. `git diff db/structure.sql` shows only the two `actor_claim` columns.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) green; the test DB left with 0 rows;
  files under ~500 lines, methods under ~60. Synthetic data only.

## Stop and ask Steve if
- Anything would add an MCP tool, change a tool's arguments or description, or change an MCP snapshot.
- A quoted line no longer matches the code, or a "live" `data_exchange` action turns out to be called only by a shim.
- Deleting a shim spec would drop coverage that can't be ported to the new routes.
- The design needs a second migration, an index, a new gem or importmap pin, or a CSP change.
- `clientInfo` can't be read from the wrapper without patching or monkey-patching the `mcp` gem.
- The diff passes ~1,500 lines, or a file passes ~500 lines and can't be split cleanly.
