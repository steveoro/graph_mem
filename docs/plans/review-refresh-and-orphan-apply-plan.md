# Review refresh + orphan apply → graph_mem 1.86.2 (cards clear without F5, live policy numbers, orphan rows apply their top live suggestion)

**Status (2026-11-13): PLAN, approved, kickoff ready.** Second PR of the train Steve confirmed on 2026-11-13:
1.86.1 (`docs/plans/mcp-sdk-1.10.0-plan.md`, `mcp` 1.10.0) → **1.86.2 (this plan)** → MCP Apps 1.87.0–1.89.0
(`docs/plans/mcp-apps-plan.md`). Steve folded the orphan-parent fix into this release (2026-11-13), so there is
**no 1.86.3**.

**Written 2026-11-13 (Europe/Rome)** for Claude, from `main` at `c242eda` (graph_mem 1.86.0; the only commits after
`466bab8` are a Gemfile.lock refresh and the 1.86.1 plan, so no app code moved). Every file:line below was checked
against `c242eda`. **This PR lands after 1.86.1**: branch off `main` once the 1.86.1 PR (`claude/mcp-1.10.0`) has
merged, so `version.rb` reads `1.86.1` when you start. If 1.86.1 hasn't merged yet, stop and ask. If a line has moved,
find it by the quoted text. If the code no longer matches the description, **stop and ask Steve** instead of improvising.

## Brief

| | |
|---|---|
| **Status** | PLAN, approved (1.86.2, second in the train). |
| **Branch / PR** | **One PR**, `claude/review-refresh-1.86.2`, off `main` after 1.86.1 merged, title `Review refresh + orphan apply (1.86.2)`: steps R1, R2, O1, O2 + release RB. Steve merges and tags. Never merge, tag, push tags or run `rake release`. |
| **Commits** | **R1** row actions refresh the queue, **R2** live rail and policy runs, **O1** one orphan parent resolver (preview, apply, card), **O2** Dangling "parent gone", **RB** release. Review fixes go in new commits. No force-push after review starts. |
| **Scope** | Review & Fix UI (Turbo Streams, partials, one GET route), `ReviewPolicyJob.running?`, the orphan parent resolver, one Dangling reason. **No migration, no setting, no gem or npm package, no JS change** (`live_refresh_controller.js` is reused as is). |
| **MCP** | **One pre-approved behaviour change (Steve, 2026-11-13):** `apply_maintenance_review` (and its `dry_run`) on an `orphan_parent` row **without** `action_params.parent_id` uses the row's top live suggested parent instead of failing. Tool schema, description, params and output keys stay unchanged; `spec/fixtures/mcp/snapshots/` stays byte-identical (`/mcp` 12 tools, readonly 9, maintenance 22). **Any other MCP surface or behaviour change is a hard stop.** |
| **Data** | Synthetic fixtures only (`SynthClient`, `synth-*` names). Never real data, real credentials, a production dump or names from a live graph. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, this plan, `app/javascript/controllers/live_refresh_controller.js` (1.84.0) and its first user, `System::JobsController#cards` + `app/views/system/jobs/index.html.haml:12-14` + `_cards.html.haml:1-4`. |

## Part 1: the Review queue refreshes itself

### What the code does today (verified at `c242eda`)

- Row actions: `ReviewController#apply/#dismiss/#snooze/#restore` (`app/controllers/review_controller.rb:48-63`) call
  `respond_with_review(result, remove: row_ids)`; `row_ids` is `[ dom_id(@row) ]` (`:161`). `#update` (Save, `:43-46`)
  uses the same responder without `remove:`.
- `ReviewResponses#respond_with_review` (`app/controllers/concerns/review_responses.rb:25-42`): the Turbo Stream answer
  updates `toasts` and, on success, removes the given DOM ids (`:36-38`). Nothing else.
- What stays stale after a row action:
  - the detail pane, Turbo Frame `review-detail` (`index.html.haml:19`, `_detail.html.haml:3`, `_preview_card.html.haml:2`),
    still shows the row or confirm card just acted on;
  - the group card (`_group_card.html.haml:2-4`, id `review_group_dom_id(group.key)`, `app/helpers/review_helper.rb:50-52`,
    the same digest as `group_ids`, `review_controller.rb:162`) keeps its count and priority and is never removed when its
    last row goes. On "Needs attention" (the default view) the rows sit in a lazy frame (`"#{dom}-rows"`,
    `_group_card.html.haml:20,25`) that is often closed, so no `dom_id(row)` is on the page and nothing visibly changes;
  - the rail badges (`_rail.html.haml:4-12`, `%nav#review-rail`; counts from `rail_counts`, `review_controller.rb:149-156`,
    which needs `@digest`, set only in `#index`, `:18-19`).
- Group actions (`group_apply/group_dismiss/group_snooze`, `:72-85`) already remove the group card (`group_ids`), but leave
  the rail stale.
- "Run policies now": `run_policies` (`:87-91`, route `config/routes.rb:146`) enqueues `ReviewPolicyJob` and toasts
  `ui.review.policies_queued` ("…results show under Policies", `config/locales/ui.en.yml:32`). The rail and the Policies
  view (`_view_policies.html.haml:6-26`, data from `load_policies`, `review_controller.rb:134-138`) change only on reload.
- `ReviewPolicyJob` (`app/jobs/review_policy_job.rb:9,25-35`) holds the named lock `"#{LOCK_PREFIX}:#{current_database}"`
  (`GET_LOCK(…, 0)`) while it runs. Between enqueue and lock there is only a Solid Queue job; the not-finished-job query
  pattern is `EmbeddingsMaintenanceEnqueuer#pending?` (`app/services/embeddings_maintenance_enqueuer.rb:36-45`).
- `live_refresh_controller.js` (1.84.0) polls `urlValue` with `Accept: text/vnd.turbo-stream.html` and renders whatever
  streams come back (`:63-77`), every 3 s while its `state` target has `data-active="true"`, 30 s otherwise (`:19-23,96-98`);
  paused on hidden tabs, keeps open `<details>` open across morphs (`:92-94`), stops and revisits on a redirect.
- **Session:** a poll must not count as activity. That is **not** automatic: `System::JobsController` overrides
  `refresh_session!` for its `cards` action only (`app/controllers/system/jobs_controller.rb:81-89`), and
  `spec/requests/system/jobs_spec.rb:83-97` tests it. A new poll endpoint needs the same override. (A signed-out poll
  isn't stored as the way back already: `application_controller.rb:53` stores only `:html` GETs.)

### R1. Row actions refresh the queue (no F5)

Plain Turbo Streams on the existing responses; no view change to the Apply/Dismiss/Snooze forms (the confirm card's Apply
posts with `turbo_frame: "_top"`, `_preview_card.html.haml:10-12`, and Turbo still applies a stream answer).

- `ReviewResponses#respond_with_review(result, remove: [], refresh: nil)`: `refresh:` is the acted-on row (or `nil`). On
  success with a row, add to `streams`:
  1. `turbo_stream.update("review-detail", partial: "review/detail_done")`: a new `app/views/review/_detail_done.html.haml`
     with a short empty state (`t("ui.review.done")`, e.g. "Done. Pick the next suggestion.", `data-testid="review-detail-done"`).
     No auto-advance to the next row (keeps j/k in `review_keys_controller.js` the only navigation).
  2. The group card: key = `row.group_key || "#{row.kind}|row:#{row.row_uuid}"` (the same fallback as
     `ReviewDigest::GROUP_SQL`, `app/services/review_digest.rb:13`, and `MaintenanceReportRow.in_group`,
     `app/models/maintenance_report_row.rb:35-38`). Re-read it with a new `ReviewDigest#group(key)` (one `groups(...)` call
     on `@scope.in_group(key)` with `limit: 1`; returns a `Group` or `nil`). Then
     `turbo_stream.replace(review_group_dom_id(key), partial: "review/group_card", locals: { group: })` when it still has
     active rows, else `turbo_stream.remove(review_group_dom_id(key))`. A replace or remove whose target isn't on the page
     is a no-op in Turbo, so the other views (search, Resolved) need no special case.
  3. The rail counts (see "Rail counts" below).
- Pass `refresh: @row` from `apply`, `dismiss`, `snooze`, `restore` (`review_controller.rb:48-63`), keeping `remove: row_ids`.
  **Not** from `update` (Save keeps the detail pane on the edited row, as today).
- Group actions (`:72-85`) add only the rail counts.
- Failures (`result[:success]` false, 404/409/422/503) answer exactly as today.
- **Rail counts.** `turbo_stream.update("review-rail", …)` with the `_rail.html.haml` partial would nest a second
  `%nav#review-rail` and drop `aria-current` (the actions don't know the view). Instead, give each badge its own element:
  in `_rail.html.haml:11-12` always render the badge for the four counted views as
  `%span.ui-badge{ id: "review-rail-count-#{key}", hidden: !count&.positive? }= count` (a new 2-line partial
  `review/_rail_count.html.haml`, locals `key:, count:`), and stream one `turbo_stream.replace("review-rail-count-#{key}", partial: "review/rail_count", …)`
  per key of `rail_counts`. Move `rail_counts` (and `active_scope`, `:147`) into a small helper both the controller and the
  concern can call (e.g. a private `review_rail_counts` in `ReviewResponses` that builds its own `ReviewDigest.new`), so
  `#index` keeps `@rail = rail_counts` unchanged in output.

### R2. Live rail and policy runs ("Run policies now" numbers refresh by themselves)

- `ReviewPolicyJob.running?` (class method next to `LOCK_PREFIX`, `review_policy_job.rb:9`): true when
  `SELECT IS_USED_LOCK(<same quoted name>)` is not null, or a not-finished Solid Queue job of class `ReviewPolicyJob`
  exists (`SolidQueue::Job.where(class_name: "ReviewPolicyJob", finished_at: nil).exists?`, guarded with
  `defined?(SolidQueue::Job)` and `rescue StandardError → false`, as `embeddings_maintenance_enqueuer.rb:36-45`). Factor
  the lock name into one private class method used by `perform` and `running?`, so they can't drift.
- New route `get "live", action: :live, as: :live` inside the `scope "review"` block (`config/routes.rb:140-155`), next to
  `policies/run` (`:146`), so `review_live_path`.
- `ReviewController#live` (operator only, like every action here): answers `render turbo_stream:` with
  - the rail counts (the same per-badge replaces as R1);
  - `turbo_stream.replace("review-live-state", partial: "review/live_state", locals: { active: ReviewPolicyJob.running? })`:
    a hidden `%span#review-live-state{ hidden: true, data: { live_refresh_target: "state", active: active.to_s } }`;
  - when `params[:view] == "policies"`: `load_policies`, then
    `turbo_stream.update("review-policy-runs", method: :morph, partial: "review/policy_runs", locals: { reports: @reports, change_sets: @change_sets })`.
  - Add `refresh_session!` override for `action_name == "live"`, copied from `jobs_controller.rb:81-89` (same comment).
- Views:
  - `_rail.html.haml:4`: the nav gets `data: { controller: "live-refresh", live_refresh_url_value: review_live_path(view: view) }`
    and renders `review/live_state` (active `false` on a normal page load, or `local_assigns[:active]`) inside it. Keep the
    live element off the search form and the `review-detail` frame. The rail's "Import suggest-merges" `<details>` stays
    open across morphs (`live_refresh_controller.js:92-94`); the per-badge replaces don't touch it anyway.
  - `_view_policies.html.haml:6-26`: move the `@reports.each` loop (and the "No policy run yet." line) into
    `review/_policy_runs.html.haml` (locals `reports:, change_sets:`), wrapped in `#review-policy-runs`.
- `run_policies` (`:87-91`): after enqueuing, besides the toast, stream `review/live_state` with `active: true` so the
  rail starts polling every 3 s at once, and falls back to 30 s when a poll sees the run finished. Change the toast to
  "Review policies queued; the numbers update when the run finishes." (`ui.en.yml:32`).
- Not in scope: a progress bar, the Home digest badge, other pages.

### Part 1 specs

- `spec/requests/review_spec.rb` (synthetic rows via the file's `seed`/`proposal` helpers, `:11-19`):
  - apply of the last row of a group: the stream has `update` of `review-detail` with `review-detail-done`, `remove` of
    `review_group_dom_id(key)`, and `replace` of `review-rail-count-attention` (next to the existing check at `:48`);
  - dismiss of one of two rows in a group: `replace` of the group card with "1 suggestion";
  - Save (`update`) still doesn't touch `review-detail` or the group card; a failed action (404) streams only the toast;
  - group dismiss streams the rail counts;
  - `GET /review/live` (turbo Accept): streams the four rail counts and `review-live-state` with `data-active="false"`;
    `true` while `ReviewPolicyJob.running?` is stubbed true; `review-policy-runs` only with `view: "policies"`;
  - the poll never counts as activity and still expires an idle session (mirror `jobs_spec.rb:83-97`); signed out it
    redirects to sign-in without storing a return path (mirror `:99-104`);
  - `run_policies` (`:170-171`): still enqueues with `trigger: "manual"` and now streams `review-live-state` active.
- `spec/jobs/review_policy_job_spec.rb`: `running?` is false idle, true while another session holds the lock (reuse the
  `Mysql2::Client` holder pattern at `:14-25`), true with a not-finished `SolidQueue::Job` row if the test DB has the
  Solid Queue tables (else stub that half).
- `spec/services/review_digest_spec.rb`: `#group(key)` returns the group's count, and `nil` once its rows are resolved;
  works for a fallback `kind|row:uuid` key.
- `spec/system/review_spec.rb`: one case on "Needs attention" (threshold stubbed like `:28-29`): dismiss a row from the
  detail pane, and the group card disappears and the rail badge drops without a reload; the detail pane shows the done state.
  If a system case for "Run policies now" is cheap, run the job inline and see the Policies list grow without reload;
  otherwise the request specs cover it.

## Part 2: orphan rows apply their top live suggested parent

### What the code does today (verified at `c242eda`)

- **Producer:** `DreamStateCompactor#queue_orphan_review` (`app/strategies/dream_state_compactor.rb:171-193`) writes
  `entity_id`, `entity_name`, `entity_type` and `suggested_parents: [{ project_id:, project_name:, score:, matched_tokens: }]`
  (`:178-185`), **never `parent_id`**.
- **Preview** (detail pane, confirm card, MCP `dry_run`): `preview_orphan_parent` (`app/services/compaction_review_applier/preview.rb:63-65`)
  reads `pick(params, :parent_id, effective, [ :parent_id ])` only, so `move_preview` (`:153-156`) answers
  `ok: false, warnings: [ "Entity or parent not found" ]` for every unedited compactor row. The detail pane previews with
  no params (`review_controller.rb:34-36`), and so does the "Move under parent…" GET (`_detail.html.haml:19-20`,
  `review_controller.rb:38-41`); the confirm card offers Apply only when `preview[:ok]` (`_preview_card.html.haml:9-12`).
- **Apply:** `move_to_parent` (`app/services/compaction_review_applier.rb:134-141`) reads the same keys and fails with
  "Node and parent are required" (`:138`). `pick_id` (`:282-296`) has no "first suggested parent" fallback.
- **Card:** `_orphan_parent.html.haml:1-2,7-8` prefills the Parent select with `payload["parent_id"] || best["project_id"]`,
  so the right parent *looks* chosen, but that select is only sent by **Save** (PATCH `update` → `edited_payload.parent_id`,
  validated at `compaction_review_service.rb:363-364`). Rows saved once work; the rest fail ("some can, some can't").
- **MCP:** `apply_maintenance_review` (`app/tools/apply_maintenance_review_tool.rb:37-57`) passes `action_params || {}` to
  the same preview (`:53`) and apply (`:57`), so an orphan row without `action_params.parent_id` fails today. The
  `action_params` description (`:34`) already calls them "Optional overrides for merge/relation/orphan endpoints".
- Group, bulk and auto apply never touch `orphan_parent` (`SAFE_BULK_KINDS`, `app/services/review_row_classifier.rb:22`).
- **Gone parents:** merge and delete (`NodeOperationsStrategy#merge_into` `:98`, `#delete_node` `:202`) don't touch review
  rows. `ReviewPolicies::DanglingCheck#orphan_parent_reason` (`app/services/review_policies/dangling_check.rb:30-34`)
  checks only the orphan (gone, or already has a `part_of` parent), unlike `reparent_entity_reason` (`:36-41`).
  `StillQualifies#orphan_below_bar?` (`app/services/review_policies/still_qualifies.rb:74-81`) dismisses a row whose
  suggestions are all gone, but with the misleading "below the current evidence bar" reason, and only when that policy is
  on. Dangling runs before StillQualifies (`app/services/review_policy_runner.rb:13-14`), so a Dangling reason wins.
- **Specs miss it:** the orphan fixture in `spec/services/compaction_review_service_spec.rb:37-51` has `suggested_parents`
  only, and no spec previews or applies an orphan row without `parent_id`.

### O1. One parent resolver for preview, apply and the card (the pre-approved MCP behaviour change)

- New public class method `CompactionReviewApplier.orphan_parent_id(effective, action_params = {})` (in the `class << self`
  block, `compaction_review_applier.rb:6`):
  1. `pick_id(action_params, :parent_id, effective, [ :parent_id ])` when non-zero (an explicit `action_params.parent_id`,
     then the edited/top-level `parent_id`): returned as is, **even if that entity is gone** (preview then says
     "Entity or parent not found", and O2's Dangling reason retires the row);
  2. else the **first** `suggested_parents[].project_id` (in stored order, i.e. best score first) whose entity still exists
     (one `MemoryEntity.where(id: ids).pluck(:id)` query, keep the payload order);
  3. else `0`.
  Accept string or symbol keys (`effective` is `with_indifferent_access` in both callers; the view passes
  `row.effective_payload`, a string-keyed Hash).
- Use it in `move_to_parent` (`:134-141`, replacing the `parent_id` line `:136`) and in `preview_orphan_parent`
  (`preview.rb:63-65`, replacing the second `pick(...)`). `reparent_entity` and its preview stay as they are.
- `_orphan_parent.html.haml:1-2`: the prefill becomes `CompactionReviewApplier.orphan_parent_id(payload)` (nil when 0),
  so what the card shows is what Apply moves to; `current_name` (`:8`) reads that entity's name, falling back to the
  matching suggestion's `project_name`. Mark the suggestion that will be used in the list (`:5-6`), e.g. "(default)", and a
  gone one "(gone)", with one query.
- **MCP (pre-approved by Steve on 2026-11-13, and the only MCP change in this PR):** through the same two call sites,
  `apply_maintenance_review` and its `dry_run` on an orphan row with no `action_params.parent_id` now preview and apply the
  top live suggested parent. No change to `apply_maintenance_review_tool.rb` itself, its description, input schema or
  output keys; the snapshots stay byte-identical. If any of that would have to change, stop and ask.
- Not in this PR: making `queue_orphan_review` also write `parent_id`. It changes the stored payload that
  `list_maintenance_review` returns (an MCP output change that is not pre-approved), and O1 already covers new and old rows.

### O2. Dangling: "parent gone" for orphan rows

`DanglingCheck#orphan_parent_reason` (`dangling_check.rb:30-34`), after the two existing checks:
- `field.call("parent_id")` present and that entity is gone → `"parent ##{id} gone"` (the edited/explicit parent);
- no `parent_id`, and no `suggested_parents[].project_id` exists any more (all gone, or the list is empty) →
  `"no suggested parent left"`.
Reuse `gone_entity` (`:98-102`) where it fits. The Dangling policy then dismisses such rows as `policy.dangling` change sets
(undoable by run, restorable per row, no suppression), so a later compaction re-queues the orphan against the surviving
project. No data migration: once O1 lands, unedited rows apply with their top live suggestion. Re-pointing pending rows
inside merge is out of scope.

### Part 2 specs (synthetic: e.g. Project `synth-alpha-project`, Project `synth-beta-project`, Task `synth-orphan-task`)

- `spec/services/compaction_review_applier_preview_spec.rb` (next to `:44` and `:102`):
  - a suggestion-only orphan row previews `ok: true`, "Moves 'synth-orphan-task' … under 'synth-alpha-project'";
  - the first suggestion deleted → previews and applies under the second (`synth-beta-project`);
  - an explicit `action_params[:parent_id]` wins over the suggestions; an edited `parent_id` wins too;
  - all suggestions gone → `ok: false`, "Entity or parent not found" (unchanged message);
  - `ApplyMaintenanceReviewTool.new.call(item_id:, dry_run: true)` on a suggestion-only orphan row returns `ok: true`
    with no `action_params`, and writes nothing.
- `spec/services/compaction_review_service_spec.rb` (the fixture at `:37-51`, or a new synthetic one): `CompactionReviewService.apply`
  of a suggestion-only orphan row moves it (a `part_of` relation to the top suggestion exists, the row is approved,
  the change set is undoable).
- `spec/tools/apply_maintenance_review_tool_spec.rb` (in `#call`, `:37`): applying a suggestion-only orphan row without
  `action_params` succeeds; the result keys are the same as for the merge case at `:38`.
- `spec/services/review_policy_runner_spec.rb` ("dangling", `:41`): an orphan row whose edited `parent_id` is gone →
  `"dangling: parent #N gone"`; one whose suggestions are all gone → `"dangling: no suggested parent left"`; one with a
  live second suggestion stays active.
- `spec/requests/review_spec.rb`: the detail pane of a suggestion-only orphan row shows the move effect and the
  "Move under parent…" confirm card has the Apply button (`preview-confirm`); the card prefill names the top live suggestion.
- `spec/services/review_policies/still_qualifies_spec.rb` stays green unchanged (Dangling now takes the all-gone rows first
  in a full run; StillQualifies on its own still behaves as before).

## RB. Release 1.86.2

- `lib/graph_mem/version.rb` `1.86.1` → `1.86.2`, then `bin/rails graph_mem:sync_skill_version` (sets
  `skills/graph-mem-mcp-toolset/SKILL.md:18` and the `README.md:7` badge; `spec/docs/agent_text_sync_spec.rb` compares
  them). Don't edit `version.rb` or SKILL.md while the full suite is running.
- CHANGELOG `## [1.86.2] - <date>` at the top, above 1.86.1:
  - Fixed: "Review & Fix: after Apply, Dismiss, Snooze or Restore the detail pane clears, the group card updates its count
    (or goes when it's empty) and the rail counts update, without a reload."
  - Fixed: "'Run policies now': the rail counts and the Policies list update by themselves when the run finishes."
  - Fixed: "Orphan suggestions queued by compaction can be applied again: the detail pane, the confirm card and Apply use
    the top suggested parent that still exists (it showed 'Entity or parent not found' unless the suggestion had been saved once)."
  - Changed: "`apply_maintenance_review` (and its `dry_run`) on an orphan suggestion without `action_params.parent_id`
    moves the entity under the top suggested parent that still exists, instead of failing. Params and output are unchanged."
  - Changed: "The `dangling` review policy dismisses orphan suggestions whose chosen parent is gone (`parent #N gone`) or
    whose suggested parents are all gone (`no suggested parent left`)."

## Version and train

- **1.86.2, a patch release**: UI refresh fixes and a data-path fix, no migration, one pre-approved MCP behaviour change,
  no surface change.
- **Train (Steve, 2026-11-13):** 1.86.1 (`mcp` 1.10.0) → **1.86.2 this plan** (the refresh fixes and the orphan fix
  together; no 1.86.3) → MCP Apps 1.87.0 / 1.88.0 / 1.89.0. If another PR lands on `main` first, take the next free patch
  number and renumber the CHANGELOG heading and `version.rb`.

## Size

About 3–4 hours. Code ~130–170 lines (R1 ~50, R2 ~60, O1 ~25, O2 ~10, partials and locale), specs ~170–200 lines.
Expected diff: about 400 lines.

## Decisions (defaults; Steve may change any)

1. After a row action the detail pane shows a "Done" empty state; no auto-advance to the next row.
2. Rail counts update per badge (one `replace` per count), so the nav, its `aria-current` and the open `<details>` stay put.
3. `ReviewPolicyJob.running?` = lock in use **or** a not-finished Solid Queue job, so polling goes fast between enqueue and lock.
4. The resolver keeps an explicit or edited `parent_id` even when it's gone (no silent fallback past an operator's choice);
   Dangling retires that row instead.
5. No producer change (`queue_orphan_review` keeps its payload).

## Acceptance criteria

- The full suite is green on CI (CircleCI rspec, rubocop, brakeman; Actions lint, scan_ruby, scan_js).
- After Apply/Dismiss/Snooze/Restore from the detail pane, on "Needs attention" and on a grouped view: the detail pane
  shows the done state, the group card shows the new count or is gone, the rail badges show the new counts, no reload.
  Save and failed actions behave as before.
- After "Run policies now" the rail polls every 3 s until the run ends, then every 30 s; on the Policies view the new run
  appears without reload. `GET /review/live` never extends the session and redirects a signed-out poll to sign-in.
- A compactor-queued orphan row that was never saved previews `ok: true` and applies under its top live suggested parent,
  from the UI and from `apply_maintenance_review` (also `dry_run`) without `action_params`; the card prefill matches.
- Dangling dismisses orphan rows with a gone edited parent or no live suggestion, with the new reasons; they're undoable.
- `spec/fixtures/mcp/snapshots/` byte-identical; tool counts unchanged (12 / 9 / 22); `apply_maintenance_review_tool.rb`
  unchanged.
- No migration, no new gem or npm package, no JS file changed, no new setting.
- CHANGELOG 1.86.2 at the top with the orphan MCP behaviour under Changed; `version.rb`, SKILL.md and the README badge read 1.86.2.
- No real hostnames, IPs, usernames, machine names or home paths in docs, specs or the PR body. Synthetic data only.

## Stop and ask Steve if

- 1.86.1 hasn't merged when you start, or another PR has merged first (renumber);
- **any MCP surface or behaviour change other than the pre-approved orphan default parent**: a tool, prompt or resource
  param or output (input or output schema, `structuredContent` keys, result text, description), a new tool, capability or
  `x-mcp-header`, or a change to what `list_maintenance_review` returns;
- **any profile's tool count changes** (default `/mcp` is 12; Steve's budget is about 20 hard, under 15 preferred, and this PR adds none);
- a new migration, gem or non-stdlib package is needed, or a JS change turns out to be required;
- the diff goes past ~3,000 lines;
- anything would weaken the `/mcp` `AccessGate`, the lockdown, or the anonymizer/cloud gate, or the operator-only access of `/review`;
- an existing spec or snapshot has to change other than the `run_policies` toast text and the request-spec stream checks this plan lists.
