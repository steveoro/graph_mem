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

- **Budget per part:** `floor((summary_num_ctx − project_scan_chunk_output_tokens − prompt) × 0.9)` tokens, where `prompt` is the instructions, the part header and a fixed 1.5 KB allowance for the names from earlier parts. Tokens are estimated, not counted: `project_scan_bytes_per_token` bytes per token (default 3, no tokenizer). At the defaults (8192 − 2048 − about 1,000) × 0.9 is about 4,650 tokens, roughly 14 KB of files per part. Below 1,024 tokens the scan doesn't call the model and falls back, with the reason "summary_num_ctx (N) leaves no room for project files; raise it to at least 4096".
- **Parts:** README and manifests first, then the root files, then each top-level directory by path. Whole files are packed into a part; a file larger than a part is split at line boundaries ("part k of m"). At most `project_scan_max_chunks` parts (default 16). From part 2 on, the prompt lists up to 50 entity names found so far, so the parts reuse the same names.
- **Request per part:** `num_ctx`, `num_predict` = `project_scan_chunk_output_tokens` (default 2048, independent of `summary_max_tokens`), `format: "json"`, `truncate: false` (Ollama refuses an over-long prompt instead of dropping its start), a timeout of `max(summary_timeout, 120)` seconds, and no client-side cut of the answer.
- **A failed part** (an error, `done_reason: "length"`, a prompt Ollama reports at the window, an HTTP 400/413 refusal, or an answer without an `architecture` array) is split in half once and both halves are sent. Two provider errors in a row stop the scan, and so do two halves the provider rejects again: with text much denser than the estimate (CJK docs, minified files, or `project_scan_bytes_per_token` set too high), a scan can stop after about 3 calls. Lower `project_scan_bytes_per_token` or raise `summary_num_ctx` then. If every part fails, the scan uses the deterministic fallback, as before.
- **Merge:** the parts' answers are merged by entity name and canonical type before reconcile, and reconcile creates every entity before any relation, so a relation to an entity from another part is kept.
- **Complete or partial:** a scan is complete when every part succeeded and every discovered file was sent. Only a complete scan marks missing entities obsolete, queues `delete_entity` rows, dismisses conflicting compaction reviews or lets the validator question usage relations. A partial scan still creates and updates what it saw, says so ("Partial: …; nothing was marked missing"), and shows a "Partial extraction" card on the scan page. Files over 50 KB, past the 200 KB input cap or past the part cap are counted and listed, never dropped silently. A project that always has such a file is partial on every scan, so it never marks anything missing.
- **What agents see:** `scan_project_status` returns `counters.parts_total`, `parts_failed`, `files_too_large`, `files_over_budget` and `details.extraction` (parts, files, the left-out paths, the budget, `partial`).
- **Resume:** resuming a paused validation batch doesn't call the model again: the extraction was reconciled in the first batch.
- **`openai_compatible`:** there is no per-request window. The same budget is computed with `summary_num_ctx` as the assumed server window, so set the server's context length to that value; `num_predict` is sent as `max_tokens`.

## Lifecycle interactions

- **Dream-state** and **garbage collection** may change which observations are active between requests; summarization does not duplicate their cleanup responsibilities.
- **Contradiction detection** remains review-oriented. Summarization may surface conflicting active observations but does not supersede or obsolete them automatically.
- Summaries are **not persisted** in the first implementation.

## Related docs

- [App settings reference](app_settings_reference.md)
- [MCP tools](mcp_tools.md)
- [REST API reference](api/rest_api_reference.md)
