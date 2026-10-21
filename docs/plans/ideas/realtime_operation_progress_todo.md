# Real-Time Operation Progress TODO

This checklist tracks the implementation across separate runs; keep completed items checked and record failures/blockers beside the relevant item.

## Run 1 — persistence and transport

- [x] Add `OperationProgress` persistence with immutable operation ID, baseline total, counters, lifecycle state, and error fields.
- [x] Add compaction-run association and operation ID to compaction status snapshots.
- [x] Add shared ActionCable broadcaster and `OperationProgressChannel`.
- [x] Add Stimulus subscriber that updates every matching operation target on the page.
- [x] Apply the two operation-progress migrations in the current test database; repeat for development/staging/production deployment databases.
- [x] Confirm production Solid Cable delivery for job-originated broadcasts.

## Run 2 — operation instrumentation

- [x] Instrument export while preserving the existing export channel contract.
- [x] Instrument synchronous import execution with a flattened import-node baseline.
- [x] Instrument garbage collection phases with precomputed diagnostic totals.
- [x] Instrument compaction entity batches and phase lifecycle events.
- [ ] Refine compaction phase totals if relationship discovery uses a traversal set different from the initial entity count.
- [ ] Pass operation IDs through import review/execution navigation if progress must be visible before the final report page.

## Run 3 — UI and compatibility

- [x] Add live progress targets to the compactor, garbage collector, and import report cards.
- [ ] Add a reusable styled partial/component instead of duplicated HAML markup if the visual design is finalized.
- [ ] Add live export progress target to the maintenance page and wire the async response operation ID into it.
- [ ] Add reconnect/fallback snapshot endpoint if Turbo navigation exposes stale operation markup.
- [ ] Add authorization and validation rules for operation IDs if channels become externally reachable.

## Run 4 — verification and cleanup

- [x] Add model specs for monotonic current/total values, completion, and snapshot serialization; add pause/failure coverage in the next verification pass.
- [ ] Add tracker/strategy specs proving deletion does not reduce a captured denominator.
- [x] Add channel/broadcaster specs for operation-ID stream names and initial snapshots.
- [ ] Update existing export specs to assert persisted operation lifecycle in addition to legacy broadcasts.
- [x] Run focused Rails specs, request specs, RuboCop, syntax checks, and `git diff --check`; full-suite verification remains for the next run.
- [ ] Decide retention policy and add cleanup for old completed operation rows.
- [ ] Update user-facing documentation with operation stream and progress counter semantics.

## Run 5 — SolidCable production troubleshooting

- [x] Diagnose real-time updates not working in a local production container (page refresh shows correct counts, but no live UI updates).
- [x] Fix missing `ActionCable.server` mount in `config/routes.rb` (WebSocket endpoint `/cable` was not exposed).
- [x] Verify `db:prepare` + `db:support:initialize` correctly create the `solid_cable_messages` table in `storage/production_cable.sqlite3`.
- [x] Rebuild the production Docker image and restart the container to pick up the route change.
- [x] Verify live updates by starting a compaction/export/import and watching the dashboard progress target update without refreshes.
- [x] If running the container on plain HTTP (`http://localhost:3030`), set `-e RAILS_FORCE_SSL=false` so the WebSocket handshake is not redirected to HTTPS.
