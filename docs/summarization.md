# Summarization

GraphMem's `summarize` feature packages hybrid search, context scoping, trust-aware observation ranking, and optional LLM synthesis into a single MCP tool and REST endpoint.

## Overview

- **MCP tool:** `summarize`
- **REST endpoint:** `POST /api/v1/summarize`
- **Core service:** `SummarizerService`
- **Configuration:** `SummarizationConfig` (AppSettings → ENV → defaults)

The feature uses a **hybrid design**:

1. Always build deterministic, source-backed evidence from active observations.
2. Optionally call a text-generation model when `enable_llm_summarization` is enabled and configured.
3. Fall back to deterministic output when the toggle is off, configuration is incomplete, or the provider fails.

## Configuration

Configure under **System › Settings › Summaries** (`/system/settings?tab=summaries`).

| Setting | ENV fallback | Notes |
|---|---|---|
| `enable_llm_summarization` | — | Boolean toggle, default `false` |
| `summary_url` | `SUMMARY_URL`, then `OLLAMA_URL` | Text-generation endpoint |
| `summary_model` | `SUMMARY_MODEL` | Interchangeable model name (e.g. `qwen3:8b`) |
| `summary_provider` | `SUMMARY_PROVIDER` | `ollama` or `openai_compatible` |
| `summary_timeout` | `SUMMARY_TIMEOUT` | HTTP timeout in seconds |
| `summary_max_tokens` | `SUMMARY_MAX_TOKENS` | Output token cap |
| `summary_num_ctx` | `SUMMARY_NUM_CTX` | Ollama context window (`options.num_ctx`), default `8192`, 2048-131072; ignored by `openai_compatible` |

The embedding model used for retrieval is **separate** from the summary model. Do not reuse `nomic-embed-text` or other embedding-only models for synthesis.

### Recommended local models

For a laptop with about 15 GB RAM:

- **Default:** `qwen3:8b` (quantized)
- **Lower memory:** `gemma3:4b`
- **Higher quality:** `gemma3:12b` if enough headroom remains for MariaDB, Rails, and Ollama

Every Ollama request sends `think: false` (1.75.0). A thinking model (`qwen3`, `gemma4`, …) would otherwise spend the answer budget (`num_predict`) on hidden reasoning, and a scan part would come back empty or cut; models without thinking accept the flag. A caller can still pass `think: true`.

## Retrieval and evidence selection

`SummarizerService` performs:

1. **Entity discovery** via `HybridSearchStrategy`, or direct load when `entity_id` is provided.
2. **Scope selection** via `scope`:
   - `context` (default when an active project context exists): hard-filters retrieval to the recursive `part_of` subtree of the active project.
   - `global`: searches the full graph and uses context only as a relevance boost.
3. **Optional traversal** via `GraphTraversalService` when `max_depth > 0`.
4. **Active observation filtering** — obsolete and superseded rows are excluded.
5. **Query-aware ranking** — observation token/vector relevance, then entity relevance, `trust_score`, confidence, then stable ID tie-breakers.
6. **Contradiction hints** — when vectors are available, semantically similar polarity-opposite pairs are flagged with `has_contradiction: true` in the evidence payload.

Source IDs are attached by GraphMem from the selected evidence. They are never taken from LLM output.

### Scope behavior

When a project context is active, `summarize` defaults to `scope: "context"`. This prevents unrelated workspace projects from entering the evidence set when a broad semantic query matches many `Project` entities. Use `scope: "global"` to opt back into workspace-wide retrieval. Project subtrees are bounded: when the cap is reached, summarization continues with its partial scope and explicitly reports that condition.

The response includes a `retrieval` diagnostics object:

- `scope`
- `context_entity_count`
- `scope_truncated`
- `scope_max_entities`
- `candidate_entity_count`
- `selected_entity_count`
- `excluded_out_of_scope_count`
- `selected_observation_count`

## Generation modes

### Deterministic (`generation_mode: "deterministic"`)

Returns:

- `summary`: entity-grouped extractive facts with `observation_id` citations, or a no-evidence message when scoped retrieval finds nothing
- `scope`: `context` or `global`
- `observations`: structured active evidence with provenance, `query_relevance`, and trust metadata
- `sources`: `{ entity_id, observation_id }` pairs
- `retrieval`: candidate/selection diagnostics for the retrieval pass
- `fallback_reason`: `disabled`, `unconfigured`, or `provider_unavailable` when LLM synthesis was skipped

### LLM (`generation_mode: "llm"`)

When enabled and the provider succeeds:

- `summary`: fluent synthesis text
- `generated_by`: configured model name
- `citation_check`: parsed `observation_id=N` citations — `cited_ids`, `unknown_ids` (possible hallucination), `uncited_evidence_ids`, `possible_hallucination`. Singular and plural keys both count, and comma-separated lists (`[observation_id=12, 13]`, `observation_ids=12,13`) credit every id. A comma-continued number only counts when another list element follows or the list closes — prose like `observation_id=7, 2026 plan` credits only 7. Trade-off: a bare unbracketed list ending a sentence (`observation_ids=12, 13.`) credits only the elements before the period; wrap the list in brackets (`[observation_id=12, 13]`) to make it sentence-safe.
- Same `observations` and `sources` as the deterministic path

Provider failures degrade gracefully to deterministic output. Deterministic summaries are self-citing by construction, so `citation_check` is only emitted for `generation_mode == "llm"`.

## Prompt contract

The LLM receives only:

- the query and style
- bounded active observations with explicit `observation_id` and `entity_id`
- instructions to avoid unsupported inference and preserve uncertainty

Temperature is low (`0.1` for concise, `0.3` for detailed).

## API examples

### MCP

```json
{
  "query": "GraphMem search capabilities",
  "scope": "context",
  "max_observations": 10,
  "style": "concise"
}
```

### REST

```bash
curl -X POST http://localhost:3000/api/v1/summarize \
  -H "Content-Type: application/json" \
  -d '{"query":"GraphMem search capabilities"}'
```

## Project scans

An LLM project scan (`ProjectScanner`, MCP `scan_project`) uses the same client and settings. It sends its input in **parts** that fit the model's window instead of one prompt, so no file is cut without the scan knowing.

- **Budget per part:** `floor((summary_num_ctx − project_scan_chunk_output_tokens − prompt) × 0.9)` tokens, where `prompt` is the instructions, the part header and a fixed 1.5 KB allowance for the names from earlier parts. Tokens are estimated, not counted: `project_scan_bytes_per_token` bytes per token (default 3, no tokenizer). At the defaults (8192 − 2048 − about 1,000) × 0.9 is about 4,650 tokens, roughly 14 KB of files per part. Below 1,024 tokens the scan doesn't call the model and falls back, with the reason "summary_num_ctx (N) leaves no room for project files; raise it to at least M, or lower project_scan_chunk_output_tokens (P)", where M is the exact minimum for the current settings. At the default answer budget (2048) M is about 4,150 (2048 + about 1,000 for the prompt + 1,024 / 0.9), so use 8192, or lower `project_scan_chunk_output_tokens` on a small window.
- **Parts:** README and manifests first, then the root files, then each top-level directory by path. Whole files are packed into a part; a file larger than a part is split at line boundaries ("part k of m"). At most `project_scan_max_chunks` parts (default 16). From part 2 on, the prompt lists up to 50 entity names found so far, so the parts reuse the same names.
- **Request per part:** `num_ctx`, `num_predict` = `project_scan_chunk_output_tokens` (default 2048, independent of `summary_max_tokens`), `format: "json"`, `truncate: false` (Ollama refuses an over-long prompt instead of dropping its start), `think: false`, a timeout of `max(summary_timeout, 120)` seconds, and no client-side cut of the answer.
- **A failed part** (an error, `done_reason: "length"`, a prompt Ollama reports at the window, an HTTP 400/413 refusal, or an answer without an `architecture` array) is split in half once and both halves are sent. Two provider errors in a row stop the scan, and so do two halves the provider rejects again: with text much denser than the estimate (CJK docs, minified files, or `project_scan_bytes_per_token` set too high), a scan can stop after about 3 calls. Lower `project_scan_bytes_per_token` or raise `summary_num_ctx` then. If every part fails, the scan uses the deterministic fallback, as before.
- **Merge:** the parts' answers are merged by entity name and canonical type before reconcile, and reconcile creates every entity before any relation, so a relation to an entity from another part is kept.
- **Complete or partial:** a scan is complete when every part succeeded and every discovered file was sent. Only a complete scan marks missing entities obsolete, queues `delete_entity` rows, dismisses conflicting compaction reviews or lets the validator question usage relations. A partial scan still creates and updates what it saw, says so ("Partial: …; nothing was marked missing"), and shows a "Partial extraction" card on the scan page. Files over 50 KB, past the 200 KB input cap or past the part cap are counted and listed, never dropped silently. A project that always has such a file is partial on every scan, so it never marks anything missing.
- **Names and other projects (1.73.1):** a project holds one entity per name whatever the type the model gives it (the first type stays; how often the type differed is counted as `type_mismatches` in the scan's Ruby result and its numbers-only `[scan]` line). An item naming the scanned project (or an alias) adds its facts to the project's root. A project-like item (typed as a project, a gem or a framework) naming **another** Project root (case, `-` and `_` ignored, aliases included; say `goggles_db` in goggles_api's Gemfile) creates nothing inside the scanned project: the scanned root gets one `depends_on` to that root (none if the two are already related either way), and nothing is written to the other project; a `part_of` into another root is never written. Any other item sharing a root's name stays local, a relation's target resolves to the scanned project's own entities before another root, and a name two roots share links to neither (counted in one numbers-only `[scan]` line). Without such a root, an item typed as a project (Project, repository, codebase, …) becomes a Component, never a second Project-typed entity; once the root exists, the next complete rescan links it and the Component is reported missing (its scan facts obsoleted, a `delete_entity` review row queued). When every part fails, the scan still reports the parts it tried (`parts_total`, `parts_failed`) and falls back.
- **Rails code map (1.75.0):** when the project folder is a Rails application or engine (an `app/` dir, plus `rails`/`railties` in its Gemfile or a root gemspec, or a `config/application.rb`), the scan first builds a deterministic **code map** from its Ruby code (`RailsCodeMap`, Prism only, no model): one entry per file's main constant under a Zeitwerk root (app/models/goggles_db/badge.rb → `GogglesDb::Badge`), with its Rails role type (Model, Controller, Helper, Job, Mailer, Concern, Strategy, …, as `rails_ast:import` types them), its aliases (the short name and the path) and a `Defined at <file>:L<n>` fact; one View entry per `app/views` folder and one Layout per layout file, named by path; a Route entry for `config/routes.rb`; and the relations the code proves (inherits, associations, mixins, `routes_to` each routed controller, engine namespaces included, and each controller or mailer `relates_to` its views). It reads every Ruby dir of `app/` and `lib/` whatever `file_globs` say, through the scan's file filter, and skips constants named like the project or another Project root (lib/goggles_db.rb's `GogglesDb`). Then:
  - **Skeleton:** right after the root, the map is written into the project (`ProjectScanner::SkeletonWriter`, source `rails_code_map`): entities under the root (a stored Class or Module takes the role type; another stored type is kept), their facts (confidence 1.0; a moved `Defined at` supersedes the old one) and relations. A later scan diffs only that source: a fact the code lost is obsoleted, an entity the code lost has its facts obsoleted (the missing-entity pass then queues it for review), and a relation the code lost becomes a `delete_relation` review row, never a silent delete. Nothing is retired when the map is incomplete (more than 3,000 files or 2,000 entries), when an entry failed to write in that scan, or for an entity whose file couldn't be parsed. The validator leaves the source's facts and relations alone. The skeleton is written on the deterministic fallback too.
  - **Guide:** each part's prompt lists the code entities its files define ("use exactly these names and types"), the ones related to them or named in the part, and that a declared gem is type Gem, within a fixed 2 KB allowance (counted in the part budget only for a Rails project; the names are data, so a cloud provider's anonymizer masks them).
  - **Canonicalization:** each part's answer is mapped onto the map before the merge: an item the map resolves (exact name, else the one entry its short name, path or trailing part points to, else the one the part's files define, else the one related to them or in their namespace) takes the map's name and type and loses the model's aliases and `part_of` (the skeleton owns containment); an item or relation target the part can't tell apart (a bare `Badge` in a part that defines both `GogglesDb::Badge` and `GogglesDb::Importers::Badge`, or in a README) is dropped and counted; any other item keeps its name and type, except that a gem the Gemfile or a gemspec declares is typed Gem. Names of Project roots aren't in the map, so they still link as above. A relation target the map doesn't know matches a stored alias only as a whole alias, never as a substring of a path alias. The validator keeps a scan fact on a code-map entity where the scan filed it: the code chose the entity, not the fact's wording, so a fact that names no entity ("Not meant to be instantiated directly.") isn't obsoleted, and one that names another class ("It belongs to a User.") isn't moved. A manual fact there that names another entity is still only queued for a move review.
  - **Counts:** the scan's Ruby result has `code_map` (entities, views, relations, unreadable and non-conventional files, items mapped and dropped, targets dropped, gems typed, complete, and what the skeleton wrote) and one numbers-only `[scan]` line; MCP and REST outputs are unchanged. A folder that isn't a Rails project scans exactly as before.
- **Reworded facts (1.76.0):** a model words the same fact differently on every scan, and reconcile used to skip only an exact repeat, so each rescan of unchanged code added near-duplicates. Before a new fact is written, its embedding is compared with its entity's embedded active facts (`ImportObservationDuplicateDetector`, embedded facts only); one within `project_scan_fact_duplicate_max_distance` (cosine distance, default 0.2, Settings › Project scans) is the same fact, so it is skipped and counted (`observations_deduped` in the scan's Ruby result and its numbers-only `[scan]` line). Without embeddings (none configured, or the service down) only the exact check runs, and the scan never fails on it. Facts the model stops stating are not retired: nothing obsoletes a prior scan's fact while its entity is still scanned.
- **Noise filter (1.73.0):** before reconcile, the merged LLM extraction loses normalized duplicate observations, self-relations, entities named only by a file extension or a generic word (`Utils`, `Helper`, …) with at most one observation, and entities with no observations and no relations that nothing points at (`ProjectScanner::NoiseFilter`). The counts are in the scan's Ruby result (`noise_dropped`) and one `[scan]` log line, not in MCP or REST outputs. The deterministic fallback isn't filtered.
- **Tuning:** `bin/rails graph_mem:scan_profile` measures parts, failures, splits, latency and noise per setting on pinned open-source repos or a synthetic repo, in a throwaway database: see [Scan profiling](scan_profiling.md).
- **What agents see:** `scan_project_status` returns `counters.parts_total`, `parts_failed`, `files_too_large`, `files_over_budget` and `details.extraction` (parts, files, the left-out paths, the budget, `partial`).
- **Resume:** resuming a paused validation batch doesn't call the model again: the extraction was reconciled in the first batch.
- **`openai_compatible`:** there is no per-request window. The same budget is computed with `summary_num_ctx` as the assumed server window, so set the server's context length to that value; `num_predict` is sent as `max_tokens`.

## LLM providers

Every model call goes through one seam, `Llm::Router` (`app/services/llm/`), which picks a provider per **task**:

| Task | Caller | Options |
|---|---|---|
| `:summary` | `SummarizerService` (MCP `summarize`, `POST /api/v1/summaries`) | none (the client's defaults, incl. the 8,192-character cut) |
| `:scan` | `ProjectScanner::ChunkedExtraction`, one call per part | `num_ctx`, `num_predict`, `format: "json"`, `truncate: false`, the scan timeout, no cut |
| `:judge` | `FactSupersede::Judge`, one call per batch (`FactSupersedeJob`, and inline from `detect_contradictions` with `mode: "outdated_by_fact"`) | `num_ctx`, `num_predict`, `format: "json"` (no `max_output_length`, so the 8,192-character cut applies) |

- **Providers:** `Llm::OllamaProvider` (named `ollama` for both transports, `openai_compatible` included) calls `SummaryGenerationClient.generate` with exactly the arguments the call site passes; requests, prompts and results are what they were before 1.67.0, and the result Hash only gains `provider: "ollama"`. Since 1.70.0 there is a second, opt-in one, `agent_cli` (`Llm::AgentCliProvider`): an agent CLI on the operator's workstation behind the host bridge (below). It is a cloud provider, so every call goes through `Llm::CloudCall` (see "Anonymization and cloud access").
- **Chains (1.70.0):** each task tries the providers its setting names, in order: **Settings › Summaries** `llm_chain_summary`, `llm_chain_scan`, `llm_chain_judge`, each one of `ollama` (the default), `agent_cli`, `agent_cli,ollama` or `ollama,agent_cli`. With the defaults every task runs exactly as before. `Llm::Router.usable?(task)` is true when any provider in the chain is configured (for `ollama`, `SummarizationConfig.llm_usable?`). The next provider is tried after a `CloudCall` refusal (no call was made), any `agent_cli` failure (the bridge is unconfigured, unreachable, busy, refusing, its gate missing, failed, stale or tripped, or the CLI failed), or an Ollama outage with no answer at all (refused or timed out; so `ollama,agent_cli` uses the bridge only when Ollama is down). An Ollama answer that refuses the prompt (400/413) or isn't usable is returned. When nothing answers, the caller sees the last real failure, never a cloud refusal that came after it (Ollama down and the project not allowed: the Ollama error). Two `agent_cli` results are returned instead too: `prompt_too_long` (a 413, so a scan part splits) and `agent_cli_tool_use` (never hidden by a fallback).
- **Profiles and backup models (1.71.0):** a chain may also name the shipped profiles: `claude`, `devin`, `claude,devin` or `devin,claude`, each alone or followed by `,ollama`. Each profile has a model (`llm_profile_<name>_model`) and up to three backup models (`llm_profile_<name>_backup_models`), tried in order. A failure about the model (`agent_cli_model_unavailable`, `agent_cli_payment_required`, `agent_cli_quota`, `agent_cli_rate_limited`, or `bridge_gate_missing` for a model the gate didn't test) tries the profile's next model. Any other bridge or CLI failure, or a refusal, moves on to the next profile, then Ollama if listed. `agent_cli` (the 1.70.0 value) keeps its single profile and model unless that profile's own model field is set. Each attempt writes its own `[llm]` line with `profile` and `fallback_step` (0 for the first attempt); an Ollama line has `fallback_step` only after a fallback.
- **JSON answers (1.71.0):** a cloud scan or judge answer must be JSON of the shape its caller parses (scan: one object; judge: an array, or an object whose only array value is the list). A wrong one is retried **once** on the same profile and model, with the same masked prompt plus a fixed request for only that JSON. Still wrong, it fails as `agent_cli_invalid_json`, which skips the remaining backups and profiles and goes to Ollama if listed (a scan part then fails without a split). An answer whose tokens can't be restored exactly (`anonymization_round_trip_failed`) also goes to Ollama, never retried. Cloud JSON answers are not cut at 8,192 characters (only the 256 KiB scan cap applies); Ollama answers are unchanged and never checked.
- **Inline calls and requests:** a call made inside an MCP request (the judge under `detect_contradictions`) is marked `inline`, and a summary always runs inside a request (the `summarize` tool, `POST /api/v1/summaries`). Neither waits on the bridge: a chain with nothing left answers `inline_skipped` (the summary is deterministic, the judge leaves candidates unjudged). Only **Requests that may use the host bridge** = `summary` (`llm_inline_cloud_tasks`) lets a summary try it: one attempt, primary model only, the whole call (connect, the bridge's checks and the CLI) fitted inside `llm_inline_cloud_timeout` seconds (20 by default, 5 to 60). `detect_contradictions` never does. When a cloud provider answers, the summary's `generated_by` names that model.
- **One cloud job at a time (1.71.0):** while its task's chain names a cloud provider, a `ProjectScanJob` or `FactSupersedeJob` shares one Solid Queue concurrency key (`llm/llm_cloud`, limit 1), so two cloud-using jobs never run at once; otherwise each keeps its own key. The key is read when the job is enqueued.
- **Budgets and usage (1.71.0):** `llm_budget_<task>_calls` and `llm_budget_<task>_tokens` cap each task's cloud sends per calendar day (0, the default, means no limit). Every send a model answered counts (ok or a CLI-level failure; a send the bridge refused or never got costs nothing), backups and the JSON retry included; tokens are the `[llm]` estimates. Over a budget the attempt is refused as `budget_exhausted` (nothing sent) and the chain moves on. The **LLM usage** card in Settings › Summaries shows, for today and the previous day, calls, OK, errors, fallbacks, refusals and estimated tokens per task and provider, plus each budget's remainder. The counters live in the cache (two days), hold numbers only, and are best effort under concurrency (each concurrent sender can overshoot a budget by one call; cloud jobs run one at a time, opted-in summaries don't). They need a cache shared across processes: production's `solid_cache_store` is, development's `memory_store` is per process. The usage counters run on every LLM call, the default Ollama-only chain included: one synchronous `Rails.cache.increment` per non-zero field, so 3 for a successful call and at most 4 (each a database upsert on `solid_cache_store`). That is small next to the model call, and the output doesn't depend on it.
- **Prompt parts:** each prompt is built as an `Llm::Prompt` of `trusted` segments (our instructions, labels and ids) and `data` segments (the caller's query and style, names, observation text, the fact and statements, file contents), and rendered as the same string as before.
- **Usage log:** one `info` line per call, also on failure, prefixed `[llm]`, with JSON fields `task`, `provider`, `model`, `inline`, `prompt_chars`, `est_in_tokens`, `out_chars`, `est_out_tokens` (4 characters per token), `latency_ms`, `outcome` (`ok` / `error`) and `prompt_tokens` when the provider reports it. It never contains the prompt, the answer, an error text or a project or entity name. For example:

  ```
  [llm] {"task":"scan","provider":"ollama","model":"qwen3:8b","inline":false,"prompt_chars":5236,"est_in_tokens":1309,"out_chars":225,"est_out_tokens":57,"latency_ms":9120.4,"outcome":"ok","prompt_tokens":1500}
  ```
- **Host bridge (1.69.0):** `script/llm_bridge/` is a loopback-only HTTP bridge for agent CLIs (`claude`, `devin`), installed separately on the workstation. The app never starts it. Each profile needs a lockdown-gate PASS before the bridge serves it. For cloud providers, people's names (Person and User entities) are masked by full name or alias wherever they are in the graph (see below for what isn't matched). Setup and the HTTP contract: [`script/llm_bridge/README.md`](../script/llm_bridge/README.md).
- **Reaching the bridge (1.70.0):** `Llm::BridgeClient`, plain HTTP with no proxy, redirect or retry, configured by two environment variables:
  - `LLM_BRIDGE_URL`: exactly `http://127.0.0.1:<port>`. `localhost`, `::1`, another address, `https`, a path, a query or user info all leave it unconfigured. `docker-compose.yml` uses host networking, so the container reaches the host's loopback.
  - `LLM_BRIDGE_TOKEN_FILE` (default `~/.local/state/agent-cli/bridge.token` in the app user's home): read on every request, opened without following a symlink, and refused unless it is a regular file owned by the app's own uid, with no group or other bits and at least 32 bytes. In the container (uid 1000), mount a 0600 copy owned by uid 1000, or the bridge's own file when the workstation user is uid 1000. There is no token environment variable. The token is never logged, stored in a setting or put in an error.
  - Then, in **Settings › Summaries**, the **Host bridge profile** (`claude` or `devin`) and **Host bridge model** (one the profile's gate passed). The **Host bridge** block there has a **Check now** button (`bin/rails llm:bridge_probe` prints the same): whether the bridge answers, and each profile's CLI, gate result and date, and tripped state. It shows no path and no token.
- **What the bridge's answers become:**

  | Bridge answer | Result `error` | Chain | Scan part |
  |---|---|---|---|
  | 200, `ok: true` | none (the text, normalized) | returned | parsed |
  | 200, `cli_<class>` | `agent_cli_<class>` (`cli_truncated` also sets `done_reason: "length"`) | next model or provider (above) | fails, not split |
  | 200, `cli_tool_use` | `agent_cli_tool_use` | returned | fails |
  | 413 | `prompt_too_long`, `http_status: 413` | returned | **split** |
  | 400 / 401 / 404 / 405 / 429 / 500 | `bridge_bad_request`, `bridge_unauthorized`, `bridge_not_found`, `bridge_method_not_allowed`, `bridge_busy`, `bridge_error` | next provider | fails, not split |
  | 503 | `bridge_cli_missing`, `bridge_gate_missing`, `bridge_gate_failed`, `bridge_gate_stale`, `bridge_tripped` | next provider | fails, not split |
  | no answer, timeout, anything else | `bridge_unreachable`, `bridge_bad_response` | next provider | fails, not split |

  Only the 413 row carries an `http_status`, so a bridge 400 can never make a scan split its parts. Two bridge failures in a row stop a scan, like two Ollama outages. The answer is normalized before the tokens are restored (`Llm::ResponseNormalizer`): for `format: "json"` (scan, judge), one Markdown fence and the prose around the outermost JSON value are dropped; a summary is trimmed; then the caller's `max_output_length` applies as for Ollama.
- **Setting it up:** the adopter guide, [`docs/agent_cli_backends.md`](agent_cli_backends.md), covers the workstation, the bridge, the app side, enabling one task for one project, what leaves the machine and how to turn it off. The train's plan: [`docs/plans/agent-cli-backend-plan.md`](plans/agent-cli-backend-plan.md).
- **Specs:** `spec/support/llm.rb` has a `FakeProvider` (`with_llm_provider(fake) { … }`) and a `SubprocessGuard` that fails a spec when code under `app/` or `lib/` starts a process (`lib/tasks/db_utils.rake`, which runs mariadb-dump for backups, is the one exception). `spec/services/llm/characterization_spec.rb` pins every prompt and request body against `spec/fixtures/llm/`.

## Anonymization and cloud access

Since 1.68.0 the Router can send a call to a **cloud** provider (one with `cloud?` true). Since 1.70.0 there is one, `agent_cli`, reached only when a task's chain names it (see "LLM providers"); with the default chains nothing leaves the machine and Ollama calls are unchanged. When a cloud provider is in the chain, each call goes through `Llm::CloudCall`:

- **Which data:** each prompt is an `Llm::Prompt` of `trusted` segments (our instructions, labels and ids) and `data` segments: the caller's query and style, entity and project names, observation text, the fact and statements, file contents. Only data segments are rewritten. The prompt is scoped (`Llm::Scope`) to the projects its data comes from: the summary's evidence, the judge's fact and candidates, or the scanned project.
- **The gate (`Llm::CloudGate`):** the call goes out only if every project in scope is a Project root with **Cloud** on. Data without a project is refused. A scan's project comes from the **folder**, not from the name it was started with (1.70.0): the folder's realpath must be, byte for byte (case and accents count), the `cloud_root` of exactly one Project root with Cloud on, recorded when Cloud was turned on as the realpath of the project's last completed scan. The scan's project name must then equal that project's name exactly. A scan of any other folder, a missing one, a folder two projects recorded, a name that doesn't match, or a project that had no completed scan stays local. A recorded folder with a symlink anywhere on its path is refused too, so re-pointing a link at or above it can't send another tree; turn Cloud off and on again to record the new realpath. If a scan finishes between loading the Projects page and confirming, the toggle changes nothing and asks you to check the new folder. The flag and the folder are read afresh on each call, so turning Cloud off takes effect on the next call, mid-scan included.
- **What is masked (`Llm::Anonymizer`):**
  - Names become typed tokens such as `⟦PRJ_3f9a⟧`: every Project root's name and aliases (`PRJ`), and the members of the projects in scope (`ENT`, or `PER` for a person). Each name is also masked without its trailing generic words ("Gadget Project" → "Gadget"). Names are matched in any spelling: spaced, camel, snake, kebab, SCREAMING, fused, inside identifiers and path segments, with a plural or a trailing number.
  - URLs (git remotes too), e-mails, IPs, private-suffix hosts (`.local`, `.internal`, …) and absolute paths are masked whole. So is a username taken from a home-directory path, everywhere it appears.
  - Secrets (PEM blocks, `sk-…`, GitHub and Slack tokens, AWS keys, JWTs, the value after a `password`/`secret`/`token`/`api key`/`access key`/`private key` name, env-style ones like `DB_PASSWORD=` included, and random-looking long runs: hex, base36, base64) become `⟦SECRET⟧`. They are never restorable, so the caller gets `[redacted]`.
- **Sessions:** a token's suffix is an HMAC of the name with a random salt per session. A session covers one summary or judge call, or one whole scan, so every part and split of a scan shares one mapping. Tokens from different sessions can't be linked. There is one token per spelling, so restoring gives back the exact text.
- **Fail closed.** These refusals reach the provider with nothing: `prompt_not_segmented`, `cloud_not_allowed`, and `anonymizer_refused` (input that already contains `⟦`, `⟧` or a token-like word; a leftover found when the masked text is scanned again; a pattern timeout; more than 20,000 names). An answer with an invented token or a half-restored one fails as `anonymization_round_trip_failed`, and so does a scan answer that writes a masked name out in plain text. Each caller degrades as on any LLM error: the summary is deterministic (with that `fallback_reason`), the scan part fails (and the scan falls back to the deterministic extraction if every part fails), and the judge leaves candidates unjudged.
- **Never kept:** the mapping, the tokens, the originals and the salt live only in the session object. They are never logged, persisted, serialized or put in an error message. A cloud `[llm]` line adds counts only: `anonymized`, `masked` (per type), `secrets`, `round_trip`, `leftover_out`, and `refused` / `refused_detail` for a refusal. Its `prompt_chars` measure the masked text.
- **Turning it on:** on the **Projects** page, the **Cloud** column (operator only) records a `project.cloud_access` change set and an audit row. The confirm names the folder cloud scans will be allowed from. It is off by default; to move the folder, scan the new one, then turn Cloud off and on again. REST, MCP, Explore, imports and exports can't set it.
- **What still leaks:** this is pseudonymization, not anonymity.
  - The structure of the code and text, domain vocabulary, numbers, dates and generic words go out as they are.
  - A name fused with other lowercase letters (`gadgetprojectcontroller`, `gadgetapp.example.com`) isn't matched; public hosts are left as they are unless they contain a matched name.
  - People (Person and User entities) are masked by full name or alias, in any case or separator form and inside identifiers, wherever they are in the graph. A first or last name on its own, a reordered name (`Doe, Jane`), an unaccented spelling of an accented name, a person stored under another type (`Developer`, `Author`) and a name that is in no entity go out as written. People count toward the dictionary's 20,000-term cap, so a graph with many of them refuses cloud calls sooner.
  - Allow cloud access only for projects whose remaining text you are willing to share.

## Lifecycle interactions

- **Dream-state** and **garbage collection** may change which observations are active between requests; summarization does not duplicate their cleanup responsibilities.
- **Contradiction detection** remains review-oriented. Summarization may surface conflicting active observations but does not supersede or obsolete them automatically.
- Summaries are **not persisted** in the first implementation.

## Related docs

- [App settings reference](app_settings_reference.md)
- [Scan profiling](scan_profiling.md): `graph_mem:scan_profile`, to measure and tune project scans safely
- [MCP tools](mcp_tools.md)
- [REST API reference](api/rest_api_reference.md)
