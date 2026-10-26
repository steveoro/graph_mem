# Chores D-1, D-2, D-3 → graph_mem 1.55.3 (one PR)

**Written 2026-10-26 (Europe/Rome)** for Claude, from `main` @ `caa523c` (1.55.2 plus the plan updates).
Every file:line below was checked against that commit. If a line has moved, find the code by the quoted
text; if the code no longer matches the description, stop and ask Steve instead of improvising.

Context: `ui-dashboard-plan.md` §0.3 (row C) and §6.D. These three small fixes ship together, before
UI-1 (1.56.0). Findings F5, F6 and F8 in `ui-dashboard-plan.md` §0 explain why each one matters.

## Brief

| | |
|---|---|
| **Branch** | `claude/chores-d1-d3-1.55.3`, off current `main`. |
| **PR** | Open **one PR against `main`**. Title: `Chores D-1–D-3: review button labels, row cleanup schedule, no re-embed in merge (1.55.3)`. Steve merges and tags; never merge, tag or run `rake release`. |
| **Commits** | One commit per chore (D-1, D-2, D-3), then a release commit (version + CHANGELOG). |
| **Data** | Synthetic fixtures only. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`. |

## D-1. Review buttons show their labels (F5)

**Problem.** `app/views/data_exchange/_compaction_review_item.html.haml:196-202` renders the review actions
with `submit_tag "<Label>", name: "review_action", value: "<value>", …`. For `submit_tag`, `value:`
*is* the button text, so it overrides the label: the buttons read `edit`, `apply`, `dismiss`,
`restore`, `ignore` instead of Save, Apply, Dismiss, Restore, Ignore.

Current code (inside `.md:col-span-3.flex.flex-wrap.items-start.gap-2`, line 194):

| Line | Condition (line) | Label → value |
|---|---|---|
| 196 | `- if row.active? \|\| row.ignored?` (195) | `"Save"` → `edit` |
| 197 | same | `"Apply"` → `apply`, with `data: { turbo_confirm: "Apply this suggestion?" }` |
| 198 | same | `"Dismiss"` → `dismiss` |
| 200 | `- if row.dismissed? \|\| row.approved?` (199) | `"Restore"` → `restore` |
| 202 | `- if row.active?` (201) | `"Ignore"` → `ignore` |

**Change.** On each of the five lines, replace `submit_tag "<Label>",` with
`button_tag "<Label>", type: "submit",` and keep every other option exactly as it is (`name:`, `value:`,
`class:`, `form: form_id`, and `data:` on Apply). The buttons sit outside the form and point at it with
`form: form_id`; `button_tag` passes `form` through as the same HTML attribute. Leave the conditions
(195, 199, 201) and the rest of the partial alone.

**Expected behaviour.** Each button shows its label; the request still posts `review_action=<value>`, so
`DataExchangeController#compaction_review_action` needs no change. The Apply confirmation still shows.
The same partial renders the compaction review and the scan review lists (through
`_compaction_review_item_frame.html.haml` and the Turbo Stream replace in `data_exchange_controller.rb:360`),
so both get the fix.

**Spec** (`spec/requests/data_exchange_spec.rb`, in `describe 'GET /data_exchange/compaction_review'`,
line 1141, which already creates an active `merge_row`):
- the page renders `<button` elements with the visible text Save, Apply, Dismiss and Ignore for the
  active row, each with `name="review_action"` and its value (`edit`, `apply`, `dismiss`, `ignore`);
  parse the body (`Nokogiri::HTML`) rather than matching raw strings;
- no `input[type=submit][name=review_action]` is left;
- a dismissed row shows a Restore button with `value="restore"`.
The existing POST specs (line 1262 onwards) post `review_action` directly and must stay green unchanged.

## D-2. Schedule `MaintenanceReportRowCleanupJob` (F6)

**Problem.** `app/jobs/maintenance_report_row_cleanup_job.rb` prunes approved, dismissed and ignored review
rows older than `AppSettings.compaction_review_row_retention_days` (lines 10-20; a value ≤ 0 falls back
to 30). Nothing ever runs it: `config/recurring.yml` has no entry and nothing enqueues it. The setting
(`app/models/app_settings.rb:51`, default 30, validated 0..365) isn't in the Settings UI either. Resolved
rows pile up forever.

**Change.**
1. `config/recurring.yml`: add the same entry under both `development:` (after `embedding_backfill`,
   line 10-13) and `production:` (after `embedding_backfill`, line 37-40):
   ```yaml
     maintenance_report_row_cleanup:
       class: MaintenanceReportRowCleanupJob
       queue: low_priority
       schedule: at 5:15am every day
   ```
   `low_priority` is already used by `stale_memory_scan` and `embedding_backfill`, and the phrase follows
   the existing `at 4:30am every day` style. Production times are GMT (comment at line 28). 5:15 runs after
   compaction (3:00), the embedding backfill (4:00) and the stale scan (4:30). Leave the job's own
   `queue_as :default` (line 7) alone; the recurring entry sets the queue.
2. `app/controllers/operator/settings_controller.rb:160-163`, the `telemetry:` group: change
   `settings: %w[tool_invocation_retention_days]` (line 162) to
   `settings: %w[tool_invocation_retention_days compaction_review_row_retention_days]`.
   The settings page renders and saves integer fields generically
   (`app/views/operator/settings/index.html.haml:53-59`, `bulk_update` lines 52-65), so no view or
   controller logic changes.
3. `config/locales/operator_settings.en.yml`: after `tool_invocation_retention_days:` (lines 108-110), add
   ```yaml
           compaction_review_row_retention_days:
             label: "Review rows retention (days)"
             description: "Approved, dismissed and ignored review rows older than this are pruned daily. Dismissed suggestions stay suppressed. 0 uses the default (30)."
   ```
   Match the indentation of the neighbouring keys.
4. Docs: in `docs/dream_state.md`, after the "Recurring schedule" table (around line 199-208), add a short
   paragraph: the daily review-row cleanup (5:15 AM GMT in production), the setting and where it lives
   (Settings › Telemetry). In `docs/app_settings_reference.md`, add a short `## Retention` section with a
   row for `compaction_review_row_retention_days` (default `30`, range 0-365, 0 = default) and a pointer to
   `docs/operator/telemetry.md` for `tool_invocation_retention_days`.

**Expected behaviour.** Solid Queue runs the cleanup once a day; Settings › Telemetry shows and saves the
retention. Rows stay suppressed after pruning only if they were dismissed (`MaintenanceReportSuppression`);
`ignored` rows pruned after the window can be proposed again, because ignoring never writes a suppression.
That is today's intended "snooze" behaviour (UI-5 makes it explicit). Say so in the PR description.

**Specs.**
- `spec/jobs/maintenance_report_row_cleanup_job_spec.rb`: add "is scheduled daily in development and
  production": `YAML.load_file(Rails.root.join("config/recurring.yml"))`, and for both environments assert
  `dig(env, "maintenance_report_row_cleanup", "class") == "MaintenanceReportRowCleanupJob"` and the queue
  is `low_priority`. Also assert an old `ignored` row is pruned (the existing example covers active,
  approved and dismissed).
- `spec/requests/operator/settings_spec.rb`: next to "renders the telemetry retention settings tab"
  (line 43) assert `data-testid="setting-compaction_review_row_retention_days"` renders; next to
  "updates telemetry retention" (line 56) add a PATCH that sets it to `45` and restores `30` in `ensure`.

## D-3. No re-embedding during a merge (F8)

**Problem.** `app/strategies/node_operations_strategy.rb:289-296`:
```ruby
def transfer_observations!(source, target)
  source.memory_observations.find_each do |observation|
    observation.assign_attributes(memory_entity_id: target.id)
    observation.trust_score = ObservationTrustRanker.rank(observation)
    observation.save!
    EmbeddingService.embed_observation(observation) if EmbeddingService.vector_enabled?   # line 294
  end
end
```
It is called from `merge_into_once` (line 113), inside `ProjectMembership.with_membership_lock`
(line 124, the global `GET_LOCK` in `app/services/project_membership.rb:51`) and the row-locking
transaction (line 125). Each call is an HTTP request to the embedding provider (`embedding_service.rb:308-309`:
open timeout 10 s, read timeout 30 s; `MAX_RETRIES = 3` with 0.5/1/2 s backoff, line 10-11). With the
provider slow or down, a merge holds the lock for up to about two minutes **per moved observation**, and
every other writer waits. The call buys nothing: an observation's vector comes from
`compose_observation_text` (`embedding_service.rb:258-263`), which uses only `content`, `source` and
`tags`, none of which the merge changes. Moving the row keeps its stored `embedding`.

**Change.** Delete line 294 and put this comment in its place:
```ruby
    # No re-embedding: an observation's vector depends only on its content, source and tags
    # (EmbeddingService#compose_observation_text), not on the owning entity. Calling the
    # embedding service here would hold the membership lock and the row locks across HTTP calls.
```
Nothing else in `transfer_observations!` changes.

**Out of scope (note it in the PR description, don't change it).** `merge_aliases` updates the target's
`aliases`, so `MemoryEntity`'s `after_commit :refresh_embedding` (`app/models/memory_entity.rb:33`, method at
line 90) re-embeds the **target entity** once per merge. That callback fires when the transaction commits,
which is still inside the `with_membership_lock` block. It is one call per merge, not one per observation,
and UI-4a reworks the merge path, so it stays as it is here.

**Spec** (`spec/strategies/node_operations_strategy_spec.rb`, `describe "#merge_into"`, line 154, which
already builds `source_with_data` with two observations and `target_node`):
- stub `allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)` and
  `allow(EmbeddingService).to receive(:embed_entity)` (the target's alias change, above), then
  `expect(EmbeddingService).not_to receive(:embed_observation)`; run `merge_into`; assert success and that
  both observations now belong to the target;
- with `vector_enabled?` false, the merge still succeeds (no regression).
Use `allow`/`expect` on the class methods: `EmbeddingService` delegates `embed_observation` to its instance
(`embedding_service.rb:21-23`), and `spec/support/embedding_helper.rb` shows the existing stubbing style.

## Release: 1.55.3

- `lib/graph_mem/version.rb`: `VERSION = "1.55.2"` → `"1.55.3"`.
- `skills/graph-mem-mcp-toolset/SKILL.md:18`: `graph-mem-version: "1.55.2"` → `"1.55.3"`
  (`spec/docs/agent_text_sync_spec.rb:193` checks they match).
- `CHANGELOG.md`: under the empty `## [Unreleased]` (line 8) add `## [1.55.3] - <merge date>` with:
  ```markdown
  ### Fixed
  - The compaction and scan review buttons show their labels (Save, Apply, Dismiss, Restore, Ignore) instead of the raw action values.
  - `MaintenanceReportRowCleanupJob` runs daily (5:15 AM GMT in production): approved, dismissed and ignored review rows older than the retention window are pruned. The retention (`compaction_review_row_retention_days`, default 30 days) is now in Settings › Telemetry.
  - Merging two entities no longer calls the embedding service for each moved observation inside the merge lock; observation vectors don't depend on the owning entity.
  ```

## Acceptance criteria

- The three changes above, and nothing else (no refactors, no other files beyond those listed).
- New and changed specs pass; the **full suite run alone** is green; `bin/rubocop` and `bin/brakeman` are
  clean; the test database has 0 rows in every table before and after the run.
- Manual check on synthetic data: the review page shows the five labels where they apply, Apply still asks
  for confirmation, and Settings › Telemetry saves the new field.
- `rg -n "submit_tag" app/views/data_exchange/_compaction_review_item.html.haml` finds nothing;
  `rg -n "embed_observation" app/strategies` finds nothing.
- Version 1.55.3 in both places and the CHANGELOG entry above.
- **One PR against `main`**, CI green. The PR body lists each chore with its specs and results, the
  "ignored rows can come back" note (D-2) and the target-entity re-embed note (D-3). Fix the review
  bot's should-fix findings with new commits on the same branch; no force-push after review starts.

## Stop and ask Steve if

- any quoted line no longer matches the code;
- `button_tag` changes the posted params or breaks the Turbo confirmation;
- Solid Queue rejects the new recurring entry at boot.
