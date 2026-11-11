# F2a → graph_mem 1.81.0: run every scheduled job now, plus small follow-ups

**Status (2026-11-11): DESIGN, for Steve's review.** Written from `main` at `1a65a64` (1.80.1). The implementation
plan comes after this design is approved. F2b (LLM keywords for facts with no entity mentions) follows F2a; its
decisions are recorded in graph_mem (entity "Fact Pertinence", 2026-11-11) and get their own design file.

## Why

wks-0 is off at night, so the jobs scheduled between 3:00 and 5:30 (GMT) never run there: compaction, the
embedding backfill, fact keywords, the contradiction scan, the review policies and the clean-ups. The afternoon
jobs (backups at 13:00 and 17:00, garbage collection at 14:00) run only when wks-0 is on at those times. Steve
often has a couple of hours in the afternoon while he's out: one button should run **every** scheduled job then,
in a safe order, and show how far it got. F2b's backfill depends on this, since it runs with the fact-keywords job.

## Decisions (Steve, 2026-11-11)

1. One button runs **all** the scheduled jobs, not only the night ones (wks-0 is off at night; the schedule stays
   for machines that are on then, such as wks-2b).
2. Ship F2a first, then F2b.
3. The unused PWA template files are removed; the manifest colour and maskable-icon follow-ups are dropped with them.
4. The README version badge is kept in step with `GraphMem::VERSION`.
5. **One start/stop switch, never a button that re-enables itself** (2026-11-11, after the first plan): Run →
   Stop → (Stopping…) → Resume, so no second run can start while one is running or paused. A paused run resumes
   where it stopped, a paused compaction from its own cursor.
6. **Stop inside batch jobs too**, not only between jobs: compaction pauses through its own pause, and the jobs
   that loop over batches whose progress lives in the database stop between batches and continue on Resume.
7. **A status line**: the current or last job, when the run and the step started, the last progress report, and
   the latest audit-log entry since the run started.

## Design

### 1. `ScheduledRun`: what runs, in which order

`app/services/scheduled_run.rb`. The jobs come from the current environment's section of `config/recurring.yml`
(`Rails.application.config_for(:recurring)`), each **once**: two entries with the same `class` (the two backups) or
the same `command` count as one. They run in the order of `ScheduledRun::ORDER`:

| # | Entry (class or command) | Why here |
|---|---|---|
| 1 | `DatabaseBackupJob` | a restore point before anything changes |
| 2 | `GarbageCollectionJob` | prunes before the graph is compacted |
| 3 | `DreamStateCompactionJob` | waited on until its run ends (§2) |
| 4 | `EmbeddingScheduledBackfillJob` | vectors for what compaction touched |
| 5 | `FactKeywordsJob` | the paths steps 6 and 7 read (F2b adds the LLM words here) |
| 6 | `StaleMemoryScanJob` | contradiction and stale-memory rows |
| 7 | `ReviewPolicyJob` | sees the fresh rows and paths |
| 8 | `MaintenanceReportRowCleanupJob` | |
| 9 | `ChangeSetPruneJob` | |
| 10 | `ExportJob.cleanup_old_exports` (command) | |

- An entry of `recurring.yml` missing from `ORDER` still runs, **after** the listed ones, so a job added to the
  schedule later is never skipped. A spec fails while the production section and `ORDER` disagree, as a reminder to
  place it.
- An `ORDER` entry not scheduled in the current environment doesn't run (development schedules no backup or GC).
- **Skipped steps:** `ScheduledRun::SETTINGS` names each job's own on/off setting where it has one (for example
  `DatabaseBackupJob` → `scheduled_backups_enabled?`, `GarbageCollectionJob` → `garbage_collector_enabled?`). A step
  whose setting is off is shown as **skipped** and not run. A job without an entry is always run; it may still
  return early on its own checks, as it does at night.
- A `command` entry runs the same way Solid Queue runs it (`eval` of the configured string). It is read from our
  own config file only, never from user input.

### 2. `ScheduledRunJob`: running, stopping and resuming the steps

`app/jobs/scheduled_run_job.rb`, queue `default`. The run's state lives in an `OperationProgress` row
(`operation_type: "scheduled_run"`): the step list, the current index, and each step's outcome (`done`,
`skipped`, `failed` with the error class and message, plus start and finish times). That's the existing progress
model, so the page updates live over `OperationProgressChannel`.

- Each step runs **inline** (`perform_now`, or the command), one at a time. A step that raises is recorded as
  `failed` and logged, and the run goes on with the next step: one broken job doesn't block the others.
- **Compaction** works in slices (each slice re-enqueues itself). The run calls `CompactionRunner.start_or_resume!`,
  records the compaction run id, then re-enqueues **itself** (`wait: 1.minute`) and returns. Each check refreshes
  the progress row, and once the compaction run is `completed`, `paused` or `failed`, the step is recorded (a
  paused or failed run as `done` with its status) and the next step runs. With the compactor setting off, the step
  is skipped.
- **One run at a time, with no timer:** a run is `running` until it finishes or is stopped; while it is
  `running` or `paused`, the button never starts another one (decision 5). A job that wakes up for a run that is
  no longer `running` does nothing.
- **Stop** (the same button) sets `details["stop_requested"]`:
  - compaction: `CompactionRun#request_pause!` at once; when its run is `paused`, the step is `stopped` and the run
    `paused`;
  - a **stoppable** job (`FactKeywordsJob`; the embedding backfill, `EmbeddingService#backfill_all`) checks
    `CooperativeStop.requested?` between batches (FactKeywordsJob) or records (the backfill) and returns early;
    the step is `stopped` and the run `paused`. Their progress lives in the database (pending paths, missing
    vectors), so running the step again continues the work;
  - any other job finishes; the run pauses before the next step ("Stopping after: <job>");
  - `CooperativeStop` is a thread-scoped check set only while `ScheduledRunJob` runs a step, so the same jobs run
    unchanged on their schedule or from their own buttons.
- **Resume** re-runs the step it stopped at (a paused compaction resumes from its cursor) and goes on.
  **Start over**, next to Resume, closes the paused run (`failed`, "abandoned") and starts at step 1.
- **wks-0 switched off mid-run:** Solid Queue releases the dead process's job at boot and it runs again,
  continuing at the stored step. If no `ScheduledRunJob` is left in Solid Queue for a `running` row (its job was
  lost), **Stop** pauses the row at once, since nothing is running to stop.
- The schedule in `recurring.yml` is unchanged.

### 3. System › Background jobs: the "Scheduled jobs" card

- A new card on `/system/jobs`, above the compactor and GC cards. It lists the steps in run order, each with its
  schedule (from `recurring.yml`) and, during or after a run, its outcome.
- **One switch** (`POST /system/jobs/scheduled_run`, operator only like the other controls), whose label and
  action follow the run's state:

  | State | Button | Press |
  |---|---|---|
  | none, completed or failed | **Run all scheduled jobs now** | start (with `data-turbo-confirm`, as the GC card's **Run now** does) |
  | running | **Stop** | request a stop |
  | running, stop requested | **Stopping…** (disabled) | — |
  | paused | **Resume** (and a small **Start over**) | continue / abandon and start again |

  The form posts the state it was rendered for (`expected: start|stop|resume|start_over`); a press that no
  longer matches the row's state (another tab, a finished run) changes nothing and redirects with a notice.
- **Status line**, live while running and kept after a reload:
  - "Step *n* of *N*: <job> · run started HH:MM · step started HH:MM · last progress HH:MM" (or, idle, the last
    run's start, finish and its done / skipped / stopped / failed counts);
  - "Latest graph change: <action> · <auditable_type> #<id> · by <actor> · HH:MM", the newest `AuditLog` row
    created since the run started, or "no graph changes logged". Jobs that change the graph through the services
    write audit rows with their actor, so this shows what is happening even when a job reports no progress.
- The step list shows each job's schedule and, during or after a run, its outcome.
- Texts go to the locale file, like the rest of System.

### 4. Follow-ups folded in

- **README version badge:** `bin/rails graph_mem:sync_skill_version` also rewrites the README's version badge, and
  `spec/docs/agent_text_sync_spec.rb` checks it equals `GraphMem::VERSION` (it says 1.52.1 today).
- **PWA template removed:** `app/views/pwa/manifest.json.erb` and `app/views/pwa/service-worker.js` (nothing routes
  or links them). `public/icon.png` and `public/icon.svg` stay: the favicon and the Apple touch icon use them.

### 5. Tests (synthetic, real instances)

- `ScheduledRun`: dedupe of the two backups, `ORDER` applied, an unlisted entry appended, an entry not scheduled in
  this environment left out, a setting-off step reported as skipped; the production section of `recurring.yml`
  matches `ORDER`.
- `ScheduledRunJob`: steps run in order; a failing step is recorded and the next one runs; compaction is waited on
  (re-enqueued until its run ends); start is refused while a run is running or paused; stop pauses after a plain
  step, pauses compaction through its own pause, and stops a stoppable job between batches; resume continues at the
  stopped step; start over abandons the paused run; a job for a run that isn't running does nothing; a lost job's
  row is paused at once by Stop.
- `CooperativeStop`, `FactKeywordsJob` and `EmbeddingService#backfill_all`: they stop early only inside a scheduled
  run with a stop requested, and the remaining work is still pending afterwards. Jobs that would touch the outside world (the backup's `db:dump`) are stubbed at that
  boundary only.
- Request spec for the new route (operator only, notice, refused while active); one system example for the card
  (button, confirmation, progress text).
- The README badge check in `agent_text_sync_spec.rb`.

### 6. Docs and release

- `docs/architecture.md` (background jobs), a short "Run all scheduled jobs now" note in `docs/dream_state.md` and
  `docs/garbage_collector.md` (both describe the System › Background jobs page), and the CHANGELOG.
- **1.81.0** (a feature), via `lib/graph_mem/version.rb` and `bin/rails graph_mem:sync_skill_version`.

## Not in F2a

- F2b: `llm_keywords` (column, LLM step, scan inline, the backfill inside `FactKeywordsJob`).
- Changing the schedule's times, or a per-job "run now" for every job (compaction and GC already have their own
  buttons).
