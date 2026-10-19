# GraphMem Next Step: Project Source Scan

Add a project source-scan capability that treats a target repository as the
**source of truth** for the project subgraph. It discovers the project name,
architecture, and factual observations, reconciles them with the existing
knowledge graph, and queues questionable deletions or merges for operator review.

## Context

GraphMem already has:

- A rich set of graph primitives (`create_entity`, `create_observation`,
  `create_relation`, `bulk_update`, `merge_entities`, `delete_observation`, etc.).
- A `DreamStateCompactionJob` that auto-parents orphans, deduplicates
  observations, and suggests merges/relations based on vector similarity and
  observation text.
- An `ImportExecutionStrategy` that imports a hand-crafted JSON tree into the
  graph under operator review.
- A `SummarizerService` / `SummaryGenerationClient` that can call Ollama or an
  OpenAI-compatible endpoint for text generation.

What it lacks is a way to point at a real project root on disk and say
"make the graph reflect this codebase". The dream-state suggestions are based
on vector similarity, so they can propose merges that are semantically close but
factually wrong for the scanned source. A source scan gives us ground truth to
auto-correct those suggestions.

The final phase of a normal scan is an automatic **facts-checking / validation**
pass over the existing project subtree. It treats the scan output as the source
of truth for the project and repairs mis-assigned observations, stale
relations, and wrong parents before they pollute the graph.

## Goal

Give agents and operators a single, high-level entry point to scan (or re-scan)
a project directory and keep the graph synchronized with the actual source:

1. Identify or create the `Project` root entity.
2. Extract architecture facts, typed components, and relationships from the
   source tree and key files.
3. Add missing entities/observations/relations and update existing ones.
4. Mark facts that no longer appear in the source as `obsolete`.
5. Automatically move an observation to a clear target entity when the target
   is known.
6. Obsolete observations that do not reference their entity or project and have
   no matching target, using `confidence: 1.0`.
7. Auto-delete `part_of` relations that point to the wrong project root.
8. Queue remaining destructive or ambiguous changes
   (`delete_relation`, `reparent_entity`, `delete_entity`) in a `scan_review`
   queue for operator or agent review.
9. Dismiss or flag `compaction_review` suggestions that conflict with the
   scanned source.

## Scope

- New MCP tools:
  - `scan_project(project_root, project_name, aliases, mode, dry_run, file_globs)`
    — enqueues a scan and returns a scan ID.
  - `scan_project_status(scan_id)` — returns progress, phase, counters, and a
    preview of queued `scan_review` items.
- New Solid Queue job: `ProjectScanJob` (operation type `project_scan`),
  tracked through `OperationProgress`.
- New service: `ProjectScanner` that walks the filesystem, calls an LLM for
  structured extraction, and reconciles the result with the graph.
- New review kinds for the existing `scan_review` queue:
  - `move_observation` — reassign an observation to a better-matching entity.
  - `reparent_entity` — move an entity under a different `part_of` parent.
  - `delete_relation` — remove a stale usage relation.
  - `delete_observation` — mark an observation obsolete because it does not reference its entity or project.
  - `delete_entity` — remove an entity that no longer appears in the source.
- Per-run source-ref tagging (`project_scan:<scan_id>:<phase>`) on observations
  and `MemoryRelation#properties` so validation can distinguish entities created
  by the current scan from pre-existing graph content.
- Optional REST endpoints mirroring the MCP tools under `POST /api/v1/scan`
  and `GET /api/v1/scan/:id`.
- Optional Devin skill `graph-mem-scan-project` that calls the MCP tools and
  handles preflight repository detection.

## Out of Scope (first pass)

- Fine-grained AST parsing or language-specific static analysis. The first pass
  uses file discovery + LLM extraction, similar to MegaMemory's approach.
- Automatic deletion of `Project` root entities.
- Auto-approval of destructive changes; those stay in the review queue.
- Blind auto-approval of all destructive changes; ambiguous cases and most
  relation deletions stay in the review queue. Only clearly mis-assigned
  observations and obviously wrong `part_of` parents are repaired automatically.
- Real-time scan progress is now wired into the Project Scans dashboard card via
  the existing `OperationProgress` / ActionCable channel.
- The human-guided, multi-stage skill companion is now available on the
  dashboard with deterministic, no-LLM depth scanning.

## Design Alternatives

### A. Agent-only skill

Implement the scan entirely as a Devin skill that reads files and calls existing
GraphMem tools (`create_entity`, `create_observation`, `create_relation`, etc.).

- **Pros:** No new server code; perfectly matches the "agent is the indexer"
  philosophy of MegaMemory; keeps MCP tool surface small.
- **Cons:** Only works for Devin; other clients (Cursor, Claude Code, etc.)
  cannot use it; long file-reading tasks are harder to resume/audit inside the
  agent.

### B. Many new MCP tools

Add a suite of tools such as `read_project_file`, `extract_entities`,
`apply_scan_result`, etc.

- **Pros:** Very granular control for an agent.
- **Cons:** GraphMem already has ~35 tools; a suite of scan tools would bloat
  the surface and force the client to orchestrate a long, stateful workflow.

### C. Single high-level tool + async job (recommended)

Add one (or two) high-level MCP tools that enqueue a Solid Queue job. The job
runs `ProjectScanner`, which uses the existing graph primitives internally.

- **Pros:** Portable to all MCP clients; resumable/auditable through
  `OperationProgress`; minimal tool surface; reuses the existing graph mutation
  and maintenance-report infrastructure.
- **Cons:** More server code than a pure skill; needs a prompt/JSON extraction
  contract with the LLM.

## Decision

Use **C**: a single `scan_project` MCP tool + `scan_project_status`, backed by
`ProjectScanJob` and `ProjectScanner`. Optionally expose a thin Devin skill that
wraps the MCP call for convenience.

## Implementation Outline

1. **Configuration**
   - Add `scan_*` settings to `AppSettings` following the existing
     `AppSettings → ENV → defaults` pattern:
     - `scan_summary_model` (defaults to `summary_model`)
     - `scan_summary_provider`
     - `scan_summary_timeout`
     - `scan_summary_max_tokens`
     - `scan_max_files`
     - `scan_file_globs`
     - `enable_project_scan`
     - `project_scan_roots` (defaults to `Rails.root`, `Dir.home`, `Dir.tmpdir`)
   - Add an operator settings panel section for scanning. Implemented: `project_scan_roots` is editable via **System Settings → Project Scans**.

2. **Project scan settings**
   - `enable_project_scan_validation` (default `true`) toggles the final
     validation pass.

3. **Models / enums**
   - Add `"scan_review"` to `MaintenanceReport::REPORT_TYPES`.
   - Add `"project_scan"` to `OperationProgress::OPERATION_TYPES`.
   - Add `scan_review` handling in `CompactionReviewService` signatures and
     `apply_action` for the destructive cases it supports.

4. **Core services**
   - `ProjectScanner` orchestrates file discovery, knowledge extraction,
     and reconciliation. Signature: `ProjectScanner.new(project_root:, project_name:,
     aliases:, mode:, dry_run: false, operation_progress: nil, file_globs: nil,
     scan_id: nil)`.
   - `ProjectScanValidator` is a dedicated, testable collaborator that performs
     the final facts-checking pass over the existing project subtree. It is
     called by `ProjectScanner` and can also be exercised in isolation.
   - The validator supports batched, resumable execution. The batch size is
     controlled by the `project_scan_validation_batch_size` setting (default 5).
     When the batch limit is reached, the validator pauses, persists
     `validation_state` in `OperationProgress#details`, and returns a paused
     result. The next `mode: "validate"` scan with the same `scan_id` resumes
     from the pending entity list.
   - `call` returns a result hash with counters, queued review items, and a
     `paused` flag with `remaining_entity_ids`.
   - A new `mode: "validate"` skips file discovery and runs only the
     validation pass over the existing project subtree.
   - File discovery:
     - Always read `README*`, `package.json`, `Gemfile`, `pyproject.toml`,
       `requirements*.txt`, `docker-compose*`, `Cargo.toml`, `go.mod`,
       `.devin/blueprint.yaml`, `docs/**/*.md`.
     - Optionally include source globs up to `scan_max_files`.
   - LLM prompt asks for structured JSON:
     ```json
     {
       "project": { "name": "...", "aliases": ["..."], "description": "..." },
       "architecture": [ { "entity": { "name": "...", "type": "Service", "aliases": ["..."], "description": "..." }, "relations": [ { "to": "...", "type": "part_of" } ], "observations": ["..."] } ]
     }
     ```
   - Reconciliation tags all newly created observations and relations with the
     per-run source ref `project_scan:<scan_id>:reconcile` and stores the
     run UUID in `MemoryRelation#properties["scan_id"]`. This lets the
     validation phase skip its own output.
   - Reconciliation:
     - Find/create the `Project` root by name or alias.
     - For each discovered architectural entity:
       - Match by `name` + `entity_type` via `ImportEntityResolver`.
       - If found: add missing observations, update description/aliases if scan
         is authoritative, ensure `part_of`/`depends_on` relation to parent.
       - If not found: create entity and relation.
     - For existing entities under the project subtree not present in the scan:
       - Mark their observations that are sourced from an earlier scan as
         `obsolete` with `source: "project_scan:<scan_id>:..."`.
       - Queue relation deletions and stale entity suggestions in
         `scan_review`.
     - For pending `compaction_review` rows that conflict with scan facts:
       - Dismiss merge/relationship proposals with
         `reason: "contradicted by project scan"`.
   - **Validation phase** (final automatic pass, implemented in the dedicated
     `ProjectScanValidator` service and gated by `enable_project_scan_validation`):
     - The `project_scan_validation_batch_size` setting (default `5`) controls
       how many project subtree entities are validated in one batch. `0` disables
       batching and processes the whole subtree in a single run.
     - After each batch the validator persists `validation_state`
       (`pending_entity_ids`, `processed_entity_ids`, `project_entity_id`,
       `project_root`) in the current `OperationProgress` and returns `paused`.
       The operation is paused; a subsequent `mode: "validate"` scan with the same
       `scan_id` resumes from the saved pending list.
     - Walk the existing project subtree, excluding entities created during this
       scan and the `Project` root itself.
     - Distinguish scan-sourced observations from manually-created ones using
       the `source` field. Observations produced by a prior scan run
       (`project_scan:*` or `project_scan_skill:*`, but not the current
       `scan_id`) may be repaired automatically. Observations with no scan
       source are never silently deleted; they are queued for review.
     - For each pre-existing entity, check active observations:
       - Skip observations created in the current run.
       - If the content mentions the entity, its aliases, the project root, or
         the project root aliases, it is correctly placed.
       - Use `EntitySearchStrategy` plus whole-word/phrase matching to find an
         explicit target entity in the content. Prefer non-`Project` targets
         and longer exact matches to avoid false moves.
       - Scan-sourced, single clear target: create a new active observation on
         the target and mark the original `obsolete` with `confidence: 1.0`.
       - Scan-sourced, no target: mark the observation `obsolete` with
         `confidence: 1.0` and reason `"Observation does not reference its
         entity or project and no matching target was found"`.
       - Manual/sourceless, single clear target: queue a `move_observation`
         `scan_review` item with `target_entity_id`.
       - Manual/sourceless, no target: queue a `delete_observation`
         `scan_review` item so the operator/agent can decide, preserving the
         scan conclusion in the review payload.
       - Ambiguous or multi-candidate cases: queue a `move_observation` review
         with the best target and `candidate_ids`, recording the ambiguity in
         the reason.
     - For each pre-existing entity, check outgoing relations while respecting
       ownership semantics:
       - `part_of` is an ownership edge: a `MemoryEntity` may have only one
         `part_of` parent. A `part_of` relation that points to a different
         `Project` root is corrupt and is deleted automatically.
       - `used_by`, `depends_on`, `requires`, `configured_by`, `implements`,
         `extends`, and `integrates_with` are reference/usage edges and do not
         assert ownership. These are only queued as `delete_relation` review
         items when the target is not supported by the scan context.
       - Skip relations created in the current run.

5. **Job: `ProjectScanJob`**
   - `queue_as :default`.
   - Create an `OperationProgress` record with type `project_scan`.
   - Call `ProjectScanner` and report progress per phase.
   - On success, call `CompactionReviewService.seed_report` with any
     `scan_review` items.
   - On failure, mark `OperationProgress` as failed and re-raise.

6. **MCP tools**
   - `ScanProjectTool` — accepts `project_root`, `project_name`, `aliases`,
     `mode` (`initial` / `rescan` / `validate`), `dry_run`, `file_globs`,
     enqueues `ProjectScanJob`, returns `{ scan_id, operation_id, status }`.
     `validate` mode skips discovery/extraction and runs only the validation
     pass over the existing project subtree.
   - `ScanProjectStatusTool` — accepts `scan_id` and returns the
     `OperationProgress` snapshot plus any seeded `scan_review` items.

7. **REST endpoints (optional first pass)**
   - `POST /api/v1/scan` and `GET /api/v1/scan/:id`.

8. **Operator UI**
   - Implemented: a "Project Scans" dashboard card lists recent scans with
     project name, status, mode, phase, and progress.
   - Implemented: a trigger form on the card starts a new scan.
   - Implemented: active scan rows subscribe to `OperationProgressChannel` and
     update status, phase, percentage, and progress bar live via ActionCable.
   - Implemented: a "Project Scan Skill Companion" dashboard card triggers and
     controls the human-guided multi-stage scan, showing the depth stepper,
     current depth, live progress, Continue/Stop actions, and reusing the
     `OperationProgressChannel` for updates.

9. **Summarization fallback**
   - If `SummarizationConfig.llm_usable?` is false or the LLM call fails,
     `ProjectScanner` switches to a deterministic fallback that still:
     - creates/updates the `Project` root from `README` and directory name,
     - creates `Configuration` entities for manifest files,
     - creates `Component` entities for top-level directories,
     - marks the result with `fallback: true` and a `fallback_reason`.

10. **Devin-local multi-stage skill**
   - Implemented: `.devin/skills/project_scan/SKILL.md` for the no-LLM / human-guided case.
   - Implemented: server-side `ProjectScanSkill` service and `ProjectScanSkillJob`
     that walk the project in progressive depths
     (`birds_eye`, `architecture`, `usage`, `ui`, `tests_and_docs`),
     using GraphMem models directly to persist `Project`, `Component`, `Route`,
     `Model`, `Service`, `Configuration`, `TestCase`, and `Documentation` entities,
     observations, and `part_of` relations. The job pauses after each depth and
     waits for the operator to continue from the dashboard, so it works without an
     LLM.

11. **Tests**
    - Unit specs for `ProjectScanner` with a fixture repo and a stubbed LLM
      client, including the deterministic fallback path.
    - Job specs verifying progress reporting and review-queue seeding.
    - Tool specs for parameter validation and status lookup.
    - Update registration and REPORT_TYPES specs to include the new tools/types.
    - RuboCop lint.

## Success Criteria

- `scan_project` returns a scan ID and starts an async job.
- `scan_project_status` returns progress and the final report.
- The scan creates or updates a `Project` root and its architectural entities,
  observations, and relations.
- Obsolete facts are marked with the run-specific
  `source: "project_scan:<scan_id>:<phase>"` and a reason.
- Clearly mis-assigned observations and wrong `part_of` parents are repaired
  automatically; ambiguous or risky destructive changes are queued in
  `scan_review` for operator/agent review.
- Conflicting dream-state compaction suggestions can be dismissed during the
  scan.
- All new code passes RuboCop and focused RSpec tests.
- No existing tools are broken.
- When LLM summarization is unavailable, `ProjectScanner` falls back to a
  deterministic, file-metadata-based extraction.
- The Devin-local `project_scan` skill can perform a multi-stage, human-guided
  scan without an LLM.
- The dashboard Project Scan Skill Companion lets operators start, continue, and
  stop a guided, no-LLM scan through the `birds_eye` → `architecture` → `usage` →
  `ui` → `tests_and_docs` depths with live progress updates.

## Assumptions

- The GraphMem server process has filesystem access to `project_root`.
- The configured summarization/LLM endpoint is used for scan extraction when
  enabled; when disabled, the deterministic fallback or the Devin-local skill
  takes over.
- Scan output is treated as authoritative for the project it scanned, but
  destructive actions are still reviewed.
- The first pass does not attempt full AST parsing; it relies on file content
  and LLM extraction.
