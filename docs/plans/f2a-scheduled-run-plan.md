# F2a (run every scheduled job now) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One start/stop switch on System › Background jobs runs every job of `config/recurring.yml` once, in a safe order. It can be stopped (inside batch jobs too) and resumed, and it shows a live status line. Also in scope: the README badge sync and removing the PWA template. Release 1.81.0.

**Architecture:**
- `ScheduledRun` turns the environment's `recurring.yml` section into an ordered, de-duplicated step list.
- `ScheduledRunJob` is a step machine whose state lives in an `OperationProgress` row (`operation_type: "scheduled_run"`). It runs each step inline, isolates failures, waits on compaction by re-enqueuing itself, and honours stop and resume.
- `CooperativeStop` is a thread-scoped flag that the batch jobs check.
- The card renders from the row and updates live through the existing `operation-progress` Stimulus controller and `OperationProgressBroadcaster`.

**Tech Stack:** Rails 8.1, Solid Queue, ActionCable, HAML, Stimulus, RSpec with a real MariaDB.

**Spec:** `docs/plans/f2a-scheduled-run-design.md` (approved 2026-11-11, with decisions 5–7 added the same day).

## Global Constraints

- Every Ruby command: `source /usr/share/rvm/scripts/rvm && rvm use ruby-3.4.12@graph_mem && bundle exec …`; specs with `OLLAMA_URL=http://127.0.0.1:9`.
- Synthetic data only in specs; real instances over doubles. The only stub allowed is at an outside-world boundary (`db:dump`).
- Order constant, verbatim: `DatabaseBackupJob, GarbageCollectionJob, DreamStateCompactionJob, EmbeddingScheduledBackfillJob, FactKeywordsJob, StaleMemoryScanJob, ReviewPolicyJob, MaintenanceReportRowCleanupJob, ChangeSetPruneJob, ExportJob.cleanup_old_exports`.
- Stoppable inside: `DreamStateCompactionJob` (its own pause), `FactKeywordsJob`, `EmbeddingScheduledBackfillJob`.
- Compaction poll: `1.minute`. There is **no** stale timer.
- Route `POST /system/jobs/scheduled_run` (param `expected` in `start stop resume start_over`), operator only. Button labels:
  - **Run all scheduled jobs now** (with `data-turbo-confirm`);
  - **Stop**;
  - **Stopping…** (disabled);
  - **Resume**, plus **Start over**.
- Texts live in `config/locales/system.en.yml` under `system.jobs.scheduled_run`.
- Public methods get YARD-style comments (AGENTS.md).
- Version **1.81.0**: `lib/graph_mem/version.rb`, then `bin/rails graph_mem:sync_skill_version`.
- Commits: one per task; review fixes in new commits; never force-push.

## Review Focus

1. **The machine switched off mid-step:** when Solid Queue re-runs the job at boot, the step marked `running` runs again and no step is recorded twice. Owner: Task 3, "resumes at the stored index".
2. **Stop pressed in two tabs, or after the run finished:** the `expected` guard changes nothing and shows a notice. Owner: Task 4, request spec "a stale press".
3. **Stop during compaction, while the compactor is between slices:** the pause is requested, and the step becomes `stopped` only once the compaction run is `paused`. Owner: Task 3, "stops compaction through its pause".
4. **A job lost from Solid Queue while its row is `running`:** Stop pauses it at once instead of showing "Stopping…" forever. Owner: Task 3, "Stop with no live job".
5. **The same batch jobs on their normal schedule:** they never stop early, because there is no flag outside a scheduled run. Owner: Task 2, "never stops outside a scheduled run".

---

### Task 1: `ScheduledRun`, the step list

**Files:**
- Create: `app/services/scheduled_run.rb`
- Test: `spec/services/scheduled_run_spec.rb`

**Interfaces:**
- Produces:
  - `ScheduledRun::SCHEDULE_PATH`;
  - `ScheduledRun::ORDER` (Array<String>);
  - `ScheduledRun::SETTINGS` (Hash{String => Symbol}, an AppSettings predicate per entry);
  - `ScheduledRun::STOPPABLE` (`%w[FactKeywordsJob EmbeddingScheduledBackfillJob]`);
  - `ScheduledRun::ARGS` (`{ "ReviewPolicyJob" => { trigger: "scheduled_run" } }`);
  - `ScheduledRun::Step = Data.define(:entry, :schedule)`, with:
    - `#label -> String` ("DatabaseBackupJob" → "Database backup", a command → itself);
    - `#enabled? -> Boolean` (SETTINGS, true when absent);
    - `#compaction? -> Boolean`;
    - `#stoppable? -> Boolean`;
    - `#run! -> void` (`entry.constantize.perform_now(**ARGS.fetch(entry, {}))`, or `eval` of a command, which comes from our config file only);
  - `ScheduledRun.steps(env: Rails.env, path: SCHEDULE_PATH) -> Array<Step>`.
- SETTINGS:

  | Entry | Setting |
  |---|---|
  | `DatabaseBackupJob` | `:scheduled_backups_enabled?` |
  | `GarbageCollectionJob` | `:garbage_collector_enabled?` |
  | `DreamStateCompactionJob` | `:dream_state_compactor_enabled?` |
  | `EmbeddingScheduledBackfillJob` | `:scheduled_embedding_backfill_enabled?` |
  | `FactKeywordsJob` | `:fact_keywords_enabled?` |
  | `StaleMemoryScanJob` | `:stale_memory_scan_enabled?` |

- [ ] **Step 1: Write the failing specs** (synthetic YAML in `tmp/`, passed as `path:`):
  - "runs each entry once, in ORDER": two `DatabaseBackupJob` entries, `ReviewPolicyJob` and `GarbageCollectionJob` give `%w[DatabaseBackupJob GarbageCollectionJob ReviewPolicyJob]`, with the first backup's schedule kept.
  - "appends an entry missing from ORDER": `SynthNewJob` comes last.
  - "leaves out ORDER entries this environment doesn't schedule".
  - "reports a setting that is off": `garbage_collector_enabled = false` makes that step not `enabled?`.
  - "knows the stoppable and compaction steps".
  - "matches the production schedule": `ScheduledRun.steps(env: "production").map(&:entry) == ScheduledRun::ORDER` (the real file).
- [ ] **Step 2: Run** `bundle exec rspec spec/services/scheduled_run_spec.rb`. Expected: it fails with `uninitialized constant ScheduledRun`.
- [ ] **Step 3: Implement.** Read with `YAML.safe_load(path.read, aliases: true)[env]` (as `MaintenanceDashboardSnapshot#schedule_hints` does). An entry is the `class` or else the `command`, de-duplicated by entry.
- [ ] **Step 4: Run** the spec. Expected: 6 examples, 0 failures.
- [ ] **Step 5: Commit** "ScheduledRun: every scheduled job once, in a safe order".

### Task 2: `CooperativeStop` in the batch jobs

**Files:**
- Create: `app/services/cooperative_stop.rb`
- Modify: `app/jobs/fact_keywords_job.rb` (check between batches), `app/services/embedding_service.rb:239-249` (check per record in both `find_each` loops)
- Test: `spec/services/cooperative_stop_spec.rb`; add examples to `spec/jobs/fact_keywords_job_spec.rb` and to the embedding backfill spec (`grep -rln backfill_all spec`)

**Interfaces:**
- Produces:
  - `CooperativeStop.with(check) { … }`, where `check` responds to `#call -> Boolean`. It is thread-scoped and nests safely, restoring the previous check.
  - `CooperativeStop.requested? -> Boolean`: false with no check. It calls the check at most once per `CooperativeStop::INTERVAL` (`2.seconds`) and remembers a true answer.

- [ ] **Step 1: Write the failing specs:**
  - `requested?` is false outside `with`, true inside `with(-> { true })`, restored after the block (and after an exception), and calls the check only once within the interval.
  - FactKeywordsJob "stops between batches when asked": with `stub_const("FactKeywordsJob::BATCH_SIZE", 2)`, five pending facts, and `CooperativeStop.with(-> { true })`, `perform` computes 2 and 3 stay pending.
  - FactKeywordsJob "never stops outside a scheduled run": all five are computed.
  - The backfill "stops between records when asked": with three facts missing vectors and the test embedding setup used by the existing backfill spec, it embeds at most one before returning, and the rest stay `missing_embedding`.
- [ ] **Step 2: Run** them. Expected: they fail with `uninitialized constant CooperativeStop`.
- [ ] **Step 3: Implement.**
  - The check lives in `Thread.current[:cooperative_stop]` (check, last checked at, answer).
  - FactKeywordsJob: `break if CooperativeStop.requested?` before each batch.
  - `backfill_all`: `break if CooperativeStop.requested?` at the top of each `find_each` block, and the observation loop is skipped once stopped.
- [ ] **Step 4: Run** the specs, plus the existing FactKeywordsJob and embedding specs. Expected: all pass.
- [ ] **Step 5: Commit** "CooperativeStop: batch jobs stop between batches inside a scheduled run".

### Task 3: `ScheduledRunJob`, the step machine

**Files:**
- Modify: `app/models/operation_progress.rb:4` (add `scheduled_run` to `OPERATION_TYPES`)
- Create: `app/jobs/scheduled_run_job.rb`
- Test: `spec/jobs/scheduled_run_job_spec.rb`

**Interfaces:**
- Consumes: Task 1's `Step`, and Task 2's `CooperativeStop.with`.
- Produces:
  - `ScheduledRunJob.current -> OperationProgress | nil`: the latest `scheduled_run` row.
  - `ScheduledRunJob.state(row = current) -> Symbol`, one of `:idle`, `:running`, `:stopping` or `:paused`. `completed` and `failed` rows are `:idle`.
  - `ScheduledRunJob.start!(steps: ScheduledRun.steps) -> OperationProgress | nil`: nil unless `:idle`.
  - `ScheduledRunJob.stop!(row) -> Boolean`: sets `stop_requested` and requests a compaction pause for a waiting compaction step. If no live job exists (see Step 3), it pauses the row at once.
  - `ScheduledRunJob.resume!(row) -> Boolean`: paused to running, then `perform_later`.
  - `ScheduledRunJob.start_over!(row) -> OperationProgress | nil`: fails the paused row with "abandoned", then `start!`.
  - `#perform(operation_id)`.
  - `COMPACTION_POLL = 1.minute`.
- Row `details`:
  ```
  { "index" => Integer, "stop_requested" => Boolean,
    "steps" => [ { "entry", "label", "schedule",
                   "outcome" => nil | "running" | "waiting" | "done" | "skipped" | "stopped" | "failed",
                   "note", "error", "started_at", "finished_at", "compaction_run_id" } ] }
  ```
  `current_count` holds the finished steps and `total_count` the step count. The run's status is `running`, `paused`, `completed` or `failed`. After every change, call `OperationProgressBroadcaster.call(row)`.

- [ ] **Step 1: Write the failing specs.** Step lists are built from small synthetic job classes (`stub_const`) unless a real job is named.
  - "runs every step in order and completes": outcomes `%w[done done done]`, the row `completed`, and `current_count == 3`.
  - "records a failing step and goes on": the middle step raises `"boom"`, giving `%w[done failed done]`, with `error == "RuntimeError: boom"` and the row `completed`.
  - "skips a step whose setting is off": the real `GarbageCollectionJob` step with the setting off gives `skipped`.
  - "waits on compaction": the first `perform` gives `waiting` and enqueues itself `wait: 1.minute`. Mark the compaction run `completed` and run `perform` again: the step is `done` with `note "completed"`, and the next step runs.
  - "a vanished compaction run": the step becomes `failed`.
  - "refuses start while running or paused".
  - "stops after a plain step": a stub step that calls `ScheduledRunJob.stop!(row)` itself, so the stop is requested mid-step, finishes `done`. The next step doesn't run, the row is `paused` with `index` at the next step, and `stop_requested` is cleared.
  - "stops a stoppable step through CooperativeStop": a stub stoppable step that loops while `!CooperativeStop.requested?` and calls `stop!` once becomes `stopped`, and the row is `paused` at that index.
  - "stops compaction through its pause": while the step is `waiting`, `stop!` sets `pause_requested` on the `CompactionRun`. Once the run is `paused`, the next `perform` marks the step `stopped` and the row `paused`.
  - "resumes at the stopped step": `resume!` re-runs the `stopped` step, finishes, and `completed`.
  - "start over abandons the paused run": the old row is `failed` with "abandoned", and a new one is `running`.
  - "Stop with no live job": in the test adapter no Solid Queue job exists, so `stop!` on a `running` row pauses it at once.
  - "resumes at the stored index": a `running` row with `index == 1` and step 1 `running` re-runs step 1, and step 0 is not run again.
  - "does nothing for a run that isn't running".
- [ ] **Step 2: Run** `bundle exec rspec spec/jobs/scheduled_run_job_spec.rb`. Expected: it fails with `uninitialized constant ScheduledRunJob`.
- [ ] **Step 3: Implement.**
  - "Live job": `ActiveJob::Base.queue_adapter_name == "solid_queue" && SolidQueue::Job.where(class_name: name, finished_at: nil).exists?`, false otherwise. In specs with a real stop, the stopping step itself is running inside `perform`, so `stop!` must not pause at once there. Pass `live: true` from inside `perform`, and have the specs call `stop!(row, live: true)`; the controller uses the default.
  - Each step runs inside `CooperativeStop.with(-> { row.reload.details["stop_requested"] })`.
  - After each step, check `stop_requested`. If it is set, pause the row (status `paused`, clear the flag, keep `index`); otherwise go on.
- [ ] **Step 4: Run** the spec. Expected: 14 examples, 0 failures.
- [ ] **Step 5: Commit** "ScheduledRunJob: run, stop and resume the scheduled jobs in sequence".

### Task 4: the switch, the status line and the card

**Files:**
- Modify: `config/routes.rb:201-204` (`post "jobs/scheduled_run", to: "jobs#scheduled_run", as: :scheduled_run`)
- Modify: `app/controllers/system/jobs_controller.rb` (add `scheduled_run`)
- Modify: `app/services/maintenance_dashboard_snapshot.rb:55-59` (`operations[:scheduled_run]`, `scheduled_steps`, `scheduled_state`, `latest_audit`)
- Create: `app/views/system/jobs/_scheduled_run_card.html.haml`
- Modify: `app/views/system/jobs/index.html.haml` (the card first), `config/locales/system.en.yml`
- Test: `spec/requests/system/jobs_spec.rb`, `spec/system/system_jobs_spec.rb` (new)

**Interfaces:**
- Consumes: `ScheduledRunJob.current`, `.state`, `.start!`, `.stop!`, `.resume!`, `.start_over!`, and `ScheduledRun.steps`.
- Produces:
  - `system_scheduled_run_path`;
  - testids `scheduled-run-card`, `btn-scheduled-run`, `btn-scheduled-run-start-over`, `scheduled-run-status`, `scheduled-run-audit` and `scheduled-run-step`;
  - `latest_audit`: the newest `AuditLog` with `created_at >= row.started_at`, or nil.

- [ ] **Step 1: Write the failing request specs:**
  - idle: the button reads **Run all scheduled jobs now** with `data-turbo-confirm` and `expected=start`, and the step list shows the schedules;
  - start: one row, the job enqueued, and the notice;
  - running: the button reads **Stop** (`expected=stop`), and the status shows "Step 2 of N", the job, the run start, the step start and the last progress;
  - stopping: **Stopping…** is disabled;
  - paused: **Resume** (`expected=resume`) and **Start over** (`expected=start_over`);
  - "a stale press": `expected=stop` against a paused row changes nothing, with a notice;
  - the audit line shows the newest audit row since the start (action, auditable type and id, actor, time), or "no graph changes logged";
  - a guest gets 403.
- [ ] **Step 2: Write the failing system example:** sign in, open `/system/jobs`, press **Run all scheduled jobs now**, accept the confirm, and see **Stop** and the status line. Run it with `perform_enqueued_jobs` off, so nothing runs.
- [ ] **Step 3: Run** both. Expected: they fail on the missing route or testids.
- [ ] **Step 4: Implement.**
  - The controller dispatches on `params[:expected]` only when it equals the current `state`'s action (`:idle` → start, `:running` → stop, `:paused` → resume or start_over); otherwise it redirects with `t("system.jobs.scheduled_run.changed")`.
  - The live counter reuses the GC card's `operation-progress` markup.
  - The step rows render from `details["steps"]`, or from `scheduled_steps` when there is no row.
- [ ] **Step 5: Run** both spec files plus `spec/requests/system/jobs_spec.rb`. Expected: all pass.
- [ ] **Step 6: Commit** "System › Background jobs: the scheduled-jobs switch and status".

### Task 5: the README version badge stays in step

**Files:**
- Modify: `lib/tasks/graph_mem.rake:65-75` (also rewrite the README badge; `README_PATH` env override, like `SKILL_PATH`), `README.md:7`
- Test: `spec/lib/tasks/sync_skill_version_spec.rb`, `spec/docs/agent_text_sync_spec.rb`

- [ ] **Step 1: Write the failing specs:**
  - the task rewrites `version-X.Y.Z-blue` in a README copy, and aborts without a badge;
  - "keeps the README version badge equal to the app version".
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement** the pattern `%r{(img\.shields\.io/badge/version-)[0-9][0-9.]*(-blue)}`, and run the task.
- [ ] **Step 4: Run** them. Expected: pass.
- [ ] **Step 5: Commit** "README version badge kept in step by sync_skill_version".

### Task 6: remove the unused PWA template

- [ ] **Step 1:** `grep -rn "pwa\|manifest.json\|service-worker" app config spec lib`. Expected: hits only in `app/views/pwa/`.
- [ ] **Step 2:** `git rm -r app/views/pwa`.
- [ ] **Step 3: Commit** "Remove the unused PWA template (nothing routed or linked it)".

### Task 7: docs, release and the PR

**Files:**
- Modify: `docs/architecture.md`, `docs/dream_state.md`, `docs/garbage_collector.md`, `CHANGELOG.md` (`## [1.81.0] - <release commit date>`), `lib/graph_mem/version.rb`, `skills/graph-mem-mcp-toolset/SKILL.md` (via the task)

- [ ] **Step 1:** Write the docs and the CHANGELOG entry:
  - Added: the switch, the order, the stop points, resume and start over, the status and audit lines;
  - Changed: the batch jobs stop inside a scheduled run; the README badge sync;
  - Removed: the PWA template.
- [ ] **Step 2:** Bump to 1.81.0 and run `bin/rails graph_mem:sync_skill_version`.
- [ ] **Step 3:** Run `rubocop`, then the full suite with the test DB truncated before and after. Expected: 0 failures.
- [ ] **Step 4:** By hand on the dev stack (`bin/dev`, Solid Queue):
  - start a run and watch the steps;
  - **Stop** during fact keywords (stops between batches) and during a plain step (Stopping…);
  - **Resume**, then **Start over**;
  - check the audit line;
  - the development list has no backup or GC step.
- [ ] **Step 5: Commit** "Release 1.81.0 (version.rb, graph_mem:sync_skill_version)". Push, and open a ready PR that lists the existing-spec edits (`spec/requests/system/jobs_spec.rb`, the FactKeywordsJob and backfill specs, the two version-sync specs).
