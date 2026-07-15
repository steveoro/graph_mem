# GraphMem Next Step #5: Query-Scoped Summarization

Add a `summarize` MCP tool and REST endpoint that accepts a query, retrieves the most relevant active observations and entities, and returns a concise, optionally context-aware natural-language summary.

## Context

This is the next roadmap item after the completed ranking/contradiction work (#2). GraphMem already supports hybrid search, trust scores, context scoping, and graph traversal. The next logical step is to package those results into a consumable summary for an MCP client or REST consumer.

## Goal

Let a user ask “Summarize what we know about X within the current project context” and get back a short, sourced summary with traceable observation IDs.

## Scope

- New MCP tool: `summarize(query, entity_id: nil, max_results: 10, max_observations: 20, max_depth: 0, include_sources: true, style: "concise")`.
- New REST endpoint: `POST /api/v1/summarize` with the same parameters.
- A shared `SummarizerService` that retrieves active, in-context observations and produces either an LLM synthesis or a deterministic extractive result.
- Operator-configurable LLM settings under **System Settings → Summaries**, following the existing `AppSettings → ENV → defaults` resolution order.
- A UI toggle that enables or disables LLM synthesis. The deterministic alternative remains available when the toggle is off, the LLM configuration is incomplete, or the configured provider is unavailable.
- Responses always retain traceable entity and observation source IDs, independently of any IDs or claims produced by an LLM.
- No automatic persistence of generated summaries in the first pass; summaries are on-demand responses derived from the current active graph.

## Out of Scope

- Streaming summaries.
- Multi-turn / chat-style summarization.
- Public web UI changes beyond the operator settings page and Swagger/docs.
- Automatic persistence/caching of summaries in the first pass.

## Design Alternatives

### A. Summary generation method

**A1. Optional LLM-generated synthesis (Ollama by default)**

- **Flow:** The service runs the existing `HybridSearchStrategy`, applies `GraphMemContext.scoped_entity_ids`, optionally performs bounded graph traversal, filters to active observations, and ranks the evidence by relevance and `trust_score`. It then sends only that bounded evidence to the configured text-generation endpoint, such as Ollama's `/api/generate` or an OpenAI-compatible `/chat/completions` endpoint.
- **Model separation:** `embedding_model` remains exclusively responsible for 768-dimensional retrieval vectors. Summarization uses a separate interchangeable `summary_model` name, so operators can select models such as `qwen3:8b`, `gemma3:4b`, or another Ollama-compatible instruct model without changing embeddings or stored vector dimensions.
- **Prompt contract:** The model must summarize only the supplied observations, avoid unsupported inference, preserve meaningful uncertainty or conflicting facts, and return plain summary text. Source IDs are attached by GraphMem from the selected evidence, not trusted from model output.
- **Resource profile:** The default documentation should recommend a quantized 7B–8B model for a 15 GB RAM laptop, with a smaller 3B–4B model as a low-memory option. Prompt size and output token limits must be bounded because model-file size is not the same as total runtime memory.
- **Example output:** `{"summary": "Steve primarily uses Ruby and Python for Rails projects, writes TypeScript for React frontends, and is currently exploring Rust.", "sources": [{"entity_id": 12, "observation_id": 123}, {"entity_id": 12, "observation_id": 124}], "generated_by": "qwen3:8b"}`
- **Pros:** Human-readable synthesis, can combine related observations, and can be tuned by `style`.
- **Cons:** Requires an external text-generation model, adds latency and resource usage, may hallucinate, and requires provider failure handling and stubbed-client tests.

**A2. Deterministic extractive summary**

- **Flow:** The service performs exactly the same retrieval, context filtering, traversal, active-observation filtering, and trust-aware ranking as A1. It returns a short deterministic heading plus the selected observations, optionally grouped by entity and annotated with trust, confidence, provenance, validity, and contradiction status.
- **Example output:** `{"summary": "Top facts about Steve's favorite programming languages", "observations": [{"id": 123, "content": "Steve prefers Ruby for Rails", "trust_score": 0.95}], "entity_count": 3, "observation_count": 12, "generated_by": "deterministic"}`
- **Role in the design:** A2 is the guaranteed evidence and availability path, not merely a development fallback. It works when LLM summarization is disabled, no summary model is configured, Ollama is stopped, a request times out, or the operator wants reproducible output.
- **Pros:** No external LLM, fast, deterministic, auditable, cheap to run, and straightforward to test.
- **Cons:** It is not fluent synthesis and can be verbose. It should therefore expose structured evidence rather than pretending that concatenated facts are an LLM-generated paragraph.

**A3. Hybrid evidence plus optional synthesis (recommended)**

- Always calculate and return the deterministic evidence selection.
- If `enable_llm_summarization` is true and the resolved summary configuration is usable, attempt A1 and add its text to the response.
- If configuration is absent, the feature is disabled, or the provider fails, return A2 with a machine-readable `generation_mode: "deterministic"` and a non-sensitive diagnostic such as `fallback_reason: "disabled"`, `"unconfigured"`, or `"provider_unavailable"`.
- If the LLM call succeeds, return `generation_mode: "llm"` while retaining the same source list and evidence payload.
- Do not make a failed Ollama request fail the entire summarize tool unless the caller explicitly requests strict LLM-only behavior; the first-pass API should default to graceful fallback.

### B. Integration / API shape

**B1. Standalone `summarize` tool + REST endpoint**

- **Flow:** A new MCP tool `summarize` and `POST /api/v1/summarize` accept the query and parameters. Clients call it explicitly when they want a summary.
- **Pros:** Clear separation, easy to discover, flexible parameters (`style`, `max_depth`, `include_sources`), not tied to search pagination.
- **Cons:** Extra tool/endpoint in the API surface.

**B2. Add a `summary` field to existing search results**

- **Flow:** `search_subgraph` and `GET /api/v1/search/subgraph` accept a new parameter such as `include_summary: true` (or `summary_style: "concise"`) and return the generated summary inside the existing search response.
- **Pros:** One call returns both raw results and a summary, good for dashboards and search UIs.
- **Cons:** Couples summary generation to search pagination (summary might be scoped to the current page), heavier response, requires updating `search_subgraph`'s output schema, less flexible for LLM-specific options.

The current implementation outline below assumes **A3 + B1** (hybrid evidence with optional LLM synthesis, exposed through a standalone tool/endpoint).

## Decision

- Use **A3 hybrid evidence plus optional synthesis**.
- Keep the standalone `summarize` tool and REST endpoint as the primary integration shape.
- Keep deterministic evidence in every response and use it whenever LLM summarization is disabled or unavailable.
- Do not couple normal search pagination to an LLM call in the first implementation.

## Implementation Outline

1. **Configuration and operator settings**
   - Add `SummarizationConfig` following the existing `EmbeddingConfig` pattern and resolving values with priority **AppSettings → ENV → defaults**.
   - Add configurable values:
     - `summary_url`: provider URL; blank defers to `SUMMARY_URL`, then `OLLAMA_URL` for the default Ollama provider.
     - `summary_model`: interchangeable model name; blank defers to `SUMMARY_MODEL`, then a documented small local default.
     - `summary_provider`: `ollama` or `openai_compatible`; blank defers to `SUMMARY_PROVIDER`, then `ollama`.
     - `summary_timeout`: bounded HTTP timeout; blank defers to `SUMMARY_TIMEOUT`, then a safe default.
     - `summary_max_tokens`: bounded output size, with an ENV/default fallback.
     - `enable_llm_summarization`: boolean feature toggle, defaulting to `false` unless explicitly enabled.
   - Add the corresponding `AppSettings` entries and document them in `docs/app_settings_reference.md` when implementation begins.
   - Extend the existing operator settings page with a dedicated **Summaries** tab/section alongside Feature Flags, Database Backup, and Embeddings. Use the established form and authorization patterns.
   - Render `enable_llm_summarization` as a Bootstrap toggle switch. Make clear in the UI that disabling it selects deterministic summaries rather than disabling the `summarize` endpoint.
   - Provide model/provider/URL/timeout/token fields with help text, a masked or safe URL presentation where appropriate, and a save/reset path consistent with the Embeddings settings page.
   - Configuration changes must be picked up by subsequent requests without a process restart. If configuration is cached, provide a reset hook equivalent to `EmbeddingService.reset_instance!`; boolean enablement must be read from the database in the same way as existing worker feature flags.

2. **Core service and fallback behavior**
   - Create `app/services/summarizer_service.rb` with `call(query:, entity_id: nil, max_results: 10, max_observations: 20, max_depth: 0, include_sources: true, style: "concise", context_entity_ids: nil)`.
   - Fetch relevant entities via `HybridSearchStrategy` (or by `entity_id` directly), then optionally use `GraphTraversalService` with bounded depth and entity limits.
   - Collect active observations only. Exclude obsolete and superseded rows by default, consistent with normal reads, search, dream-state compaction, and garbage-collector behavior.
   - Rank and cap evidence deterministically. Use relevance first, then `trust_score`, confidence, validity, and stable IDs as deterministic tie-breakers.
   - Preserve provenance and validity metadata in the evidence payload. Do not silently discard observations merely because they disagree; expose candidate conflicts so the LLM and caller can distinguish uncertainty from consensus.
   - Build a bounded prompt from the query, active context, entity metadata, relations, and selected evidence. Never send the whole graph by default.
   - Select the generation path before calling the provider:
     1. build deterministic evidence;
     2. if the toggle is off or the provider/model is unconfigured, return A2;
     3. otherwise call the configured provider with a timeout;
     4. on timeout, connection error, invalid response, or provider-disabled response, log a safe diagnostic and return A2.
   - Support Ollama's generation API and isolate provider-specific request/response parsing behind a small client interface so the model name remains interchangeable.
   - Validate generated output and enforce a maximum response size. The service must never treat model-generated source IDs as authoritative.
   - Return structured metadata such as `generation_mode`, `generated_by`, `fallback_reason`, `entity_count`, `observation_count`, and `sources`.

3. **MCP tool**
   - Create `app/tools/summarize_tool.rb` inheriting from `ApplicationTool`.
   - Normalize parameters through the existing `ParameterNormalizer` conventions and call `SummarizerService` with `graph_mem_context.scoped_entity_ids`.
   - Keep the tool schema explicit about caps for results, observations, traversal depth, style, and source inclusion.
   - Ensure context scoping follows the existing `X-MCP-Client` and `GraphMemContext` behavior.

4. **REST endpoint**
   - Create `app/controllers/api/v1/summaries_controller.rb` with a `create` action.
   - Add `post "summarize", to: "summaries#create"` in `config/routes.rb` under `api/v1`.

5. **Tests**
   - `SummarizationConfig` specs covering AppSettings, ENV, defaults, blank values, provider selection, model selection, timeout, and token limits.
   - Operator settings request/view specs covering the Summaries section, validation, authorization, persistence, and the toggle switch.
   - Service specs covering deterministic output, active-observation filtering, trust-aware ordering, context scoping, traversal caps, provenance, validity, and contradiction-preserving evidence.
   - Service specs covering LLM success, disabled toggle, missing URL/model, unknown provider, timeout, malformed provider response, and graceful deterministic fallback.
   - Provider-client specs for Ollama request construction, model-name pass-through, bounded generation options, and response parsing.
   - Tool specs validating the normalized schema, source IDs, generation metadata, and fallback behavior.
   - Request specs for `POST /api/v1/summarize`, including both generation modes and non-sensitive fallback diagnostics.
   - Integration specs that create a small graph with duplicate, obsolete, superseded, and contradictory observations, call `summarize`, and verify that only valid active evidence is returned with sourced observation IDs.
   - Keep LLM tests offline by stubbing the provider client; include a deterministic integration path that requires no Ollama process.

6. **Documentation**
   - Add `summarize` to `docs/mcp_tools.md`.
   - Document the REST endpoint in `docs/api/rest_api_reference.md`.
   - Update `docs/app_settings_reference.md` with the Summaries settings, resolution order, defaults, and toggle semantics.
   - Create `docs/summarization.md` explaining inputs, prompt construction, context scoping, source attribution, active observation lifecycle, deterministic fallback, provider errors, and model selection.
   - Add a CHANGELOG entry under the 1.9.8 section.

## Success Criteria

- `summarize` MCP tool returns a summary and a `sources` list.
- `POST /api/v1/summarize` returns a valid JSON summary response.
- The operator can configure and save summary settings from the dedicated System Settings UI.
- With LLM summarization disabled or unconfigured, the same interfaces return deterministic extractive evidence without attempting an external call.
- With LLM summarization enabled and configured, a successful response contains an LLM summary plus the deterministic source/evidence payload.
- Provider failures degrade to deterministic output and do not expose credentials or internal exception details.
- All new code passes focused RSpec and RuboCop.
- Existing tools and endpoints remain unchanged.

## Assumptions

- The endpoint is always available as an on-demand query service; LLM synthesis is optional.
- Ollama is the default local provider, but `summary_model` is an interchangeable model name and the provider boundary permits an OpenAI-compatible endpoint later.
- The existing embedding model and vector dimensions are unchanged. Retrieval and generation use separate model configuration.
- The output contains plain summary text when available, deterministic structured evidence in all modes, and optional source attribution controlled by `include_sources`.
- Active observation lifecycle rules remain authoritative. Dream-state and garbage collection may change which observations are active or available between requests; the summarizer does not duplicate their cleanup responsibilities.
- Contradiction detection remains a review-oriented feature. Summarization may surface conflicting active observations but does not automatically supersede, obsolete, or merge them.
- The first implementation does not persist or cache generated summaries. Cache invalidation can be designed later around query, context, model, and graph revision.
