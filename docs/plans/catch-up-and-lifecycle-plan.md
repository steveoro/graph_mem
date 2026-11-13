# Scheduled-run catch-up and lifecycle repair (plan, 1.86.0)

## Context

- **Night jobs never run.** wks-0 is off at night, and Solid Queue skips a missed recurring slot. So the 3:00–5:15
  jobs never fire: compaction, embedding backfill, fact keywords, stale scan, review policies, row cleanup, change-set
  prune. Steve runs "Run all scheduled jobs now" (`ScheduledRunJob`) at lunch. Found in the 1.85.0 investigation
  (`docs/plans/review-queue-noise-plan.md`, section D).
- **A lifecycle_corruption row that Apply can't fix.** Production row 331 points at observation #4217: superseded,
  `superseded_by` NULL, `outdated_by` #4227. It happened in three steps:
  - on 11-03 a fact supersede was applied with **Supersede…** and no replacement text, so the fact's own text became
    the replacement: a byte-identical copy (#4249) of fact #4227, on the same entity;
  - the 14:00 garbage collection on 11-04 deleted #4249 as a duplicate, and the `ON DELETE SET NULL` foreign key
    cleared #4217's link;
  - the integrity sweep then flagged #4217. `CompactionReviewApplier` has no branch for `lifecycle_corruption`
    ("Unknown review kind"), so Apply does nothing.

Steve's decisions (2026-11-13):
1. The catch-up starts soon after boot, is on by default, and has a setting to turn it off.
2. One PR, 1.86.0.

## Part A: catch-up

- **New `ScheduledRunCatchUpJob`,** recurring every 15 minutes in production. In development it doesn't recur (no
  surprise runs on a dev box); specs call it directly. It starts `ScheduledRunJob.start!` only when all of these hold:
  - the setting `scheduled_run_catch_up_enabled` (default true) is on;
  - Solid Queue's oldest live supervisor (`SolidQueue::Process`) has been up at least `BOOT_GRACE` (20 min), so the
    machine has settled before a long run starts;
  - no scheduled run is running, stopping or paused. A paused run is never auto-resumed: Steve paused it for a reason;
  - no scheduled run *started* within `OVERDUE_AFTER` (20 h), whatever its outcome;
  - no compaction run started within `OVERDUE_AFTER`. If the host was up at night, the nightly slots already ran.
- **The run shows who started it.** The existing row records a trigger: "catch-up" vs "manual". The card says
  "Started automatically (catch-up)", and the catch-up logs one line with its reason when it starts a run.
- **Settings:** `scheduled_run_catch_up_enabled` in System › Settings, next to the review policy toggles (or wherever the
  scheduled-run settings live), with i18n.
- **Docs:** `docs/architecture.md` (Background jobs) and the Background jobs operator doc.

## Part B: lifecycle_corruption

- **B1, repair action.** `CompactionReviewApplier` gets a `lifecycle_corruption` branch, with a preview. Each issue
  re-checks the live row:
  - "superseded observation has no superseded_by reference":
    - if `outdated_by` is set, active, and on the same entity, set `superseded_by = outdated_by` (#4217 → #4227);
    - otherwise set the status to `obsolete`, keeping `obsoleted_at`, its reason and `outdated_by`;
  - "active observation has obsoleted_at set": clear `obsoleted_at` (and the stale `obsolescence_reason`);
  - cross-entity `superseded_by`: no automatic repair; the view offers Dismiss only.
  - Each repair is audited and undoable, inside the `review.apply` change set like other applies. A row whose issue no
    longer holds is "already consistent", which the Dangling policy can dismiss.
  - The view (`review/kinds/_lifecycle_corruption`) says what's wrong and what Repair will do.
- **B2, no twin replacement.** `CompactionReviewApplier::FactSupersede` (supersede action): when the replacement text
  equals the fact's text and the fact is on the same entity, don't create a copy. Point `superseded_by` at the fact.
  This needs a model path (e.g. `supersede!(by: fact)`) that sets the status and reason without creating a
  replacement.
- **B3, GC keeps links.** Before the garbage collection's duplicate pass deletes a duplicate, it repoints every
  `superseded_by_id` / `outdated_by_id` that targets a deleted id to the kept copy (`keep_id`), so no link is
  nulled by the foreign key.

## Verification

- Specs, each seen failing first:
  - each catch-up condition (each blocks the start on its own; all clear → started; paused → not resumed);
  - each repair branch, and undo;
  - supersede with the fact's own text makes no twin;
  - GC repoints the links before deleting.
- Full suite with the test DB truncated before and after; rubocop.
- **On production after deploy:**
  - Review & Fix row 331 → Repair: #4217 gets `superseded_by` #4227;
  - after the next boot, the run starts by itself after ~20 min.
