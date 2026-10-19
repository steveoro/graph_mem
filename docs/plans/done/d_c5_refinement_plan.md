---
agent: devin-local
session: picayune-store
created: 2026-10-13T11:57:04Z
---
# v1.52.0 hardening + first-time Graphify import optimization

One implementation plan covering the agreed v1.52.0 read-path/maintenance fixes (D2 god-nodes, C5 citation check, r2 locking/perspective/cleanup, get_callers deprecation) plus a targeted first-time Graphify import performance review, all while preserving multi-pass idempotence and the existing safety architecture.

## 1. Version and changelog

- Bump `lib/graph_mem/version.rb` from `1.51.0` to `1.52.0`.
- Add a `CHANGELOG.md` entry for v1.52.0 grouping:
  - D2 god-node reporting in `get_graph_stats`.
  - C5 LLM citation validation for `summarize`.
  - r2 review-queue hardening (locking, edited-payload absorb, perspective pin, caused_by migration down, negation regex).
  - First-time import performance improvements.
  - `get_callers` → `traverse_graph` recipe note.

## 2. D2 — God-node reporting in `get_graph_stats`

- Modify `app/tools/get_graph_stats_tool.rb`:
  - Add `god_nodes` and `god_node_count` keys to `#call`.
  - Add a `#god_nodes` method that reuses the existing `most_connected` aggregation logic, filters for `degree > 100`, returns up to 10 entries shaped `{ id, name, entity_type, relation_count }`, and reports the total qualifying count.
  - Update the tool description to mention `god_nodes`.
- Keep `app/controllers/api/v1/maintenance_controller.rb` `#stats` in sync (same hash shape).
- Update `swagger/v1/swagger.yaml` under `/api/v1/maintenance/stats` to document `god_nodes` and `god_node_count`.
- Update `docs/mcp_tools.md` `get_graph_stats` description.
- Add tests in `spec/tools/get_graph_stats_tool_spec.rb` for threshold (e.g. a hub with 101 edges appears, 100 does not), cap at 10, and `god_node_count`.

## 3. C5 — Citation validation for LLM `summarize`

- Modify `app/services/summarizer_service.rb`:
  - In `#attempt_llm_synthesis`, after a successful `SummaryGenerationClient.generate` call, scan the generated `summary` text for `observation_id=N` / `[observation_id=N]` tokens.
  - Compute from the `evidence` list the set of valid `observation_id`s used as citations.
  - Build a `citation_check` block: `cited_ids`, `unknown_ids`, `uncited_evidence_ids`, `possible_hallucination: unknown_ids.any?`.
  - Merge `citation_check` into the response only when `generation_mode == "llm"`.
- Update `docs/summarization.md` to document `citation_check` and that deterministic summaries are self-citing by construction.
- Add tests in `spec/services/summarizer_service_spec.rb` (or `spec/tools/summarize_tool_spec.rb`):
  - LLM summary citing only valid IDs → no hallucination flag.
  - LLM summary citing an unknown ID → `possible_hallucination: true`.
  - Evidence present but not cited → `uncited_evidence_ids` populated.
  - Deterministic mode does not include `citation_check`.

## 4. r2 — Review-queue hardening (from Graphy round on `a3fd770`)

### 4.1 Apply-vs-scan locking
- Modify `app/services/compaction_review_service.rb`:
  - In `.apply(item_id, ...)`, lock the loaded row with `row.with_lock`, `row.reload`, and re-check `row.status.in?(%w[active ignored])` before calling `apply_action` and updating status/applied_at.
  - In `.absorb_stale_memory?`, lock all matching active `stale_memory` rows (or at least the `keep` row) inside the `seed_report` transaction, reload, and re-check `active?` before read-modify-write. Use ordered locking by `id` to avoid deadlocks.

### 4.2 Edited-payload absorb
- In `.absorb_stale_memory?`, when `keep.edited_payload` is present, merge the new `observation_ids` into `keep.edited_payload` rather than into `payload`, because `effective_payload = payload.merge(edited_payload)` means edits win. Recompute the signature from the final effective payload.

### 4.3 Subgraph SQL perspective pin
- Modify `app/services/subgraph_search_service.rb`:
  - In `#merge_vector_ids`, when `@perspective` is present, call `VectorSearchStrategy.new.search_observations(@effective_query, limit: @per_page * 2, perspective: @perspective)` instead of `VectorSearchStrategy.search` (which matches entity embeddings and ignores perspective).
  - The text branch already applies `perspective` to the observation `WHERE` clause; keep it, but add a regression spec to enforce end-to-end behavior.
- Add a test in `spec/services/subgraph_search_service_spec.rb` (or extend `spec/observation_perspective_spec.rb`) that an entity matching **only** via an `experience` observation must not appear in `perspective: "world"` results.

### 4.4 `caused_by` migration `down`
- Modify `db/migrate/20261013120000_seed_caused_by_relation_mappings.rb`:
  - Change `down` to `RelationTypeMapping.where(variant: ...).where(canonical_type: CANONICAL).delete_all` so operator remaps with a different canonical are not destroyed.
- Add a migration spec that `down` leaves non-`caused_by` canonical rows untouched.

### 4.5 StaleMemoryScanner negation and spec pins
- Modify `app/services/stale_memory_scanner.rb`:
  - Extend `NEGATED_MARKERS` to also catch forms like `not open anymore` without over-negating legitimate open markers such as `not fixed`. Document the conservative under-flagging choice.
- Add cheap spec pins in `spec/services/stale_memory_scanner_spec.rb`:
  - `valid_until` re-check direction (only still-elapsed obs are obsoleted).
  - `absorb_stale_memory?` retires duplicate rows into `ignored`.
  - `absorb_stale_memory?` respects suppression when the merged signature is suppressed.
  - Negated "not open anymore" content is not flagged.

## 5. `get_callers` deprecation / traversal recipe

- Update `docs/mcp_tools.md` in the `traverse_graph` section:
  - Add an explicit recipe: to list callers, use `traverse_graph` with `direction: "incoming"` and `relation_types: ["calls"]`.
  - State that no `get_callers` tool exists and it is permanently dropped.
- No code changes; no new tool.

## 6. Optional fold-in: `CompactionReviewService` split

- Create `app/services/compaction_review_applier.rb` and move the private `apply_action` dispatcher plus all `apply_*` helpers (`apply_stale_memory`, `merge_entities`, `create_relation`, `move_to_parent`, `apply_relation_integrity`, `move_observation`, `reparent_entity`, `delete_relation`, `delete_entity`, `dismiss_compaction_review`, `delete_observation`, `pick_id`) there.
- Keep `CompactionReviewService` responsible for queue listing, editing, seeding, suppression, and the `.apply` orchestration (lock + status update).
- Update any specs that reach into `CompactionReviewService` private helpers.
- Do this **after** the locking changes to avoid touching the same code twice.

## 7. First-time Graphify import performance optimization

### 7.1 Profile and measure
- Add a temporary (or retained, non-blocking) benchmark around `GraphifyImporter.translate` plus `ImportExecutionStrategy.execute` for `spec/fixtures/files/graphify_sample.json` and a larger synthetic graph.
- Use an `ActiveSupport::Notifications` SQL counter or `Bullet` / `ActiveRecord::QueryRecorder`-style helper to surface N+1 hot spots during first-time import.

### 7.2 Targeted candidate fixes
- `app/services/import_observation_duplicate_detector.rb`:
  - Cache per-entity active observation contents and embedding availability inside one `find_duplicate` call / one import execution to avoid repeated `where(...).find_by`/`exists?` round-trips for the same entity.
- `app/strategies/import_execution_strategy/entity_writes.rb`:
  - In `#import_observations`, accept the already-loaded `MemoryEntity` (or load it once) instead of `MemoryEntity.find(entity_id)` per call.
  - Use a preloaded `active_memory_observations` set for exact-content checks; only invoke the full duplicate detector when an exact match is not found and embeddings are available.
  - Batch counter-cache updates: collect entity ids whose observation count changed and use `MemoryEntity.update_counters` once after observation creation, instead of `update_column(:memory_observations_count, ...)` per entity.
- `app/strategies/import_matching_strategy.rb`:
  - For `will_add_observations` and `observation_exists?`, preload the matched entity's active observation contents once per node rather than calling the duplicate detector for each observation.
- `app/strategies/import_execution_strategy/relations.rb`:
  - Replace the three-column `IN` query in `#preload_existing_relations` with a composite `(from_entity_id, to_entity_id, relation_type) IN (...)` expression (sanitized via `sanitize_sql_array` or Arel) so MariaDB can use the existing unique index `index_memory_relations_uniqueness`.
  - Pre-bulk-load `project_id` and `entity_type` for all resolvable `from_id`/`to_id` pairs before the relation loop to remove the per-edge `MemoryEntity.where(id: [from_id, to_id]).pluck(...)` N+1.
- `app/services/graphify_importer.rb`:
  - Review repeated `@edges` scans in `#build_stats` and `#build_relations`; keep the importer DB-free but collapse redundant counts into a single pass if measurement shows it matters.

### 7.3 Safety constraints
- Keep all first-time/re-import idempotence guarantees: exact-match dedup, relation dedupe, deferred embedding backfill, transactional `execute` with rollback on errors.
- Do **not** re-enable inline embeddings or per-edge trust recompute during bulk import.
- Do not widen transaction boundaries; only optimize queries and batch auxiliary writes.

### 7.4 Regression tests
- Add `spec/integration/import_perf_spec.rb` (or extend `spec/integration/import_fixtures_spec.rb`):
  - First-time baseline import stays under a query-count/time budget compared to the pre-refactor baseline.
  - Re-import yields unchanged `MemoryEntity`/`MemoryObservation`/`MemoryRelation` counts (existing test preserved).
  - Paraphrased re-import still performs semantic deduplication when embeddings are backfilled.
- Run `spec/services/graphify_importer_spec.rb`, `spec/strategies/import_execution_strategy_spec.rb`, and `spec/services/import_observation_duplicate_detector_spec.rb` after each change.

## 8. Verification commands

- Run the focused suites through the project RVM gemset:
  ```bash
  source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem
  bundle exec rspec spec/services/graphify_importer_spec.rb
  bundle exec rspec spec/integration/import_fixtures_spec.rb
  bundle exec rspec spec/strategies/import_execution_strategy_spec.rb
  bundle exec rspec spec/services/import_observation_duplicate_detector_spec.rb
  bundle exec rspec spec/tools/get_graph_stats_tool_spec.rb
  bundle exec rspec spec/services/summarizer_service_spec.rb
  bundle exec rspec spec/services/subgraph_search_service_spec.rb
  bundle exec rspec spec/services/stale_memory_scanner_spec.rb
  bundle exec rubocop
  ```
- If the full suite is green, commit with a v1.52.0 changelog-style message.

## 9. Risks and considerations

- `CompactionReviewService` locking and splitting should be sequenced: lock first, extract second, to avoid double refactoring of the same methods.
- Row-level locking in `.apply` can serialize concurrent applies; surface `ProjectMembership::LockTimeout`-style failure messages cleanly.
- Composite `(a,b,c) IN (...)` SQL is supported by MariaDB 11.8+; verify sanitization and parameter count limits for very large payloads.
- Counter-cache batching must remain inside the same `execute` transaction so a rollback leaves counts consistent.
- Changing `SubgraphSearchService` vector merging to `search_observations` under `perspective` may exclude name-only semantic matches; document that `perspective` filters observations, not just entity names.
- Import optimizations should not change the public `ImportExecutionStrategy::ImportReport` shape or the `GraphifyImporter.translate` output.
