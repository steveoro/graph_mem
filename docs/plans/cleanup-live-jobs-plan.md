# Clean-up PR (1.84.0): a live Background jobs page, a step progress bar, and F2c's deferred minors

## Context

1.83.0 is deployed; Steve started "Run all scheduled jobs now" with 3533 facts pending LLM words. Two problems:
- **The page doesn't update by itself.** Only F5 or the Dream State card's "Refresh" link (a full page visit) shows
  new state. The existing ActionCable path (`operation_progress_controller.js` + `OperationProgressChannel`, Solid
  Cable in production) only patches a few `data-progress-*` nodes, and a long inline step (FactKeywordsJob run via
  `perform_now` inside `ScheduledRunJob`) reports nothing until it ends.
- **No sense of how far the current step is.** Steve wants ONE progress bar in the "Scheduled jobs" card, under
  the running step's label (no new card per job).
- **The LLM-word backlog drains slowly:** a run stamps at most 25 batches × 20 = 500 facts (`FactKeywordsJob::LLM_BATCHES_PER_RUN`), so 3533 need ~8 presses.

Design from Fable (advisor), checked against the code. Steve's decisions (2026-11-12):
1. Live updates, any modern Rails 8.1 approach (→ Turbo frame polling with morph, cable kept as an accelerator).
2. No 25-batch cap on LLM words inside a scheduled run (Stop works between batches); the cap stays for the job's
   own runs (after-write requests, nightly).
3. Polls don't count as session activity, provided switching tabs back resumes polling (it does:
   `visibilitychange`). The operator idle timeout is 24 h (`SessionAuthentication::OPERATOR_IDLE_TIMEOUT`).
4. Fold in F2c's deferred minors (listed in #169).

## Part A: live page (polling a morphing Turbo frame)

- **Route + action:** `GET /system/jobs/cards` → `System::JobsController#cards`, renders a new partial
  `system/jobs/_cards` (the three cards, extracted from `app/views/system/jobs/index.html.haml`). The action skips
  the session activity stamp (`refresh_session!`), so polls never extend the session (decision 3).
- **`MaintenanceDashboardSnapshot.cards`:** everything the cards need except `graph_stats` (the orphan anti-join and
  counts), so a poll stays cheap. `index` keeps the full snapshot.
- **`index.html.haml`:** the cards inside
  `turbo_frame_tag "jobs-cards", src: system_jobs_cards_path, refresh: "morph", target: "_top", data: { controller: "live-refresh", live_refresh_active_value: … }`,
  rendered inline (no extra request on first paint). `target: "_top"` keeps every `button_to` and link a full visit
  (flashes kept).
- **New `app/javascript/controllers/live_refresh_controller.js`:**
  - `frame.reload()` every 3 s while something is active (scheduled run running or stopping, compaction running,
    GC running), every 30 s otherwise;
  - paused while `document.hidden`; on becoming visible, one immediate reload and the timer resumes;
  - skips a tick while the frame is `busy`;
  - keeps open `<details>` open across morphs (`turbo:before-morph-attribute` for `open`);
  - on `turbo:frame-missing` (an expired session returns the login page) prevents the default and stops.
  - The "active" flag comes from a `data-live-refresh-target="state"` node in `_cards` (`data-active`).
- **`operation_progress_controller.js`:** `operationIdValueChanged()` resubscribes (a morph can swap the run id),
  and `render` leaves `progress` elements marked `data-progress-step` alone (today it sets every `progress` in the
  card to the run's percentage).
- **Dream State card:** drop the "Refresh" link (the page refreshes itself).

## Part B: the current step's progress bar

- **New `app/services/step_progress.rb`**, a thread-scoped sibling of `CooperativeStop`:
  `StepProgress.with(sink) { … }`, `StepProgress.report(done:, total:, label: nil)` (a no-op outside `with`; a
  failing sink is logged and swallowed, so progress never fails a step).
- **`ScheduledRunJob#run_step`:** wraps the step in `StepProgress.with(method(:record_progress))` inside
  `CooperativeStop.with`. `record_progress` writes `details["steps"][i]["progress"] = { "done", "total", "label" }`
  under the row lock, at most every 2 s (the first report and label changes always written), touches the row (so
  "Last progress" moves) and broadcasts; returns silently when `current_job?` is false (never raises `Superseded`
  into the step's rescue). `finish` drops `"progress"`.
- **Reporters** (one `StepProgress.report` next to each existing `CooperativeStop.requested?` check):
  - `FactKeywordsJob` paths: done = computed, total = `keywords_pending` count at start (read `uncached`);
  - `FactKeywordsJob` LLM words: done = facts stamped, total = pending at start; label "LLM words: N of M";
  - `EmbeddingService#backfill_all`: done = rows visited (failures included), total = missing entities +
    observations at start.
- **Read-time probes** for steps with their own progress row: compaction from `CompactionRun#operation_progress`
  (the step's `compaction_run_id`), garbage collection from `GarbageCollectionRunner`'s `OperationProgress`
  (`garbage_collection`, created after the step's `started_at`).
- **`MaintenanceDashboardSnapshot#scheduled_run_snapshot`** adds `step_progress: { percent:, label: } | nil`
  (nil = indeterminate: backup, stale scan, review policies, clean-ups).
- **`_scheduled_run_card.html.haml`:** under the step label, one `%progress{ data: { testid: "scheduled-run-step-progress", progress_step: true } }`
  (no `value` → the browser's indeterminate bar) plus a hint line with the label.

## Part C: no LLM-word cap inside a scheduled run (decision 2)

`FactKeywordsJob#compute_llm_words`: inside a scheduled run (`CooperativeStop.active?`, a new reader on the module)
there is no `LLM_BATCHES_PER_RUN` cap; the walk ends on an empty batch, `LLM_EMPTY_BATCHES` failures in a row, or
Stop. Outside one, the cap stays.

## Part D: F2c's deferred minors

- `LlmWords::GENERIC` compared by key too (`"data"` → `"datum"`).
- Duplicate ids: parse with `JSON.parse(text, allow_duplicate_key: true)` and keep the first occurrence explicitly;
  spec it.
- Undo: add `keywords_at` and `llm_keywords_at` to the change-set undo's ignored columns
  (`app/services/change_set_undo/audit_inverse.rb`).
- `:summary` reuse: fix the `REQUEST_TASKS` comment (`app/services/llm/chain_run.rb`), add the call site's G-entry to
  `spec/services/llm/call_sites_spec.rb` and a golden for the words prompt in `characterization_spec.rb`.
- `Relatedness.compare` passes "same own entity" by id (`memory_entity_id`), not by name.
- Re-pend `llm_keywords_at` when a path recompute turns a fact's mentions from some to none (`FactKeywords.compute!`).
- `llm_refresh` aborts with a message when `Llm::Router.usable?(:summary)` is false.
- "LLM:" through i18n in `review/kinds/_keyword_path.html.haml`.
- `normalize` keeps words like `2fa`/`3d` (a token that starts with digits but is mostly letters isn't a detail).
- Words through `RailsCodeMap.lookup_key`-style separator folding (as the design said), keeping the stored form.

## Critical files

`app/controllers/system/jobs_controller.rb`, `config/routes.rb`, `app/services/maintenance_dashboard_snapshot.rb`,
`app/views/system/jobs/{index,_cards,_scheduled_run_card,_dream_state_compactor_card}.html.haml`,
`app/javascript/controllers/{live_refresh,operation_progress}_controller.js`, `app/services/step_progress.rb`,
`app/jobs/{scheduled_run_job,fact_keywords_job}.rb`, `app/services/embedding_service.rb`,
`app/services/cooperative_stop.rb`, `app/services/fact_keywords/{llm_words,relatedness}.rb`,
`app/services/fact_keywords.rb`, `lib/tasks/fact_keywords.rake`, `app/services/change_set_undo/audit_inverse.rb`,
`config/locales/system.en.yml`, docs (`docs/architecture.md`), CHANGELOG, version 1.84.0.

## Verification

- **Specs (synthetic, real instances; the LLM faked at the provider boundary):** `step_progress_spec` (no-op outside
  `with`, sink errors swallowed); `scheduled_run_job_spec` (progress written by a real FactKeywordsJob, throttled
  with `travel_to`, cleared on finish, skipped for a superseded token); snapshot `step_progress` per source
  (reporter, compaction row, GC row, nil); `fact_keywords_job_spec` (no cap inside a scheduled run, the cap outside);
  request spec for `/system/jobs/cards` (frame, bar, active flag, operator only, no session stamp); system spec with
  a ~200 ms interval: change the row in the test, the bar moves without a visit, an open `<details>` stays open;
  one spec per Part D item, each seen failing first.
- Full suite with the test DB truncated before and after; rubocop.
- **By hand on the dev stack** (`bin/dev` with `bin/jobs`): start a run, watch the bar and the cards update on their
  own, switch tabs and back (immediate refresh), press Stop.
- Process as before: native execution, a fresh final reviewer, PR ready, Graphy rounds.
