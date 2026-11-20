# Plan: make MariaDB vector search use its index (plus zero-vector fixes)

> Status: **draft for Steve, 2026-11-20. Plan only: no code PR until Steve says go.** Written against
> `main` at `c546109` (merge of #188, Dream State R1a, **1.93.0**). Each kickoff rechecks its own line
> references against `main`.
>
> Motivation: an outside pitch to move graph_mem onto a separate graph/vector database. A code-side
> look showed that graph_mem already stores its vectors in MariaDB 11.8 with HNSW indexes. The
> cheaper win is to make the queries able to use those indexes, and to fix how unembedded rows are
> handled. A new backend isn't needed for that.

## Goal

1. Fix the zero-vector handling bugs first (step 0).
2. Measure before changing anything (step 1).
3. Let the **unfiltered** vector channels use the HNSW index, and keep exact scans wherever a filter
   would make the index path lose rows (step 2).
4. Bring `suggest_merges` and the other similarity checks off O(N) per entity and O(N²) loops (step 3).
5. Stop loading the 3 KB vector with every entity row (step 4).
6. Optionally, add FULLTEXT as an extra text signal next to `LIKE` (step 5).

Out of scope: new gems, a second database or backend, a new embedding model, MCP params or outputs.
Each step keeps the tool budget unchanged.

## Current state (main at c546109, 1.93.0)

**Storage.** `memory_entities.embedding` and `memory_observations.embedding` are
`vector(768) NOT NULL DEFAULT <zero vector>` (`db/structure.sql:219, 259`), with
`VECTOR KEY ... DISTANCE='cosine'` (`structure.sql:231, 292`; default `M=6`). `BEFORE INSERT`
triggers write a zero vector when the value is NULL (`structure.sql:244, 307`;
`app/services/embedding_vector_trigger_manager.rb`). `embedded_at` marks a real vector
(`with_embedding` scope, `app/models/memory_entity.rb:49`, `app/models/memory_observation.rb:48`).
The NOT NULL columns, triggers and index are installed by `rake embeddings:add_indexes`
(`lib/tasks/embeddings.rake:45`, `app/services/embedding_index_manager.rb`). Installs without
the index keep nullable columns.

**Producer.** `EmbeddingService` calls Ollama or an OpenAI-compatible API
(`app/services/embedding_service.rb`). The defaults are `nomic-embed-text`, 768 dims
(`app/services/embedding_config.rb:5-10`). The vector is written by a compare-and-set raw
`UPDATE` (`embedding_service.rb:357-364`).

**Hybrid search.** `HybridSearchStrategy` fuses the channels with weighted RRF, `RRF_K = 60`
(`app/strategies/hybrid_search_strategy.rb:8, 132-179`). The channels are text (64), entity vectors
(67), observation vectors grouped per entity (73) and temporal (90-97), each at `limit * 2`.

**No vector query can use the index today.** MariaDB uses a `VECTOR KEY` only for
`ORDER BY VEC_DISTANCE_*(col, <constant vector>)` (or its alias) `ASC ... LIMIT n`. EXPLAIN on
MariaDB 11.8.6 shows the index is skipped when the query has a `HAVING` on the distance, uses a
scalar subquery as the vector, wraps the distance in an expression (`d + 0`), aggregates
(`MIN(...)` with `GROUP BY`), or has a selective `WHERE` that the optimizer serves from a B-tree
index instead:

| Site | Shape | Index usable? |
|---|---|---|
| `app/strategies/vector_search_strategy.rb:33-45` (entity search) | literal vector, `HAVING < 0.85`, `ORDER BY (vec_distance + 0)` | no (wrapped on purpose) |
| `vector_search_strategy.rb:64-84` (observation search) | `MIN(VEC_DISTANCE_COSINE)` + `GROUP BY` | no |
| `app/services/import_observation_duplicate_detector.rb:88-104` | `(vec_distance + 0)` on purpose (comment at 92-99) | no, correct as is |
| `app/tools/suggest_merges_tool.rb:41-61` | subquery vector, `HAVING`, one query per entity | no |
| `app/controllers/api/v1/maintenance_controller.rb:12-30` (REST copy) | the same | no |
| `app/services/entity_merge_evidence.rb:30-39` | literal, `HAVING`, `LIMIT limit*3` | no |
| `app/services/contradiction_detector.rb:286-302` | subquery, `HAVING`, per anchor | no |
| `app/services/fact_supersede/candidates.rb:152-158` | subquery, `HAVING`, `ORDER BY vec_distance, id` | no |
| `app/services/summarizer_service.rb:221-235` | subquery, `HAVING`, no `ORDER BY` | no (not a kNN) |
| `app/services/observation_relevance_ranker.rb:51-66` | `WHERE id IN (...)` | no (not a kNN; fine) |
| `entity_merge_evidence.rb:139`, `app/services/review_policies/auto_apply_contradiction.rb:123` | pairwise distance | not a kNN (fine) |

`docs/plans/done/ui-3-plan.md:117-121` and `docs/architecture.md:121` rely on the search queries
being exact scans, since a `WHERE` there loses no recall. Step 2 keeps that guarantee for filtered
searches.

**Synthetic measurements** (MariaDB 11.8.6, 20,000 synthetic 768-d rows in 50 clusters, 5% zero
placeholders, default `mhnsw_default_m=6`, `mhnsw_ef_search=20`, `mhnsw_max_cache_size=16 MB`; one
machine; *synthetic, not live data*):

- Exact scan in the current search shape: about 40 ms per query. Estimated to grow linearly, to about
  200 ms at 100k rows and about 2 s at 1M.
- Index (ANN) top-20: about 1 ms.
- ANN recall@20 against exact, over four probes: 20, 17, 15 and 7 out of 20. The misses were near-ties
  (the top-60 distances spanned 0.246 to 0.270 on a tie-heavy set).
- **Hazard:** with the index forced and a selective filter (`WHERE entity_type = <one of 10 types>`),
  the ANN query returned **0 rows** where the exact query returned 5. The index returns its nearest
  rows *before* the `WHERE`, and the `LIMIT` caps them. This is the problem
  `import_observation_duplicate_detector.rb:92-99` describes.
- `suggest_merges` runs one scan per entity. At 20k synthetic entities over 10 types that's about
  20k × 10-15 ms, or **about 4-5 minutes** for one call (estimate from the bench).

**Text channel.** `EntitySearchStrategy` splits the query on whitespace
(`app/strategies/entity_search_strategy.rb:84-90`) and builds `LOWER(field) LIKE '%token%'` ORed
over `name`, `entity_type` and `aliases` (97-106). That's a full scan, and every candidate is loaded
and scored in Ruby (`FIELD_WEIGHTS`, 30-34) before `.first(limit)` (73-77).
`index_memory_entities_fulltext (name, aliases)` exists (`structure.sql:230`; migration
`20260227122154`), but nothing queries it: there are 0 `MATCH ... AGAINST` sites.

**Vectors loaded with every row.** `MemoryEntity` has no `ignored_columns`, so every load carries
the 3 KB vector (768 × 4 bytes). That includes the unbounded `LIKE` candidate set and
`suggest_merges`' `scope.to_a` (`suggest_merges_tool.rb:44`). The readers that actually need the
vector are `app/strategies/dream_state_compactor.rb:228-236` and `entity_merge_evidence.rb:145-152`
(`unpack("e*")`).

## Step 0 (first). Zero-vector placeholders read as "distance 0" (spec first, then fix)

**Code path (confirmed on main).** On an install with the index, an unembedded row holds the zero
vector, not NULL. The `embedding.present?` / `embedding.blank?` guards test the column, so they pass
for those rows:

- `summarizer_service.rb:222` (`contradiction_partner_ids`): the anchor comes from
  `entity.active_memory_observations` (`build_evidence`, 179-180) with no `with_embedding` filter.
- `observation_relevance_ranker.rb:53, 67` (`batch_vector_similarity`).
- `contradiction_detector.rb:287`, `maintenance_controller.rb:21`, `entity_merge_evidence.rb:24, 145`,
  `dream_state_compactor.rb:229`. These callers also filter `with_embedding`, so they're probably
  safe. The step 0 specs confirm it.

**What MariaDB 11.8.6 does with a zero vector** (checked on a scratch DB):
`VEC_DISTANCE_COSINE(<zero>, <any>)` is **NaN**. The text protocol prints it as `0`, it is not
`= 0` and not `< 0.35`, and any arithmetic on it (`d + 0`) raises
**`ERROR 1690 (22003) DOUBLE value is out of range`**. So:

1. **Summarizer contradiction marks (`summarizer_service.rb:221-235`).** As written, the query does
   **not** raise 1690: the `HAVING vec_distance < 0.35` is false for NaN. Instead, an unembedded
   observation silently never gets `[possible contradiction]`. 1690 would appear as soon as the
   query gained an arithmetic `ORDER BY` (the `+ 0` pattern used elsewhere).
2. **Ranking (`observation_relevance_ranker.rb:51-71`).** Unembedded ids are passed to
   `WHERE id IN (...)`. The NaN arrives in Ruby as `0` (inferred from the text protocol; the spec
   confirms it), so `1.0 - distance` gives a **vector score of 1.0, the maximum**. Unembedded
   observations are then pushed *up* in `summarize`, `rank_observations`, and the observation
   ordering of `get_entities` and `traverse_graph` (through `ObservationRankingService`).
3. Any exact scan whose query vector is a zero vector raises 1690 (`(vec_distance + 0)` shapes).
   Today the query vectors come from the embedding service, and rows are filtered by
   `with_embedding`, so that's a guard to keep, not a live bug.

**Specs first** (real MariaDB, synthetic rows, `OLLAMA_URL` pointed at a closed port, the index and
triggers installed by the spec's setup):

- a summarizer spec: one embedded and one unembedded observation on the same entity, with polarity
  conflict text. Expect: no exception, and the unembedded one isn't compared (documents the fixed
  behaviour);
- a ranker spec: an unembedded observation gets `nil` vector similarity, not 1.0;
- for each other guard listed above, a spec that an unembedded anchor is skipped;
- a SQL-level spec that pins the NaN behaviour (`d < x` is false, `d + 0` raises), so a future
  MariaDB that changes it shows up.

**Fix:** replace those guards with `embedded_at.present?` and add `.with_embedding` where ids are
gathered for the ranker. Small change, no migration. It changes the observation order that
`summarize`, `rank_observations`, `get_entities` and `traverse_graph` return, but only in that
unembedded rows stop getting a false top score. **Steve to confirm** this counts as a bug fix
(no MCP params or outputs change).

## Step 1. Synthetic benchmark plus EXPLAIN and recall specs

- `lib/tasks/vector_bench.rake` (or `script/vector_bench.rb`): seeds N synthetic entities and
  observations into a **scratch database** created by the task. It never touches the dev or
  production database. The data is 768-d clustered vectors with 5% zero placeholders, generic names
  (`SynthEntity123`) and 10 synthetic types. The task prints p50/p95 per channel (exact and ANN) and
  recall@k against exact, as Markdown for a PR body. It's opt-in, run by hand, and not part of CI.
- Specs (CI, small N of about 2,000 rows so the suite stays fast):
  - **EXPLAIN-shape specs**: for each query in the table above, assert whether
    `key = idx_*_embedding` is expected. Today none should use it; steps 2 and 3 flip the ones they
    change.
  - **recall spec**: ANN against exact recall@10 on the clustered fixture ≥ an agreed threshold
    (proposal: ≥ 0.8 average, no single probe below 0.5; see Q4).
  - **filter-hazard spec**: documents that ANN with a selective `WHERE` can return fewer rows than
    exact. This is the reason filtered searches stay exact.
- Gate the EXPLAIN specs on `MariaDB >= 11.8` and keep CI pinned to `cimg/mariadb:11.8.6`. Optimizer
  output can change between minors.

## Step 2. Index-friendly vector search for unfiltered queries; exact scans stay for filtered ones

- `VectorSearchStrategy#search`: when the index is active and the call has **no** `SearchFilter`
  scope and **no** `entity_type`, run an inner
  `SELECT id, VEC_DISTANCE_COSINE(embedding, VEC_FromText(?)) AS d ... ORDER BY d LIMIT K`. Apply the
  `embedded_at IS NOT NULL` filter, the `d < 0.85` threshold and the final `LIMIT` in an **outer**
  query. K = `limit × 4`, at least 100, plus the count of unembedded rows (cheap through
  `idx_*_embedded_at`), capped at 1,000. Unembedded placeholders are NaN and the threshold drops them,
  but they can still use up K.
- `#search_observations`: an inner ANN over observations (K as above), then the outer
  `GROUP BY memory_entity_id` with `MIN(d)` and the `perspective` filter applied outside. When
  `perspective` or a scope is set, stay exact.
- **Fallback**: if the index is missing (`EmbeddingIndexStatus`), or any filter is present, keep
  today's exact query unchanged. That keeps the "WHERE loses no recall" guarantee from
  `architecture.md:121`.
- Optional switch: `AppSettings` `vector_search_mode` = `exact | ann` (default `exact` until Steve
  flips it). AppSettings is rails-settings-cached, so this needs no migration. The settings page gains
  one field.
- Docs: `docs/operator/embeddings.md` explains `mhnsw_max_cache_size`. The 16 MB default holds
  roughly 5-10k 768-d nodes (estimate). Raise it before switching to `ann` on a larger graph.
- **Changes result order** (ANN is approximate). **Needs Steve's approval** before `ann` becomes the
  default. No MCP params or outputs change.

## Step 3. `suggest_merges` and the other similarity checks

- `suggest_merges` (MCP tool) and `GET /api/v1/maintenance/suggest_merges`: stop `scope.to_a` over
  every embedded entity. Iterate in id batches without loading the vector. For each entity, run an
  inner ANN query (literal vector, `ORDER BY d LIMIT K`), then apply the type filter, `id > ?`,
  `embedded_at` and the threshold outside. Same-type filtering stays in the outer query, so K must be
  generous; the step 1 recall spec covers it. Add a wall-clock budget, with a `truncated` note in the
  existing output text only if Steve approves (see Q6). Otherwise stop at `limit` as today.
- `EntityMergeEvidence.candidates_for`, `ContradictionDetector#find_contradiction_pairs`,
  `FactSupersede::Candidates`, `SummarizerService#contradiction_partner_ids`: replace the
  scalar-subquery vector with the loaded literal (it removes one subquery per row) and move `HAVING`
  to an outer query. These are scoped to one entity, a subtree or an id list, so **they stay exact**.
  That's a cost cleanup with no recall change.
- One shared helper (`VectorQuery.nearest(relation, vector, k:, exact:)`) builds both shapes, so the
  rule "filtered → exact, unfiltered → inner ANN" lives in one place.
- **Changes MCP tool behaviour** (`suggest_merges`: different candidates when ANN misses near-ties).
  **Needs Steve's approval.** The params, outputs and tool count stay unchanged.

## Step 4. Stop loading the 3 KB vector with every entity row

- `MemoryEntity` and `MemoryObservation`: exclude `embedding` from default selects. Either
  `self.ignored_columns += ["embedding"]` with an explicit `pluck`/`select` where it's read, or a
  default scope through `select(column_names - ["embedding"])`. The step 4 kickoff picks one after
  checking that `ignored_columns` doesn't break the raw `UPDATE` writers.
- Explicit readers: `app/strategies/dream_state_compactor.rb:228-236`, `entity_merge_evidence.rb:145-152`, the
  `embedding_service.rb` binary helpers (126-136), the merge snapshot (`entity_merge_snapshot.rb:10`,
  `embedding_hex`) and the step 0 guards (these switch to `embedded_at`).
- `as_json` already leaves the vector out (`memory_entity.rb:53-56`), so no output changes. This is a
  pure performance change and needs no approval beyond the plan.

## Step 5 (optional). FULLTEXT as an extra text signal alongside `LIKE`

Checked on MariaDB 11.8.6 with `utf8mb4_general_ci` and InnoDB defaults:

- `innodb_ft_min_token_size = 3`: tokens of 1-2 characters (`ui`, `gm`) are never indexed.
- `_` is a word character: `graph_mem` is one token, so `graph` doesn't find it (a boolean
  `graph*` does).
- CamelCase isn't split: `Sweep` doesn't find `RelationTypeSweep`, while `LIKE '%sweep%'` does.
- Hyphens split tokens. Matching ignores case and accents (`citta` finds `Città`).
- The default stopword list applies. Changing the token size or stopwords means rebuilding the
  index (server settings). FT changes become visible at commit. Deleted rows linger in the FT index
  until `OPTIMIZE TABLE`.

So FULLTEXT **can't replace** `LIKE` for graph_mem's identifier-style names. The proposal is a
boolean-mode prefix match (`MATCH(name, aliases) AGAINST('tok*' IN BOOLEAN MODE)` for tokens of 3 or
more characters). It would be used either as a fifth RRF channel with a low weight, or to bound the
`LIKE` candidate set on large graphs, in both cases fused with `LIKE` rather than replacing it. The
existing index is reused, so there's no migration. A FULLTEXT index on
`memory_observations.content`, where FT fits prose better, **would need a migration and Steve's
approval** (not in this plan).

The quality gain isn't proven. Ship it only with a before/after on a fixed synthetic query set.
**Changes result order**, so it **needs Steve's approval.**

## Releases (proposal for Steve)

The train as it reads on `main` (`docs/plans/dream-state-semantics-plan.md`, "Order and size";
`docs/plans/sql-exchange-plan.md:342`; `docs/plans/mcp-sdk-1.11.0-plan.md:1-4`):

| Version | What |
|---|---|
| 1.93.0 | Dream State R1a (#188, shipped) |
| 1.93.1 | mcp 1.11.0 bump |
| 1.94.0 | SQL exchange (four PRs) |
| 1.95.0 (+1.95.1) | Dream State R1b (+ R1c) |
| 1.96.0 | Dream State R2 |
| unnumbered | Dream State R3, R4 (each behind a measurement) |

Proposal:

- **Step 0 as an independent patch**, as soon as Steve wants it: the next free patch on whichever
  minor is current (for example **1.93.2** after the mcp bump, or a `.x` patch on 1.94.0). It's a bug
  fix with no migration and no new surface.
- **Step 1** ships with step 0 or as its own patch. It's only specs and an opt-in rake task, so there's
  no runtime change.
- **Steps 2-4 as one minor after R2: 1.97.0** (PRs below). They don't touch relations, membership or
  the export formats, so they could slot in **between trains** instead (for example after the SQL
  exchange and before R1b) if Steve prefers. The version would then be the next minor at that point,
  and the Dream State versions would move up by one.
- **Step 5**, if approved: its own minor after that (1.98.0), or folded into 1.97.0.
- Dream State R3 proposes "embedding-near entities of different types" as a discovery rule. It
  benefits from step 3's helper, so if R3 is scheduled, steps 2-3 should land first.

## PR breakdown

| PR | Scope | Size | Depends on | Approval needed |
|---|---|---|---|---|
| A | Step 0: specs, then guard fixes (summarizer, ranker, the other guards) | S, ~250-450 lines | none | Steve confirms it's a bug fix (result order changes for unembedded rows) |
| B | Step 1: bench rake task, EXPLAIN-shape, recall and filter-hazard specs | S/M, ~500-800 lines | A (or in parallel) | none (specs and opt-in tooling) |
| C | Step 2: inner-ANN search channels, exact fallback, optional `vector_search_mode` setting, operator docs | M, ~700-1,100 lines | B | **yes**: result order; default mode |
| D | Step 3: `VectorQuery` helper, `suggest_merges` batching plus ANN, subquery → literal in the scoped checks | M, ~800-1,300 lines | B, C (helper) | **yes**: `suggest_merges` behaviour |
| E | Step 4: stop loading vectors by default; explicit readers | S/M, ~300-600 lines | A | none (performance only) |
| F | Step 5 (optional): boolean-mode FULLTEXT channel and the before/after query set | S, ~250-450 lines | B | **yes**: result order |
| Release | Version, CHANGELOG, `sync_skill_version` (in the last PR of each release) | S | — | — |

Each PR stays under the ~3,000-line stop. Order: A → B → (C, E in either order) → D → F. **No new
gems. No migrations** in A-F. Removing the index machinery (see Q1) would be a separate PR with a
migration and needs Steve's approval.

## Test burden

- CI: keep the single rspec job on **`cimg/mariadb:11.8.6`**. No new matrix. EXPLAIN-shape specs are
  gated on `>= 11.8` and get rechecked whenever the image is bumped.
- Fixtures: synthetic only (`SynthEntity…` names, seeded random clustered vectors, 5% zero
  placeholders). The index and triggers are installed in the spec setup the way
  `embeddings:add_indexes` does it, and dropped afterwards so other specs see the usual schema.
- Recall thresholds: ANN against exact recall@10 ≥ 0.8 average, with no probe below 0.5, on the
  ~2,000-row CI fixture (proposal, Q4). `suggest_merges` keeps exact results on a fixture small
  enough to stay below K.
- Performance: the bench rake task is opt-in and never runs in CI (CircleCI medium is too noisy).
  Each of C, D and E pastes its numbers into the PR body at 10k, 50k and 200k synthetic rows.
- Expected suite growth: about 15-25 spec examples, mostly in services and strategies, plus a
  few seconds of index setup.

## Open questions for Steve

1. **Keep or drop the HNSW indexes?**
   - Keeping them costs index maintenance on every embed write (not measured yet; step 1 can
     measure it), the NOT NULL plus zero-vector trigger machinery (`embedding_vector_trigger_manager.rb`,
     `embedding_index_manager.rb`, `app/lib/structure_dump_guard.rb`, `embedded_at`) and the step 0
     class of bugs.
   - What it buys: the index path in steps 2-3.
   - Dropping them is an operator action today (`embeddings:drop_indexes`, no code change). Fully
     removing the machinery would be a PR with a migration and needs your approval.
   - Proposal: keep them, and decide after step 1's numbers at your expected graph size.
2. Step 0: may the ranking fix (unembedded observations stop getting a top vector score) ship as a
   bug-fix patch, even though it changes observation order in `summarize`, `rank_observations`,
   `get_entities` and `traverse_graph`?
3. Step 2: should ANN become the default for unfiltered searches, or stay behind
   `vector_search_mode = exact` until you flip it?
4. The recall bar: is recall@10 ≥ 0.8 average (no probe below 0.5) on the synthetic fixture
   acceptable for switching an unfiltered channel to ANN?
5. Releases: steps 2-4 as 1.97.0 after R2, or between the SQL exchange and R1b? Should step 0 ship
   as an early patch (for example 1.93.2)?
6. `suggest_merges`: may a long scan stop at a time budget? If it should say so, may it add a line to
   the existing text (no new output field)? Or must it stay "stop at `limit`" only?
7. Step 5: worth doing at all, given the 3-character minimum and the underscore and CamelCase
   tokenization? If yes, is a fixed synthetic query set enough evidence?
