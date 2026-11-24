# Plan: make MariaDB vector search use its index (plus zero-vector fixes)

> Status: **plan, decisions taken by Steve on 2026-11-20 and 2026-11-24 (see the two "Decisions"
> sections). Still plan only: no code PR until Steve says go.** Written against `main` at `c546109`
> (merge of #188, Dream State R1a, **1.93.0**). Each kickoff rechecks its own line references
> against `main`.
>
> **Release renumbered (2026-11-24):** the `part_of` membership PRs took 1.93.1 and 1.93.2, so the
> mcp 1.11.0 bump is now 1.93.3 and this plan's step 0 + 1 release is **1.93.4** (it was 1.93.2).
> 1.97.0 is unchanged.
>
> Motivation: an outside pitch to move graph_mem onto a separate graph/vector database. A code-side
> look showed that graph_mem already stores its vectors in MariaDB 11.8 with HNSW indexes. The
> cheaper win is to make the queries able to use those indexes, and to fix how unembedded rows are
> handled. A new backend isn't needed for that.
>
> **Scope note.** At the current reference graph size (hundreds of entities, a few thousand
> observations, full embedding coverage) vector search speed is **not a bottleneck today**. The
> real bottleneck is LLM summarization on a CPU-only Ollama host, which this plan does not address.
> This plan fixes correctness now (step 0) and prepares the index path for when the graph grows.

## Goal

1. Fix the zero-vector handling bugs first (step 0).
2. Measure before changing anything (step 1).
3. Let the **unfiltered** vector channels use the HNSW index, and keep exact scans wherever a filter
   would make the index path lose rows (step 2).
4. Bring `suggest_merges` and the other similarity checks off O(N) per entity and O(N²) loops (step 3).
5. Stop loading the 3 KB vector with every entity row (step 4).
6. *(Deferred.)* FULLTEXT as an extra text signal next to `LIKE` (step 5).

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
unembedded rows stop getting a false top score. **Decided: ships as a bug fix, 1.93.4** (Decision 2;
no MCP params or outputs change).

## Step 1. Synthetic benchmark plus EXPLAIN and recall specs

- `lib/tasks/vector_bench.rake` (or `script/vector_bench.rb`): seeds N synthetic entities and
  observations into a **scratch database** created by the task. It never touches the dev or
  production database. The data is 768-d clustered vectors with 5% zero placeholders, generic names
  (`SynthEntity123`) and 10 synthetic types. The task prints p50/p95 per channel (exact and ANN) and
  recall@k against exact, as Markdown for a PR body. It also measures **write cost**: insert and
  embed throughput (rows/s, p95 per write) with and without the `VECTOR KEY`s, the numbers Decision 1
  waits for. It's opt-in, run by hand, and not part of CI.
- Specs (CI, small N of about 2,000 rows so the suite stays fast):
  - **EXPLAIN-shape specs**: for each query in the table above, assert whether
    `key = idx_*_embedding` is expected. Today none should use it; steps 2 and 3 flip the ones they
    change.
  - **recall spec**: ANN against exact recall@10 on the clustered fixture ≥ an agreed threshold
    (Decision 4: ≥ 0.8 average, no single probe below 0.5, as a starting bar).
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
- **Setting (Decision 3, Decisions N2-N3):** `AppSettings` `vector_search_mode` = `exact | ann`,
  **default `exact`**. It's an app setting, not an MCP param. The `ann` path runs only when the
  operator sets `ann`, and the plan expects that only once the graph grows. **It governs the search
  channels only** (this step). `suggest_merges` has its own switch, `suggest_merges_mode` (step 3),
  and the scoped checks stay exact in either mode. AppSettings is rails-settings-cached, so this needs
  no migration. The Settings page gains one field with an info tooltip (see "Settings page fields
  and tooltips" below), documented in `docs/app_settings_reference.md`.
- **Recall gate:** the step 1 recall spec runs the search `ann` path and must clear the Decision 4 bar
  (≥ 0.8 average recall@10, no probe below 0.5). If the first K and the index settings don't clear
  it, step 2 tunes K, the `mhnsw_ef_search` session value or the index `M` until they do. Changing
  `M` means rebuilding the index through `embeddings:add_indexes`, with no migration. Step 2 doesn't
  merge below the bar.
- Docs: `docs/operator/embeddings.md` explains `mhnsw_max_cache_size`. The 16 MB default holds
  roughly 5-10k 768-d nodes (estimate). Raise it before switching to `ann` on a larger graph.
- With the default `exact`, result order doesn't change. With `ann` it can, because ANN is
  approximate; that's the operator's choice (Decision 3). No MCP params or outputs change.

## Step 3. `suggest_merges` and the other similarity checks

- `suggest_merges` (MCP tool) and `GET /api/v1/maintenance/suggest_merges`: stop `scope.to_a` over
  every embedded entity. Iterate in id batches without loading the vector. For each entity, run an
  inner ANN query (literal vector, `ORDER BY d LIMIT K`), then apply the type filter, `id > ?`,
  `embedded_at` and the threshold outside. Same-type filtering stays in the outer query, so K must be
  generous. The ANN query is used only when **`suggest_merges_mode`** is `ann` (Decision N2: its own
  switch, separate from `vector_search_mode`); with `exact` (the default) the batching applies and
  each per-entity query stays exact, with the same candidates as today.
- **Setting `suggest_merges_mode` (Decision N2):** `AppSettings` field, `exact | ann`, **default
  `exact`**, not an MCP param, no migration. It governs only `suggest_merges`' per-entity inner query,
  for the MCP tool and the REST copy alike. `vector_search_mode` doesn't affect it, and it doesn't
  affect search.
- **Recall gate for the merge `ann` path (Decision N2):** the step 1 recall spec gains a
  `suggest_merges` probe set: in `ann` mode, the candidate pairs found per probe entity against exact
  must clear the same Decision 4 bar (≥ 0.8 average, no probe below 0.5). If they don't, step 3 raises
  K (the step 2 tuning of `mhnsw_ef_search` and `M` applies too). Step 3 doesn't merge below the bar.
- **Time budget (Decision 6, Decision N1):** the scan stops when a wall-clock budget runs out. The
  budget is the `AppSettings` field **`suggest_merges_time_budget_seconds`** (integer, **default 30**,
  validated as a positive integer through `validates: { numericality: { greater_than: 0,
  less_than_or_equal_to: 600 } }`; the 600 s cap is a proposal so a typo can't make one call run for
  hours, and it gives the Settings page its "Accepted range: 1–600" line). No migration
  (rails-settings-cached). It applies to the MCP tool and `GET /api/v1/maintenance/suggest_merges`
  alike, read once at the start of each call. When the budget runs out, the scan says so with **one
  line in its existing text output** (for example "Scan stopped after the time budget: N of M
  entities checked."), with **no new field**. It still stops at `limit` as today.
- `EntityMergeEvidence.candidates_for`, `ContradictionDetector#find_contradiction_pairs`,
  `FactSupersede::Candidates`, `SummarizerService#contradiction_partner_ids`: replace the
  scalar-subquery vector with the loaded literal (it removes one subquery per row) and move `HAVING`
  to an outer query. These are scoped to one entity, a subtree or an id list, so **they stay exact**.
  That's a cost cleanup with no recall change.
- One shared helper (`VectorQuery.nearest(relation, vector, k:, exact:)`) builds both shapes, so the
  rule "filtered → exact, unfiltered → inner ANN" lives in one place. **The helper reads no setting**:
  each caller passes `exact:` from its own switch (`vector_search_mode` for the search channels,
  `suggest_merges_mode` for `suggest_merges`, always `true` for the scoped checks above).
- **MCP tool behaviour** (approved, Decision 6): `suggest_merges` can stop early on the budget, with
  the text line above. In `ann` mode (`suggest_merges_mode`) it can also return different candidates
  when ANN misses near-ties. The params, output fields and tool count stay unchanged.

## Settings page fields and tooltips (steps 2 and 3; Decision N3)

Steve's requirement: each of the three new settings gets an **info tooltip** that says plainly what it
controls and which feature it affects, so `vector_search_mode` and `suggest_merges_mode` can't be
confused.

**How the Settings page renders help today** (checked on `main`): every field comes from
`SettingsSchema` (`app/services/settings_schema.rb`) and renders through
`app/views/system/settings/_field.html.haml`: a label (`system.settings.fields.<key>.label`), the
input, and an **always-visible hint paragraph** `%p.system-hint{ id: "setting_<key>_help" }` with the
text of `system.settings.fields.<key>.description` (the input points at it with
`aria-describedby`; `SettingsFieldsHelper#settings_field_input`), then the accepted range for numeric
fields. Locale file: `config/locales/system_settings.en.yml`. **There is no tooltip or info-icon
component on the Settings page today** (the only tooltip in the app is the Explore graph's node
tooltip, `app/javascript/graph/tooltip.js`, which doesn't fit a form).

**So:** keep the existing pattern (label + short `.description` hint) and add a small accessible info
tooltip, rendered by `_field` only when the optional key `system.settings.fields.<key>.tooltip`
exists (so no other field changes):

- an info button right after the label: `%button.system-info{ type: "button", aria: { label:
  t("system.settings.info_button", label: t(field.label)), describedby: "setting_<key>_tip",
  expanded: "false" } }` showing an "i" glyph. It's a
  real `<button>`, so it's keyboard focusable, and it never submits the form;
- the tip: `%span.system-info__tip{ id: "setting_<key>_tip", role: "tooltip", hidden: true }` with the
  `.tooltip` text;
- shown on hover and on keyboard focus, toggled on click/tap (touch), hidden with **Escape** and on
  blur. CSS in `app/assets/tailwind/system.css` (`.system-info`, `.system-info__tip`, using the
  existing `--color-ui-*` tokens) plus a tiny Stimulus controller (`settings_tip_controller.js`,
  about 20 lines, no new package) for Escape, the click toggle and `aria-expanded`;
- the text stays in the DOM (`hidden` toggled), so screen readers read it through
  `aria-describedby`; the always-visible `.description` hint stays as today.
- spec: a request/view spec that the three fields render the button and the tip with the
  `aria-describedby` link, and that a field without a `.tooltip` key renders no button.

**Where:** the three fields go in the **Embeddings** tab (`define_group(:embeddings, ...)`), after the
embedding fields, in this order: `vector_search_mode`, `suggest_merges_mode`,
`suggest_merges_time_budget_seconds`. The two modes use `input: :select, choices: %w[exact ann]` and a
validator `:vector_lookup_mode` in `SettingsSchema::Validators` that accepts `exact` and `ann` and
stores the blank option ("— use ENV / default —") as `exact`. Readers treat any value other than `ann`
as `exact`. The budget is a plain integer field (its range comes from the `validates` above). The
labels name the feature first, so the two modes differ at a glance.

**Drafted `en` locale keys** (`config/locales/system_settings.en.yml`):

```yaml
en:
  system:
    settings:
      info_button: "About: %{label}"   # the info button's aria-label
      fields:
        vector_search_mode:
          label: "Search: vector lookup mode"
          description: "Search only. exact (default) or ann; see the info icon."
          tooltip: "How semantic search finds similar memories. exact checks every vector: slower on big graphs, never misses. ann uses the HNSW index: much faster, may rarely miss a close match. Affects search only, not merge suggestions. Searches with a filter always stay exact."
        suggest_merges_mode:
          label: "Merge suggestions: vector lookup mode"
          description: "Merge suggestions only. exact (default) or ann; see the info icon."
          tooltip: "How merge suggestions (suggest_merges) find entities that look like duplicates. exact compares each entity with every other one: slower on big graphs, never misses a pair. ann uses the HNSW index: much faster, may rarely miss a close pair. Affects merge suggestions only, not search. The time budget below still applies."
        suggest_merges_time_budget_seconds:
          label: "Merge suggestions: time budget (seconds)"
          description: "Merge suggestions only. Default 30."
          tooltip: "The most seconds one merge suggestions run (suggest_merges, from MCP or the REST API) may take. When time runs out it stops and its text says how many entities it checked. To check more, raise this or switch merge suggestions to ann. Affects merge suggestions only, not search."
```

**Docs:** `docs/app_settings_reference.md`, Embeddings section, gains the three rows (setting,
default, range, effect) with the same plain wording, and says which switch affects which feature.

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

## Step 5 (deferred). FULLTEXT as an extra text signal alongside `LIKE`

**Deferred by Decision 7: not scheduled, no PR.** It's kept here for a later decision.

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

The quality gain isn't proven. If it's ever picked up, it ships only with a before/after on a fixed
synthetic query set, and it changes result order, so it needs Steve's approval then.

## Releases (Decision 5)

The train as it reads on `main` (`docs/plans/dream-state-semantics-plan.md`, "Order and size";
`docs/plans/sql-exchange-plan.md:342`; `docs/plans/mcp-sdk-1.11.0-plan.md:1-4`), with this plan's
releases placed:

| Version | What |
|---|---|
| 1.93.0 | Dream State R1a (#188, shipped) |
| 1.93.1 | `part_of` membership, PR 1 (`docs/plans/done/part-of-membership-plan.md`, shipped) |
| 1.93.2 | `part_of` membership, PR 2 (scans, rake tasks, dream state, integrity sweep; `docs/plans/done/part-of-membership-plan.md`, shipped) |
| 1.93.3 | mcp 1.11.0 bump |
| **1.93.4** | **This plan: step 0 (zero-vector bug fix) + step 1 (benchmark and specs)**, PRs A and B |
| 1.94.0 | SQL exchange (four PRs) |
| 1.95.0 (+1.95.1) | Dream State R1b (+ R1c) |
| 1.96.0 | Dream State R2 |
| **1.97.0** | **This plan: steps 2-4** (`vector_search_mode`, `suggest_merges_mode`, `suggest_merges` time budget setting, no vector on default loads), PRs C, E, D |
| unnumbered | Dream State R3, R4 (after 1.97.0) |

- **1.93.4 right after the mcp 1.93.3 bump.** It's a bug fix with no migration and no new surface.
- **Step 1 ships with step 0 in 1.93.4.** It's specs plus an opt-in rake task, with no runtime change.
  The plan already orders B right after A, and shipping it early also gives the write-cost numbers
  that Decision 1 waits for well before 1.97.0. If PR B isn't ready when A is, A ships alone as
  1.93.4 and B becomes the first PR of the 1.97.0 train (no version of its own).
- **Steps 2-4 as one minor, 1.97.0, after R2 and before R3.** R3's "embedding-near entities of
  different types" rule can then use step 3's helper.
- Step 5 is deferred and has no version.

## PR breakdown

| PR | Scope | Size | Depends on | Approval needed |
|---|---|---|---|---|
| A | Step 0: specs, then guard fixes (summarizer, ranker, the other guards). **1.93.4** | S, ~250-450 lines | none | decided: bug fix (Decision 2) |
| B | Step 1: bench rake task (search latency, recall, write cost), EXPLAIN-shape, recall and filter-hazard specs. **1.93.4** (release in this PR) | S/M, ~500-800 lines | A | none (specs and opt-in tooling) |
| C | Step 2: inner-ANN search channels, exact fallback, `vector_search_mode` setting (default `exact`, **search only**) with its info tooltip, plus the Settings info-tooltip component (`_field`, CSS, Stimulus controller), recall tuning to the bar, operator docs. **1.97.0** | M, ~800-1,200 lines | B | decided (Decisions 3, 4, N2, N3) |
| D | Step 3: `VectorQuery` helper (`exact:` from each caller's own setting), `suggest_merges` batching, `suggest_merges_time_budget_seconds` (default 30) and text line, separate `suggest_merges_mode` (default `exact`) with ANN in `ann` mode and its recall gate, both fields with info tooltips, subquery → literal in the scoped checks. **1.97.0** (release in this PR) | M, ~900-1,400 lines | B, C (inner-ANN shape, tooltip component) | decided (Decisions 6, N1, N2, N3) |
| E | Step 4: stop loading vectors by default; explicit readers. **1.97.0** | S/M, ~300-600 lines | A | none (performance only) |
| F | Step 5: **deferred** (Decision 7), not scheduled | — | — | would need approval if picked up |
| Release | Version, CHANGELOG, `sync_skill_version` (in the last PR of each release) | S | — | — |

Each PR stays under the ~3,000-line stop. Order: **A → B** (1.93.4, after mcp 1.93.3), then after R2
**C → E → D** (1.97.0; E can come before C, and D goes last because it reuses C's inner-ANN query
shape and the Settings tooltip component). F is deferred. **No new gems. No migrations** in A-E. Removing the index machinery
(Decision 1, if the benchmark says so) would be a separate PR with a migration and needs Steve's
approval.

## Test burden

- CI: keep the single rspec job on **`cimg/mariadb:11.8.6`**. No new matrix. EXPLAIN-shape specs are
  gated on `>= 11.8` and get rechecked whenever the image is bumped.
- Fixtures: synthetic only (`SynthEntity…` names, seeded random clustered vectors, 5% zero
  placeholders). The index and triggers are installed in the spec setup the way
  `embeddings:add_indexes` does it, and dropped afterwards so other specs see the usual schema.
- Recall thresholds: ANN against exact recall@10 ≥ 0.8 average, with no probe below 0.5, on the
  ~2,000-row CI fixture (Decision 4, a starting bar that step 2 must clear). The same bar applies to
  `suggest_merges` in `ann` mode (candidate pairs per probe entity against exact, Decision N2). In
  `exact` mode `suggest_merges` keeps today's results, checked on a fixture small enough to stay below K.
- Performance: the bench rake task is opt-in and never runs in CI (CircleCI medium is too noisy).
  Each of B, C, D and E pastes its numbers into the PR body at 10k, 50k and 200k synthetic rows. B
  includes write cost with and without the index.
- Expected suite growth: about 15-25 spec examples, mostly in services and strategies, plus a
  few seconds of index setup.

## Decisions (Nov 20, 2026)

Steve's answers to the plan's open questions:

1. **HNSW indexes: keep them.** Decide again after step 1's benchmark has measured their write cost.
   Dropping them would be an operator action (`embeddings:drop_indexes`), and fully removing the
   machinery would be a separate PR with a migration that needs approval.
2. **Step 0 ships as a bug fix**, although it changes observation order for unembedded rows in
   `summarize`, `rank_observations`, `get_entities` and `traverse_graph`.
3. **Index search is not the default.** Step 2 ships an app setting `vector_search_mode`
   (`exact | ann`, not an MCP param) that defaults to `exact`. Flip it only if the graph grows.
4. **Recall bar accepted as a starting bar**: ≥ 0.8 average recall@10, no probe below 0.5. Step 2's
   tuning must actually clear it.
5. **Releases:** step 0 as **1.93.4**, right after the mcp 1.93.3 bump, with step 1 alongside it (renumbered on 2026-11-24, see the note at the top).
   Steps 2-4 as **1.97.0**, after R2 and before R3.
6. **`suggest_merges` may stop on a time budget** and say so with a line in its existing text
   output. No new field.
7. **Step 5 (FULLTEXT) is skipped for now** and stays in the plan as deferred.

## Decisions (Nov 24, 2026)

Steve's answers to the two questions raised for the 1.97.0 kickoff (both now resolved):

- **N1. The `suggest_merges` time budget is an app setting**, `suggest_merges_time_budget_seconds`,
  **default 30 s**, a positive integer (proposed cap 600). rails-settings-cached, no migration. It
  applies to the MCP tool and `GET /api/v1/maintenance/suggest_merges` alike, and is documented in
  `docs/app_settings_reference.md` (step 3).
- **N2. Two separate switches.** `vector_search_mode` (`exact | ann`, default `exact`) governs the
  search channels only (step 2). A new `suggest_merges_mode` (`exact | ann`, default `exact`) governs
  only `suggest_merges`' per-entity inner query (step 3). The scoped checks
  (`EntityMergeEvidence`, `ContradictionDetector`, `FactSupersede::Candidates`, `SummarizerService`
  partners) stay exact whatever either switch says. `VectorQuery` takes `exact:` from each caller's
  own setting. The Decision 4 recall bar applies to both `ann` paths.
- **N3. Each of the three settings gets an info tooltip** on the Settings page that says plainly what
  it controls and which feature it affects, so the two modes can't be confused. The wording and the
  component are in "Settings page fields and tooltips".

No MCP params or outputs change: all three are app settings.
