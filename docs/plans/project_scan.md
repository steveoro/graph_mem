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

## Goal

Give agents and operators a single, high-level entry point to scan (or re-scan)
a project directory and keep the graph synchronized with the actual source:

1. Identify or create the `Project` root entity.
2. Extract architecture facts, typed components, and relationships from the
   source tree and key files.
3. Add missing entities/observations/relations and update existing ones.
4. Mark facts that no longer appear in the source as `obsolete`.
5. Queue destructive changes (relation deletions, merge rejections, entity
   deletions) in a `scan_review` queue for operator approval.
6. Dismiss or flag `compaction_review` suggestions that conflict with the
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
- New maintenance report type: `scan_review` (handled by the existing
  `apply_maintenance_review` / `dismiss_maintenance_review` tools once the
  appropriate signatures are registered).
- Optional REST endpoints mirroring the MCP tools under `POST /api/v1/scan`
  and `GET /api/v1/scan/:id`.
- Optional Devin skill `graph-mem-scan-project` that calls the MCP tools and
  handles preflight repository detection.

## Out of Scope (first pass)

- Fine-grained AST parsing or language-specific static analysis. The first pass
  uses file discovery + LLM extraction, similar to MegaMemory's approach.
- Automatic deletion of `Project` root entities.
- Auto-approval of destructive changes; those stay in the review queue.
- Streaming/real-time UI for scan progress beyond the existing
  `OperationProgress` / ActionCable infrastructure.

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
   - Add an operator settings panel section for scanning.

2. **Models / enums**
   - Add `"scan_review"` to `MaintenanceReport::REPORT_TYPES`.
   - Add `"project_scan"` to `OperationProgress::OPERATION_TYPES`.
   - Add `scan_review` handling in `CompactionReviewService` signatures and
     `apply_action` for the destructive cases it supports.

3. **Core service: `ProjectScanner`**
   - `ProjectScanner.new(project_root:, project_name:, aliases:, mode:, dry_run: false,
     operation_progress: nil, file_globs: nil)`
   - `call` returns a result hash with counters and queued review items.
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
   - Reconciliation:
     - Find/create the `Project` root by name or alias.
     - For each discovered architectural entity:
       - Match by `name` + `entity_type` via `ImportEntityResolver`.
       - If found: add missing observations, update description/aliases if scan
         is authoritative, ensure `part_of`/`depends_on` relation to parent.
       - If not found: create entity and relation.
     - For existing entities under the project subtree not present in the scan:
       - Mark their observations that are sourced from an earlier scan as
         `obsolete` with `source: "project_scan"`.
       - Queue relation deletions and stale entity suggestions in
         `scan_review`.
     - For pending `compaction_review` rows that conflict with scan facts:
       - Dismiss merge/relationship proposals with
         `reason: "contradicted by project scan"`.

4. **Job: `ProjectScanJob`**
   - `queue_as :default`.
   - Create an `OperationProgress` record with type `project_scan`.
   - Call `ProjectScanner` and report progress per phase.
   - On success, call `CompactionReviewService.seed_report` with any
     `scan_review` items.
   - On failure, mark `OperationProgress` as failed and re-raise.

5. **MCP tools**
   - `ScanProjectTool` — accepts `project_root`, `project_name`, `aliases`,
     `mode` (`initial` / `rescan` / `validate`), `dry_run`, `file_globs`,
     enqueues `ProjectScanJob`, returns `{ scan_id, operation_id, status }`.
   - `ScanProjectStatusTool` — accepts `scan_id` and returns the
     `OperationProgress` snapshot plus any seeded `scan_review` items.

6. **REST endpoints (optional first pass)**
   - `POST /api/v1/scan` and `GET /api/v1/scan/:id`.

7. **Operator UI (optional)**
   - Add a "Project Scans" card to the operator dashboard that lists recent
     `OperationProgress` entries of type `project_scan`.

8. **Summarization fallback**
   - If `SummarizationConfig.llm_usable?` is false or the LLM call fails,
     `ProjectScanner` switches to a deterministic fallback that still:
     - creates/updates the `Project` root from `README` and directory name,
     - creates `Configuration` entities for manifest files,
     - creates `Component` entities for top-level directories,
     - marks the result with `fallback: true` and a `fallback_reason`.

9. **Devin-local multi-stage skill**
   - Add `.devin/skills/project_scan/SKILL.md` for the no-LLM / human-guided case.
   - The skill walks the project in progressive depths
     (`birds_eye`, `architecture`, `usage`, `ui`, `tests_and_docs`),
     uses existing GraphMem MCP tools (`create_entity`, `create_observation`,
     `create_relation`) to persist facts, and asks the user whether to continue
     after each depth. It records progress as an observation on the project entity
     so scans can resume across sessions.

10. **Tests**
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
- Obsolete facts are marked with `source: "project_scan"` and a reason.
- Destructive changes are queued in `scan_review`, not applied automatically.
- Conflicting dream-state compaction suggestions can be dismissed during the
  scan.
- All new code passes RuboCop and focused RSpec tests.
- No existing tools are broken.
- When LLM summarization is unavailable, `ProjectScanner` falls back to a
  deterministic, file-metadata-based extraction.
- The Devin-local `project_scan` skill can perform a multi-stage, human-guided
  scan without an LLM.

## Assumptions

- The GraphMem server process has filesystem access to `project_root`.
- The configured summarization/LLM endpoint is used for scan extraction when
  enabled; when disabled, the deterministic fallback or the Devin-local skill
  takes over.
- Scan output is treated as authoritative for the project it scanned, but
  destructive actions are still reviewed.
- The first pass does not attempt full AST parsing; it relies on file content
  and LLM extraction.
