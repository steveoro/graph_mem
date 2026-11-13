# Review queue noise: from 447 rows to about 40 (plan, 1.85.0)

## Context

On 2026-11-12 Steve pressed "Run all scheduled jobs now" on 1.84.0. The Review queue went from about 23 active
rows to 447. Steve's example, contradiction #3620 (goggles_db) vs #3622 (goggles_main), pairs two release notes
of two different projects. The queue should shrink algorithmically, not through a DB restore.

Investigation (2026-11-13). Everything was read-only against production (`docker exec graph_mem-app-1 bin/rails runner`), then
checked against the code:

| Kind | Active | Producer | Real (judged) |
|---|---|---|---|
| entity_merge | 234 | `DreamStateCompactor` tree walk → `EntityMergeEvidence.score_pair` | ~10-15 |
| relationship_proposal | 171 | `RelationshipDiscoveryStrategy` | 2 (`depends_on`) |
| orphan_parent | 30 | `OrphanMatchingStrategy` | ~5 |
| contradiction | 22 | `StaleMemoryScanner.detect_contradictions` → `ContradictionDetector` | 5 (all supersede-shaped) |
| stale_memory, lifecycle_corruption | 3 | | |

**Why it jumped.** The 14:17 run was the first compaction since June. Solid Queue skips a missed recurring slot,
and the host is off at night, so the night jobs have never fired:
- 3am compaction;
- 4am embedding backfill;
- 4:30 stale scan;
- fact keywords, review policies and the cleanups.

`SolidQueue::RecurringExecution` has rows only for the 13:00-18:00 jobs. A full traversal of 505 entities then met
loose producer thresholds and a per-run cap that never binds.

## Root causes

1. **Boilerplate facts count as evidence.** Identical "Key: value" lines ("Status: Completed", "Priority: Medium",
   "Successfully refactored to use fast-mcp syntax.") sit on dozens of entities.
   - `RelationshipDiscoveryStrategy#shared_observation_proposals` (`app/strategies/relationship_discovery_strategy.rb:41-71`)
     turns every pair that shares one into a `relates_to` with a hard-coded `high` / score 10. That gives 143 of
     the 171 rows, as cliques per string.
   - `EntityMergeEvidence#shared_observation_count` adds up to +6 for the same lines. All 6 of the score-10 merges
     are such pairs.
2. **The merge review floor equals the distance-only score.** `score_pair` gives +4 for any same-type pair within
   0.30 (`entity_merge_evidence.rb:62`). `REVIEW_SCORE` is 4, so every near pair is queued: 169 rows at score 4,
   about 2% real.
3. **The per-run cap counts through pruned reports.**
   - `SeedLimits#earlier_in_run` counts rows via reports with the run's `source_ref`.
   - The compactor writes one report per entity, and `MaintenanceReport::MAX_REPORTS_PER_TYPE = 30` prunes the
     rest with `delete_all`.
   - So the 100-per-kind cap (`ReviewRowClassifier::RUN_CAPS`) never binds: 234 merges were seeded.
   - The run stats also count candidates before the cap (merges_queued 290 vs 234 seeded).
4. **Orphan suggestions without evidence.**
   - The +2 bonus for the agent's active project alone passes `score > 0`: 20 rows with `matched_tokens: []`.
   - Substring matches of 2-letter tokens ("if" and "sh" in TwelveShifts, "go" in goggles) add 5.
5. **Contradictions.**
   - The `:unknown` fallback pairs any two mention-less facts within 0.15 (`contradiction_detector.rb:89`): 16 of 22,
     Steve's example included. Its keyword paths are just `["goggles_db"]` / `["goggles_main"]`.
   - Two different Project roots never come out `:unrelated` (`fact_keywords/relatedness.rb:188`).
   - The polarity check is a bag of words: "no offenses", `= false`, `NOT NULL` and "removed …" in a changelog all
     count.
   - The policy ran at seed time, before the LLM words landed.

## Plan

### A. Producer gates

- **A1. Boilerplate filter (shared).** A small service, e.g. `ObservationEvidence.distinctive?(content)`, used by
  both producers. Shared content counts as evidence only when all of these hold:
  - it is at least 40 chars;
  - it is not a `Key: value` line (`/\A[\w ]{2,20}:\s/`);
  - it is held by ≤ 2 entities (one grouped count per run, not a query per pair).
- **A2. Relationship proposals.** Drop the identical-content `relates_to` rule (0 of 31 approvals ever came from it;
  decision 1). `solves` needs ≥ 3 shared terms, the existing high-band line. Do not add an IDF cutoff on `solves`:
  it would lose 23-30 of the 31 approvals. **171 → 2.**
- **A3. Entity merges.**
  - Shared-observation credit goes through A1.
  - `REVIEW_SCORE` goes to 6, so a pair needs more than "within 0.30". Distance < 0.10 still scores 8 and queues.
  - **234 → ~26**, which keeps the fast-mcp_gem/fastmcp_gem, CSRF, Phase and TinyMCE duplicates.
- **A4. Orphans.**
  - The context bonus applies only when at least one token matched.
  - Substring matches need a token of ≥ 3 chars.
  - A suggestion needs a score of at least 8 (review: 6 let the context bonus decide), and an orphan with no suggestion left isn't queued (it stays an
    orphan, visible on Explore).
  - **30 → 5.**
- **A5. Contradictions.** All of these together lose none of the 5 real rows: **22 → 11**.
  - Skip a pair when both sides are dated events (a leading `[YYYY-MM-DD]`): two events don't contradict.
  - A shared mention of another project's root, or of an entity owned by another project, doesn't make the
    "same subject".
  - Two different Project roots compare `:unrelated`.
  - Don't pair through the `:unknown` fallback while either side's LLM words are pending. Re-judge once they land.
  - Decision 2 (Steve, 2026-11-13): the `:unknown` fallback no longer creates contradiction rows. The 5 real rows
    are all "the newer procedure replaces the older" cases, so such a pair goes through FactSupersede's own
    filters instead:
    - `LegacyGuard` keeps work logs, versions and other projects' statements;
    - `FactSupersede::Judge` (local LLM) decides superseded / still_valid / unrelated, newer side as the fact;
    - only a `superseded` verdict queues a `fact_supersede` row (same payload as Find & supersede, source
      "contradiction_fallback").
    - Contradiction rows stay for pairs with a shared subject (mention or LLM words): **22 → ~6**, plus the few
      supersede rows the judge confirms.
    - None of the 5 real pairs has a fact_supersede row today. The pairs are capped per run, like the other kinds,
      to bound the LLM calls.

### B. Plumbing

- **B1. Per-run cap that binds.** `SeedLimits` counts what the run seeded in memory (or by `source_ref` on the rows),
  not through reports that pruning deletes. Rank inside a kind by (score, -distance) before the cap: today's
  priority is flat (53-60), so it doesn't rank.
- **B2. Honest run stats.** `merges_queued`, `relationships_queued` and `orphans_queued` count rows actually seeded.
- **B3.** Report pruning leaves rows with `maintenance_report_id = nil` (all 234 merges). Check that nothing relies
  on the report (the review UI, the cap, exports); document it or keep the run's reports.

### C. The existing backlog: a re-check policy, no restore

A review policy `StillQualifies`, modelled on `ReviewPolicies::NoLongerFlagged`:
- For each active row of the four kinds, re-run the producer's current gate (A2-A5) on the live entities and
  observations.
- Dismiss, without suppression, the rows that no longer qualify: "below the current evidence bar".
- It runs with "Run policies now" and the scheduled policy run.
- Spec it against real rows of each kind.
- Expected: **447 → ~40**. Rows Steve already acted on are untouched.

### D. Night jobs that never run (decision 3)

The host is off at night, so every night slot is dead. Options:
- (a) Move the daily slots into the 13:00-18:00 window where the host is up. Simple, but it pins the schedule to
  today's habits.
- (b) A catch-up: an hourly `OverdueJobsJob` that runs a daily job whose last run (its RecurringExecution, or the
  job's own record) is older than 24 h. Robust to any uptime.

The recommendation is (b). It is a separate small PR, after A-C: once the gates are fixed, running compaction
nightly is safe.

### Not in scope

- Policy dismissals (329) leave no suppression. That's by design: the signal may return and the policy re-dismisses.
- The data smell "goggles_db (a Project root) `part_of` goggles_main" is Steve's call in the graph, not code.

## Decisions (Steve, 2026-11-13)

1. The identical-content `relates_to` rule is dropped entirely.
2. The `:unknown` pairs go through FactSupersede (A5).
3. Night jobs: the catch-up job (D, option b), in a follow-up PR.
   - wks-0 is off at night, and Steve runs all scheduled jobs at lunch.
   - The catch-up makes that press optional: whenever the host is up, the overdue daily jobs run.

## Graph data (by hand, not code)

- **Relations between the Goggles projects.**
  - `part_of` is ownership with a single parent (`GraphVocabulary::SINGLE_PARENT_TYPES`), so goggles_db can't be
    `part_of` the three apps that use it.
  - The right shape is the one the apps already have: goggles_main, goggles_api and goggles_admin2 `depends_on`
    goggles_db. "Used by" is that edge read backwards.
  - Done 2026-11-13 (through MCP, audited): relation 1067 (goggles_db `part_of` goggles_main) deleted; 232 and
    233 ("depends on", with a space) replaced by `depends_on` relations 1230 and 1231.
  - The scan already writes these links (`ProjectScanner::ProjectLinks`, 1.73.1: a Gemfile naming another root
    gives `depends_on`), but only when the two roots aren't related yet. The manual `part_of` counted as related.
- **Spaced legacy relation types.** About 60 relations from 2025 use spaced verbs ("part of" ×4, "is part of" ×2,
  "depends on" ×5, "has many" ×15, …). The hierarchy code only knows `part_of`, so a spaced "part of" parent
  doesn't count: it can make an entity look orphaned. This is a candidate for a later normalization pass (map
  through `GraphVocabulary`, queue what doesn't map), not in this PR.

## Verification

- One spec per gate, each seen failing first, built from synthetic real instances shaped like the production cases:
  - boilerplate cliques;
  - a distance-only merge pair;
  - a context-bonus-only orphan;
  - dated release notes of two projects;
  - two Project roots.
- A cap spec: one run over more than 100 candidates seeds 100, despite report pruning.
- `StillQualifies` dismisses an old-gate row and keeps a qualifying one.
- Full suite with the test DB truncated before and after; rubocop.
- On production after deploy: "Run policies now", then compare the counts per kind with the table above.
