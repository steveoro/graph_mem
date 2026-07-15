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

Configure under **Operator → System Settings → Summaries** (`/operator/settings?tab=summaries`).

| Setting | ENV fallback | Notes |
|---|---|---|
| `enable_llm_summarization` | — | Boolean toggle, default `false` |
| `summary_url` | `SUMMARY_URL`, then `OLLAMA_URL` | Text-generation endpoint |
| `summary_model` | `SUMMARY_MODEL` | Interchangeable model name (e.g. `qwen3:8b`) |
| `summary_provider` | `SUMMARY_PROVIDER` | `ollama` or `openai_compatible` |
| `summary_timeout` | `SUMMARY_TIMEOUT` | HTTP timeout in seconds |
| `summary_max_tokens` | `SUMMARY_MAX_TOKENS` | Output token cap |

The embedding model used for retrieval is **separate** from the summary model. Do not reuse `nomic-embed-text` or other embedding-only models for synthesis.

### Recommended local models

For a laptop with about 15 GB RAM:

- **Default:** `qwen3:8b` (quantized)
- **Lower memory:** `gemma3:4b`
- **Higher quality:** `gemma3:12b` if enough headroom remains for MariaDB, Rails, and Ollama

## Retrieval and evidence selection

`SummarizerService` performs:

1. **Entity discovery** via `HybridSearchStrategy`, or direct load when `entity_id` is provided.
2. **Context scoping** via `GraphMemContext.scoped_entity_ids` when a project context is active.
3. **Optional traversal** via `GraphTraversalService` when `max_depth > 0`.
4. **Active observation filtering** — obsolete and superseded rows are excluded.
5. **Deterministic ranking** — entity relevance, `trust_score`, confidence, then stable ID tie-breakers.
6. **Contradiction hints** — when vectors are available, semantically similar polarity-opposite pairs are flagged with `has_contradiction: true` in the evidence payload.

Source IDs are attached by GraphMem from the selected evidence. They are never taken from LLM output.

## Generation modes

### Deterministic (`generation_mode: "deterministic"`)

Returns:

- `summary`: a short heading such as `Top facts about <query>`
- `observations`: structured active evidence with provenance and trust metadata
- `sources`: `{ entity_id, observation_id }` pairs
- `fallback_reason`: `disabled`, `unconfigured`, or `provider_unavailable` when LLM synthesis was skipped

### LLM (`generation_mode: "llm"`)

When enabled and the provider succeeds:

- `summary`: fluent synthesis text
- `generated_by`: configured model name
- Same `observations` and `sources` as the deterministic path

Provider failures degrade gracefully to deterministic output.

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

## Lifecycle interactions

- **Dream-state** and **garbage collection** may change which observations are active between requests; summarization does not duplicate their cleanup responsibilities.
- **Contradiction detection** remains review-oriented. Summarization may surface conflicting active observations but does not supersede or obsolete them automatically.
- Summaries are **not persisted** in the first implementation.

## Related docs

- [App settings reference](app_settings_reference.md)
- [MCP tools](mcp_tools.md)
- [REST API reference](api/rest_api_reference.md)
- [Phase 5 plan](plans/phase_5_towards__a_knowledge_base.md)
