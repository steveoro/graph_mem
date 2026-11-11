# F2a (run every scheduled job now) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One button on System › Background jobs runs every job of `config/recurring.yml` once, in a safe order, with live progress; plus the README badge sync and the PWA template removal. Release 1.81.0.

**Architecture:** `ScheduledRun` (a service) turns the environment's `recurring.yml` section into an ordered, de-duplicated step list. `ScheduledRunJob` is a step machine whose state lives in an `OperationProgress` row (`operation_type: "scheduled_run"`). It runs each step inline, isolates failures, and waits on compaction by re-enqueuing itself. The page renders a card from that row and updates it live through the existing `operation-progress` Stimulus controller and `OperationProgressBroadcaster`.

**Tech Stack:** Rails 8.1, Solid Queue, ActionCable, HAML, Stimulus, RSpec with a real MariaDB.

**Spec:** `docs/plans/f2a-scheduled-run-design.md` (approved 2026-11-11).

## Global Constraints

- Every Ruby command: `source /usr/share/rvm/scripts/rvm && rvm use ruby-3.4.12@graph_mem && bundle exec …`; specs with `OLLAMA_URL=http://127.0.0.1:9`.
- Synthetic data only in specs; real instances over doubles. The only stub allowed is at an outside-world boundary (`db:dump`).
- Order constant, verbatim: `DatabaseBackupJob, GarbageCollectionJob, DreamStateCompactionJob, EmbeddingScheduledBackfillJob, FactKeywordsJob, StaleMemoryScanJob, ReviewPolicyJob, MaintenanceReportRowCleanupJob, ChangeSetPruneJob, ExportJob.cleanup_old_exports`.
- Compaction poll: `1.minute`. Stale after: `15.minutes`.
- Route `POST /system/jobs/scheduled_run`, operator only. Button text **Run all scheduled jobs now**, with `data-turbo-confirm`.
- Texts live in `config/locales/system.en.yml` under `system.jobs.scheduled_run`.
- Public methods get YAML-style comments (AGENTS.md).
- Version **1.81.0**: `lib/graph_mem/version.rb`, then `bin/rails graph_mem:sync_skill_version`.
- Commits: one per task; review fixes in new commits; never force-push.

## Deviation from the design (flag to Steve in the PR)

The design treats a run as stale once its progress row hasn't changed for 15 minutes. But a long inline step (garbage collection, the fact-keywords backlog) can run longer than that without touching the row, so a second press could start a parallel run. A run therefore counts as **alive** if *either*:
- its row was updated within 15 minutes; or
- Solid Queue still holds an unfinished `ScheduledRunJob` (`SolidQueue::Job.where(class_name: "ScheduledRunJob", finished_at: nil)`).

The Solid Queue check applies only when the adapter is `solid_queue`, so not in the test environment. After a power-off, Solid Queue releases the dead process's claimed job and it re-runs, continuing from the stored index.

## Review Focus

1. **wks-0 is powered off mid-step:** the step marked `running` re-runs on resume, and a step is never recorded twice. Owner: Task 2, example "resumes at the stored index".
2. **A second press during a long inline step:** it must be refused, not start a parallel run. Owner: Task 2 (time rule); the Solid Queue rule is checked by hand on wks-0 (Task 6).
3. **A job raises while the compactor is waiting:** a failure in the poll itself (the compaction run row deleted) records the step as failed and moves on. Owner: Task 2, example "a vanished compaction run".
4. **`recurring.yml` gains a job missing from `ORDER`:** it runs last and the drift spec fails. Owner: Task 1.
5. **The operator's browser misses the broadcasts:** a reload must still show the right step and outcomes from the row. Owner: Task 3, the request spec renders a mid-run row.

---

### Task 1: `ScheduledRun`, the step list

**Files:**
- Create: `app/services/scheduled_run.rb`
- Test: `spec/services/scheduled_run_spec.rb`

**Interfaces:**
- Produces:
  - `ScheduledRun::ORDER` (Array<String>);
  - `ScheduledRun::SETTINGS` (Hash{String => Symbol}, an AppSettings predicate per entry);
  - `ScheduledRun::ARGS` (`{ "ReviewPolicyJob" => { trigger: "scheduled_run" } }`);
  - `ScheduledRun::Step = Data.define(:entry, :schedule)`, with `#label -> String` (`"DatabaseBackupJob"` → "Database backup", a command → itself), `#enabled? -> Boolean` (SETTINGS, true when absent), `#compaction? -> Boolean`, and `#run! -> void` (`entry.constantize.perform_now(**ARGS.fetch(entry, {}))` for a class, `eval(entry)` for a command, the `command` being read from our config file only);
  - `ScheduledRun.steps(env: Rails.env, path: ScheduledRun::SCHEDULE_PATH) -> Array<Step>`.
- SETTINGS:

  | Entry | Setting |
  |---|---|
  | `DatabaseBackupJob` | `:scheduled_backups_enabled?` |
  | `GarbageCollectionJob` | `:garbage_collector_enabled?` |
  | `DreamStateCompactionJob` | `:dream_state_compactor_enabled?` |
  | `EmbeddingScheduledBackfillJob` | `:scheduled_embedding_backfill_enabled?` |
  | `FactKeywordsJob` | `:fact_keywords_enabled?` |
  | `StaleMemoryScanJob` | `:stale_memory_scan_enabled?` |

- [ ] **Step 1: Write the failing specs** in `spec/services/scheduled_run_spec.rb`, each writing a synthetic YAML to `tmp/` and passing `path:`:
  - "runs each entry once, in ORDER": a section with two `DatabaseBackupJob` entries (13:00 and 17:00), `ReviewPolicyJob` and `GarbageCollectionJob` gives `steps.map(&:entry) == %w[DatabaseBackupJob GarbageCollectionJob ReviewPolicyJob]`, with the backup's schedule being the first one listed.
  - "appends an entry missing from ORDER": `SynthNewJob` comes last.
  - "leaves out ORDER entries this environment doesn't schedule", for example `env: "development"` with no backup.
  - "reports a setting that is off": `AppSettings.garbage_collector_enabled = false` makes `GarbageCollectionJob`'s step `enabled?` false. Clean up in `after`.
  - "matches the production schedule": `ScheduledRun.steps(env: "production").map(&:entry) == ScheduledRun::ORDER`, against the real `config/recurring.yml`.
- [ ] **Step 2: Run** `bundle exec rspec spec/services/scheduled_run_spec.rb`. Expected: it fails with `uninitialized constant ScheduledRun`.
- [ ] **Step 3: Implement** `app/services/scheduled_run.rb`. Read the YAML with `YAML.safe_load(path.read, aliases: true)[env]` (as `MaintenanceDashboardSnapshot#schedule_hints` does). An entry is the `class` or else the `command`, and it is de-duplicated by entry.
- [ ] **Step 4: Run** the spec. Expected: 5 examples, 0 failures.
- [ ] **Step 5: Commit** "ScheduledRun: every scheduled job once, in a safe order".

### Task 2: `ScheduledRunJob`, the step machine

**Files:**
- Modify: `app/models/operation_progress.rb:4` (add `scheduled_run` to `OPERATION_TYPES`)
- Create: `app/jobs/scheduled_run_job.rb`
- Test: `spec/jobs/scheduled_run_job_spec.rb`

**Interfaces:**
- Consumes: `ScheduledRun.steps`, `Step#run!`, `#enabled?`, `#compaction?`, `#label`, `#schedule`.
- Produces:
  - `ScheduledRunJob.start!(steps: ScheduledRun.steps) -> OperationProgress | nil`. It returns nil when a live run exists, and marks a stale one `fail!("interrupted")`.
  - `ScheduledRunJob.current -> OperationProgress | nil`, the latest `scheduled_run` row.
  - `ScheduledRunJob#perform(operation_id)`.
  - Constants `STALE_AFTER = 15.minutes` and `COMPACTION_POLL = 1.minute`.
- Row `details`:
  ```
  { "index" => Integer,
    "steps" => [ { "entry", "label", "schedule",
                   "outcome" => nil | "running" | "waiting" | "done" | "skipped" | "failed",
                   "note", "error", "started_at", "finished_at", "compaction_run_id" } ] }
  ```
  `current_count` holds the number of finished steps and `total_count` the step count. After every change, call `OperationProgressBroadcaster.call(row)`.

- [ ] **Step 1: Write the failing specs** in `spec/jobs/scheduled_run_job_spec.rb`. Build the step lists from small synthetic job classes defined in the spec (`stub_const`), so no real job runs, except where named:
  - "runs every step in order and completes": three steps give outcomes `%w[done done done]`, the row is `completed`, and `current_count == 3`.
  - "records a failing step and goes on": the middle class raises `RuntimeError, "boom"`, giving outcomes `%w[done failed done]`, with `error == "RuntimeError: boom"` and the row `completed`.
  - "skips a step whose setting is off": the real `GarbageCollectionJob` step with `garbage_collector_enabled = false` gives outcome `skipped`.
  - "waits on compaction": the real compaction step with the compactor enabled. The first `perform` gives `waiting` and enqueues `ScheduledRunJob` with `wait: 1.minute` (`have_enqueued_job.with(row.operation_id)`). Then mark the `CompactionRun` `completed` and run `perform` again: the step is `done` with `note == "completed"`, and the next step has run.
  - "a vanished compaction run": delete the `CompactionRun` between performs, and the step becomes `failed`.
  - "refuses a second start while live": `start!` twice returns nil the second time, and only one row is `running`.
  - "replaces a stale run": with `travel 16.minutes`, `start!` fails the old row with message "interrupted" and returns a new one.
  - "does nothing for a replaced run": `perform(old.operation_id)` after replacement runs no step.
  - "resumes at the stored index": a row whose `index == 1` and step 1 `running` re-runs step 1 and finishes the rest, with step 0 not run again.
- [ ] **Step 2: Run** `bundle exec rspec spec/jobs/scheduled_run_job_spec.rb`. Expected: it fails with `uninitialized constant ScheduledRunJob`.
- [ ] **Step 3: Implement.**
  - `queue_as :default`.
  - `start!` creates the row with `OperationProgress.start!(operation_type: "scheduled_run", total_count: steps.size, details: …)` and calls `perform_later(row.operation_id)`.
  - A run is live if its row is `running` and either it was updated within `STALE_AFTER`, or `ActiveJob::Base.queue_adapter_name == "solid_queue"` and `SolidQueue::Job.where(class_name: name, finished_at: nil).exists?`.
  - `perform` loads the row and returns unless it is `running`. It then walks from `details["index"]`:
    - a step that isn't enabled is `skipped`;
    - for a compaction step: start `CompactionRunner.start_or_resume!` once and store `compaction_run_id`, re-enqueue, and return; on later performs, poll until the run's status is `completed`, `paused` or `failed`;
    - any other step: `run!` inside `rescue StandardError`.
  - Persist after each step, and `complete!` at the end.
- [ ] **Step 4: Run** the spec. Expected: 9 examples, 0 failures.
- [ ] **Step 5: Commit** "ScheduledRunJob: run the scheduled jobs in sequence, waiting on compaction".

### Task 3: the "Scheduled jobs" card and its route

**Files:**
- Modify: `config/routes.rb:201-204` (add `post "jobs/scheduled_run", to: "jobs#run_scheduled", as: :run_scheduled_jobs`)
- Modify: `app/controllers/system/jobs_controller.rb` (add `run_scheduled`)
- Modify: `app/services/maintenance_dashboard_snapshot.rb:55-59` (`operations[:scheduled_run] = ScheduledRunJob.current&.snapshot`, plus `scheduled_steps: ScheduledRun.steps`)
- Create: `app/views/system/jobs/_scheduled_run_card.html.haml`
- Modify: `app/views/system/jobs/index.html.haml` (render the card first)
- Modify: `config/locales/system.en.yml` (`system.jobs.scheduled_run.*`; the subtitle mentions scheduled jobs too)
- Test: `spec/requests/system/jobs_spec.rb`, `spec/system/system_jobs_spec.rb` (new)

**Interfaces:**
- Consumes: `ScheduledRunJob.start!`, `.current`, and `ScheduledRun.steps`.
- Produces: `system_run_scheduled_jobs_path`; testids `scheduled-run-card`, `btn-scheduled-run` and `scheduled-run-step`.

- [ ] **Step 1: Write the failing request specs:**
  - the card lists the steps of `ScheduledRun.steps` with their schedules, and the button has `data-turbo-confirm`;
  - `POST` starts a run (one `scheduled_run` row, `ScheduledRunJob` enqueued) and redirects with the notice;
  - a second `POST` while it is live redirects with the alert and creates no row;
  - a guest gets 403;
  - Review Focus 5: a row mid-run (index 2, outcomes done/skipped/running) renders "Step 3 of N" and each outcome, with the button disabled.
- [ ] **Step 2: Write the failing system example** (`spec/system/system_jobs_spec.rb`): sign in, open `/system/jobs`, click **Run all scheduled jobs now**, accept the confirm, and see the notice and the card in a running state. Run it with `perform_enqueued_jobs` off, so nothing runs.
- [ ] **Step 3: Run** both spec files. Expected: they fail on the missing route or testids.
- [ ] **Step 4: Implement.**
  - `run_scheduled` calls `ScheduledRunJob.start!` and redirects back, with `notice: t("system.jobs.scheduled_run.started")` or, when nil, `alert: t("system.jobs.scheduled_run.busy")`.
  - The card uses the GC card's `operation-progress` markup for the live counter.
  - The step rows render from `details["steps"]` when a row exists, else from `scheduled_steps`.
  - An idle card shows the last run's started and finished times and its done/skipped/failed counts.
- [ ] **Step 5: Run** both spec files plus `spec/requests/system/jobs_spec.rb`. Expected: all pass.
- [ ] **Step 6: Commit** "System › Background jobs: run all scheduled jobs now".

### Task 4: the README version badge stays in step

**Files:**
- Modify: `lib/tasks/graph_mem.rake:65-75` (also rewrite the README badge; `README_PATH` env override for specs, like `SKILL_PATH`)
- Modify: `README.md:7` (badge to the current version, via the task)
- Test: `spec/lib/tasks/sync_skill_version_spec.rb`, `spec/docs/agent_text_sync_spec.rb`

- [ ] **Step 1: Write the failing specs:**
  - the task rewrites `version-X.Y.Z-blue` in a README copy to `GraphMem::VERSION`, and aborts when the badge is missing;
  - `agent_text_sync_spec.rb`: "keeps the README version badge equal to the app version".
- [ ] **Step 2: Run** them. Expected: they fail (the badge says 1.52.1).
- [ ] **Step 3: Implement** the pattern `%r{(img\.shields\.io/badge/version-)[0-9][0-9.]*(-blue)}`, and run `bin/rails graph_mem:sync_skill_version`.
- [ ] **Step 4: Run** both specs. Expected: pass.
- [ ] **Step 5: Commit** "README version badge kept in step by sync_skill_version".

### Task 5: remove the unused PWA template

**Files:**
- Delete: `app/views/pwa/manifest.json.erb`, `app/views/pwa/service-worker.js`

- [ ] **Step 1:** `grep -rn "pwa\|manifest.json\|service-worker" app config spec lib`. Expected: no hits outside `app/views/pwa/`.
- [ ] **Step 2:** `git rm -r app/views/pwa`.
- [ ] **Step 3: Commit** "Remove the unused PWA template (nothing routed or linked it)".

### Task 6: docs, release and the PR

**Files:**
- Modify: `docs/architecture.md` (background jobs), `docs/dream_state.md`, `docs/garbage_collector.md` (one "Run all scheduled jobs now" note each)
- Modify: `CHANGELOG.md` (`## [1.81.0] - <release commit date>`), `lib/graph_mem/version.rb`, `skills/graph-mem-mcp-toolset/SKILL.md` (via the task)

- [ ] **Step 1:** Write the docs and the CHANGELOG entry: Added (the button, the order, failure isolation, compaction wait, the stale rule with the Solid Queue check); Changed (the README badge sync); Removed (the PWA template).
- [ ] **Step 2:** Bump to 1.81.0 and run `bin/rails graph_mem:sync_skill_version` (SKILL.md and the README badge).
- [ ] **Step 3:** Run `rubocop`, then the full suite with the test DB truncated before and after. Expected: 0 failures.
- [ ] **Step 4:** By hand on the dev stack (`bin/dev`, `solid_queue`): press the button, watch the card step through the run, press again during a step (refused), and confirm that the development list has no backup or GC step (development doesn't schedule them).
- [ ] **Step 5: Commit** "Release 1.81.0 (version.rb, graph_mem:sync_skill_version)". Push, and open a ready PR. List the existing-spec edits (`spec/requests/system/jobs_spec.rb`, the two version-sync specs) and the stale-rule deviation in the PR body.
