# Changelog

All notable changes to GraphMem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.54.2] - 2026-10-25

Fixes from the Claude Code client check (PR-3 step 5).

### Added
- MCP error envelopes carry an optional `code` naming the exact reason. `scan_project` refusals use the `ScanRootPolicy` codes (`not_mounted`, `denied`, `outside_filter`, …, plus `invalid_file_globs`), each with its own `next_move`.
- `graph_delete` deletes a `Project` root on the maintenance profile once no entity is scoped to it, and clears the client contexts that pointed at it. The default profile still refuses (`project_delete_needs_maintenance`); a Project with members is refused everywhere (`project_has_members`).

### Fixed
- `scan_project` (MCP) and `POST /api/v1/scan` record the scan as pending before replying, so `scan_project_status` / `GET /api/v1/scan/:id` find the `scan_id` straight away instead of answering "not found" until a worker starts the job. All three entry points share `ProjectScanJob.enqueue`.
- The stdio runner returns tool errors as the same JSON envelope as HTTP, instead of plain `Error:` text.

### Documentation
- `memory_graph` needs `include_relations=true` to return neighbours; `memory_entities` values must be percent-encoded.
- `docs/protocol_compat.md` describes the tool error envelope, its `code` and the stdio change.

## [1.54.1] - 2026-10-24

### Added
- MCP protocol compatibility cases in `spec/fixtures/mcp/handshakes/` (16 stdio, 27 Streamable HTTP): version negotiation, the 2026-07-28 fallback, `MCP-Protocol-Version`, session errors, id rules, body shape and size. Each case records graph_mem's answer and the v2.0.0 reference servers' (Memory, Everything), with a reason for every difference.
- `spec/requests/mcp_protocol_compat_spec.rb` asserts graph_mem's answers in the normal suite: HTTP through the Rails app, stdio through runner subprocesses. Wire-level only, so it carries over to the official `mcp` gem migration.
- `script/mcp_compat/compare.rb` replays the cases against running servers (graph_mem, the reference servers, and the official Ruby SDK 1.8.1 as an informational column) and fails on an unexpected difference.
- `script/mcp_compat/clients.sh` connects the Ruby SDK clients 1.8.0 and 1.8.1 and the TS client 2.3.1 to graph_mem (12 rows).
- `docs/protocol_compat.md`: supported protocol versions, how 2026-07-28 clients fall back, the client matrix, the Claude Code check results and the reference comparison.

## [1.54.0] - 2026-10-24

### Added
- Project scans in containers: the host user's home is mounted read-only at the same path (`${HOME}:${HOME}:ro`, override with `GRAPH_MEM_SCAN_HOME`); `GRAPH_MEM_SCAN_ROOTS` / `GRAPH_MEM_SCANS`; Settings › Project scans shows mounts (read-only/read-write), a runtime subfolder filter (default "Projects"), the always-blocked list and a path checker. `docs/container_scan_mounts.md` (Linux Docker; rootless Podman best-effort; SELinux, UID).
- MCP transport limits: a 4 MiB request body cap (`GRAPH_MEM_MCP_MAX_REQUEST_BYTES`, 413), a 256-session cap on Streamable HTTP (`GRAPH_MEM_MCP_MAX_SESSIONS`: at the cap the least recently active idle session is evicted, 503 only when all are busy), 409 on a second GET stream for one session, and the JSON-RPC `id` on 400/404 errors. Documented in `docs/mcp_access_control.md`.
- `graph_write` `on_duplicate: "skip"` with a `skipped` list (`"reject"`, the default, keeps the previous behaviour). Observations and relations that name a skipped *similar* entity are skipped too (`depends_on_skipped`), so the rest of the batch still writes.

### Changed
- `project_scan_roots` is replaced by `project_scan_subfolders` (relative to the scan root, editable at runtime); `PROJECT_SCAN_ROOTS` (never effective) is removed. Native installs default to home + "Projects", so scanning outside `~/Projects` (e.g. `/tmp/foo`) needs `GRAPH_MEM_SCAN_ROOTS` (e.g. `/tmp/foo`) plus a blank subfolder filter, since the filter applies under every scan root.
- fast-mcp bumped to steveoro v1.8.0 (handshake negotiation up to 2025-11-25, strict JSON-RPC, per-session subscriptions). **Legacy `/mcp/sse` clients:** every `/mcp/messages` POST must carry the server-issued `sessionId` (400 without it, 404 for an unknown one), and a legacy stream with no POST for 30 minutes is closed (fast-mcp's default `sse_idle_timeout`).
- Streamable HTTP and stdio negotiate 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25; any other requested version gets 2025-11-25. 2026-07-28 clients fall back via the `server/discover` probe.
- `MCP-Protocol-Version` is validated on in-session requests (400 for unsupported values).
- CORS reflects allowed origins only (`Vary: Origin`); `MCP-Protocol-Version` is allowed and exposed.
- `initialize` advertises `resources.subscribe`/`listChanged` and `tools.listChanged` as false (graph_mem never sent them).
- MCP `initialize` now carries per-profile instructions (texts from 1.53.0, `GraphMem::McpInstructions`).
- **Behaviour change:** an exact duplicate entity name in `graph_write` now returns a structured `possible_duplicate` (`reason: "same_name"`) instead of a validation error.

### Security
- One `ScanRootPolicy` for the dashboard, `POST /api/v1/scan`, MCP `scan_project` and job start (previously the API and MCP accepted any directory). Hidden folders can't be scan roots or project folders, nor can `snap`/`Library`/`AppData`/`Maildir`/`Mail` directly under the scan root; a home folder (yours, `/root`, `/home/*`, `/Users/*`) can't be scanned as one project, and `/home` / `/Users` can't be scan roots. Inside a project, `.git`, `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, `.password-store` and secret files (`.env*`, keys, certificates, `credentials*`, `master.key`, `*.tfstate`, shell history, …; case-insensitive) are never read, even via explicit `file_globs`. `..`/absolute `file_globs` are rejected; symlinks resolving outside the root are skipped. A filter whose entries are all invalid allows nothing (only a blank filter means the whole root).
- `/api/v1` CSRF matrix specs for refused bearer writes with no session: a junk token gets 401, a valid token from a disallowed IP gets 403 (behaviour since 1.53.0).
- Import review page: its inline script moved to a Stimulus controller, ready for CSP enforcement.
- The graph UI's data_exchange JSON writes now require the CSRF token (the graph UI already sent it).
- `allow_guest` appends instead of replacing.
- Docs: the production 503 names only `OPERATOR_PASSWORD`; `GRAPH_MEM_MCP_ALLOWED_IPS` defaults to loopback + private ranges.

### Fixed
- Scanner applied `max_files` before sorting (non-deterministic file set).
- A JSON-array POST body was returned as the raw HTTP response (status/headers/body chosen by the caller); non-object bodies now get 400 -32600.
- The stdio runner wrote Rails/FastMcp log lines to stdout, breaking strict stdio clients (e.g. the Ruby MCP SDK); logs now go to stderr.
- Duplicate preflight now runs under the write lock (batch and single-op paths); concurrent duplicates return a structured response.
- Delete counts reflect rows actually deleted.
- A request with `"id": null` is refused (400 -32600) and never executed; id-less request methods are no longer executed behind a 202.
- An invalid UTF-8 object key in a POST body returns 400 -32700 instead of 500.

## [1.53.0] - 2026-10-23

### Added
- `graph_write` and `graph_edit` schemas now advertise the provenance/staleness fields the services already accepted (`source`, `confidence`, `valid_from`, `valid_until`, `tags`, `perspective`; relation `weight`/`properties`).
- `graph_edit` `update_entity` and `graph_write` `create_entity` take `aliases` as an array of strings: each is stripped, blanks are dropped, duplicates are removed case-insensitively (first spelling kept) and the list is stored `|`-joined. A legacy pipe-separated string is still accepted; an alias containing `|`, or an item that isn't a string or number, is rejected. In `update_entity`, `[]` or `null` clears the aliases.

### Changed
- **Agent-facing text is situation-first** (agent-rules AR-T): the skill description, the `search` / `graph_write` / `graph_edit` description openers, the `orient` / `recall` / `persist` prompts and the `next_move` hints now say *when* to recall (task start, before a convention, before first editing a file or component) and *when* to persist (corrections, preferences, locations, verified fixes), as one general rule per observation, superseding old rules with `graph_edit` instead of appending.
- **Skill follows the Agent Skills spec**: a "what, then when" description, `license: LGPL-3.0-or-later`, `compatibility` and a `metadata.graph-mem-version` kept equal to the app version; the recall/persist workflow, a Gotchas section and call templates live in `SKILL.md`, with tool details in `references/tools.md` and scans/dream-state/review queues in `references/maintenance.md`.
- **Memory homes**: prompts, the skill and its templates name one place per kind of memory: `<Project> Conventions` (BestPractice, part_of the Project), the global `User Preferences` (Preference; create it with the context cleared), and the entity an environment fact describes.
- New `GraphMem::McpInstructions.for(profile)` holds the per-profile MCP server `instructions` text (readonly omits the persist sentence). Not sent yet: it is wired in once graph_mem runs on fast-mcp 1.8.0.
- `rank_observations`' `next_move` no longer names write tools, which the readonly profile lacks.
- `docs/rules/README.md` has one install recipe for every agent: the skill in `.agents/skills/` (plus `.claude/skills/` for Claude Code) and a 10-line snippet in `AGENTS.md`. The graph_mem reference text moved into the skill's `references/`.

### Fixed
- Agent-facing hints no longer point at nonexistent operations (`graph_edit move_to_parent`, `graph_write update_entity`) or at the maintenance-only `dream_state_status` for default-profile sessions.
- Every agent now loads the repo's rules from one root `AGENTS.md` (Cursor, Codex, Copilot, Devin; Claude Code through `@AGENTS.md` in `CLAUDE.md`). The per-tool rule files in `.cursor/rules/` and `.devin/rules/` are removed; Cursor had been ignoring the `.md` ones.
- Agents in this repo (Cursor, Codex, Copilot, Devin via `.agents/skills/`; Claude Code via `.claude/skills/`) now discover the graph_mem skills; the stale Cursor skill shim is removed; `project_scan` moves to `skills/project-scan/` (renamed to match its skill name, linked from `.agents/skills/` and `.claude/skills/`, and run only on request).

### Security
- **UI-0 / F1 — XSS: replace all `innerHTML` template-literal sinks** in the graph UI with safe DOM construction. Six sinks fixed: `graph/tooltip.js` (label/type/aliases), `graph/context_menu.js` (node header, labels, edge info), `graph/observation_renderer.js` (`renderObservationCards`, `renderDuplicateWarning`), `graph/drag_drop_manager.js` (action-menu header, relation-form labels), `graph/modal_manager.js` (modal title + content node), `controllers/compaction_review_controller.js` (entity-search select options). New `app/javascript/lib/dom.js` provides `el()`, `text()`, `br()`, `escapeHtml()` helpers; pinned in importmap under `lib/`. Guarded by `spec/javascript_sinks_spec.rb` (static grep — any new `innerHTML = \`...\${` line fails CI) and `spec/system/escaping_spec.rb` (runtime: five examples covering the tooltip, context menu, observation/modal, drag-drop menu and compaction-review sinks with an `<img src=x data-probe=1>` payload via Selenium headless Chrome).
- **UI-0 / F2 — API authentication**: all `/api/v1/*` endpoints now require either (a) an active operator browser session or (b) a Bearer token matching `GRAPH_MEM_MCP_TOKEN` from an IP allowed by `McpAccessPolicy`. `ApiAuthentication` concern replaces the previous `skip_before_action :authenticate_operator!` in `Api::V1::BaseController`. Session expiry (idle 24 h, absolute 7 d) is enforced in both the browser and API paths.
- **UI-0 / F3 — Login hardening**: `Operator::SessionsController#create` calls `reset_session` before setting keys (session-fixation protection), stores `session[:role]`, `session[:user]`, `session[:signed_in_at]`, `session[:last_seen_at]` (legacy `session[:operator_signed_in]` still accepted for backward compat). Rate-limited to 10 POSTs per 3 minutes via `rate_limit`. Production deployments using the fallback `operator`/`changeme` credentials receive a `503 Service Unavailable` on GET /operator/login instead of the login form.
- **UI-0 / F4 — ActionCable authentication**: `ApplicationCable::Connection` now decrypts the session cookie and rejects connections that do not carry `role: "operator"` (or the legacy `operator_signed_in: true` key). Unauthenticated and non-operator WebSocket upgrade attempts are rejected.
- **UI-0 — CSP report-only**: `config/initializers/content_security_policy.rb` fully enabled in report-only mode (`Content-Security-Policy-Report-Only`). `script-src 'self'` + per-request nonce (via `content_security_policy_nonce_generator`/`content_security_policy_nonce_directives`); `style-src 'self' 'unsafe-inline'` (pending the asset-pipeline nonce work in UI-1). Reports accepted at `POST /csp-reports` (rate-limited, unauthenticated, logged at warn level).
- **UI-0 — Rswag access control**: Swagger UI at `/api-docs` is now gated behind `OperatorSessionConstraint` — non-operator requests see a 404 (route constraint not matched) instead of the full API documentation.

## [1.52.1] - 2026-10-19
- **`StructureDumpGuard.canonical?` tolerates a split-line trigger terminator**: a trigger created without the query-log tag (e.g. test env, where `query_log_tags_enabled` is off) dumps as `...)))` then `*/;;` on its own line — the previous `*/;;` check demanded a literal space, so a fresh dump of a healthy tag-less DB reported non-canonical. Now matches with any whitespace before `*/;;`.
- **`embeddings:add_indexes` is idempotent and repairs drift**: `EmbeddingIndexManager.add_indexes!` no longer dies with `Duplicate key name` on an already-indexed DB — `ADD VECTOR INDEX` is skipped per table when `idx_*_embedding` exists (or warns when the column is indexed under a different name), `MODIFY ... NOT NULL DEFAULT` runs only for nullable columns and is never applied to a NOT NULL column carrying an index (a default/dims drift there is reported as a warning with the `drop_indexes` + `add_indexes` repair path — the ALTER would have to rebuild the vector index), and `EmbeddingVectorTriggerManager.install!` is now convergent: it re-creates only missing or body-drifted triggers and reports `{installed, unchanged, skipped}`, leaving healthy DBs untouched (a trigger rebuild is DROP+CREATE, two auto-committed statements — skipping it on correct triggers removes the non-atomic window on re-runs). The result gains `converged`/`performed`/`skipped`/`warnings`; the rake task prints warnings and exits non-zero when `converged: false`, and the operator action flashes them as an alert. New migration `EnsureEmbeddingInsertTriggers` calls `install!` at migrate time — fixing the root drift (`AddEmbeddingInsertTriggers` only creates triggers when the columns are already NOT NULL, so a different migrate order could leave indexes but no triggers). Re-running the task is now the repair path when `db:schema:dump` warns "dump came from a DB without the embedding indexes/triggers".

## [1.52.0] - 2026-10-14
- **D2 — god-node reporting in `get_graph_stats`**: responses gain `god_nodes` (up to 10 entities whose degree — incoming + outgoing relations — exceeds the fixed threshold `> 100`, shaped `{ id, name, entity_type, relation_count }`) and `god_node_count` (the full qualifying total, uncapped). Degree aggregation is shared with `most_connected`; `GET /api/v1/maintenance/stats` reports the same shape and Swagger documents both fields.
- **C5 — `citation_check` on LLM summaries**: `summarize` parses `observation_id=N` / `[observation_id=N]` tokens out of the generated text (plural `observation_ids=` and comma-separated lists like `[observation_id=12, 13]` credit every id — a comma-continued number only counts when list-shaped: followed by `,`, `]`/`)`, or line end, so prose like `observation_id=7, 2026 plan` or `7, 2026.` never credits 2026) and reports `cited_ids`, `unknown_ids` (cited but not in the evidence set), `uncited_evidence_ids`, and `possible_hallucination` under `citation_check`. Diagnostics only — the text is never rewritten or rejected on unknown citations. Deterministic summaries omit the field entirely (they self-cite by construction).
- **r2/r3 — review-queue concurrency hardening**: `CompactionReviewService.apply` now locks the row (`with_lock` + reload + status re-check) so an apply racing a dismiss/rescan edit can never mutate a settled row; stale-memory seeding performs the candidate discovery itself as a locking read (`FOR UPDATE`, deterministic id order) — a concurrent apply/dismiss can no longer strike through a read-then-lock window, and rows settled mid-merge are re-checked `active?` so they are never merged into or retired. The `FOR UPDATE` is narrowed to a REAL index range: `maintenance_report_rows` gains a virtual generated `stale_entity_id` column (`COALESCE(JSON_VALUE(edited_payload), JSON_VALUE(payload))` — `effective_payload` semantics, so operator re-targets are honored) with index `index_mrr_stale_candidates(stale_entity_id, report_type)`, which the candidate read forces — under REPEATABLE-READ + `innodb_snapshot_isolation` a seed X-locks only the rows it can absorb into; a writer on another entity's stale row no longer waits on the seed's locks (a whole-queue `FOR UPDATE` scanned and X-locked every stale row because `JSON_VALUE` predicates filter but don't narrow the lock). `status` is deliberately NOT in the index: an apply's `update!(status:)` would move the row's index entry into a gap a waiting seed has next-key locked, and InnoDB resolves that by deadlocking the seed (errno 1213) — keeping the index on the immutable dimension means the seed just waits for the apply's record lock, then sees the settled row. `seed_report`'s transaction retries transient lock failures — ER_CHECKREAD (errno 1020 — statement-level abort under snapshot isolation) and `ActiveRecord::Deadlocked` (1213) — up to three attempts with light backoff around the whole transaction (the read view is fixed at the first consistent read). Absorption respects operator edits: new observation ids merge into `edited_payload` when present, never overwrite the original payload under it. The generated column yields NULL for non-numeric or oversized (19+ digit) entity ids and floors positive decimals to match Ruby's `to_i`. NOTE for dev databases that ran the r4 revision of `20261016120000`: the migration was edited in place — re-apply it with `bin/rails db:migrate:redo VERSION=20261016120000` (its by-name `down` makes the redo safe).
- **r2 — perspective hard filter fix + regression**: `search`/`subgraph` perspective filtering genuinely applies to both the obs-text match SQL and the vector observation channel (entity payload observations are filtered too). Note the documented distinction: perspective filters OBSERVATIONS — an entity can still surface via a name/type/alias match while carrying no in-perspective observations.
- **r2 — `caused_by` seed migration rollback narrowed**: `down` deletes only mappings whose canonical type is `caused_by`, preserving operator remaps like `triggered_by → depends_on`.
- **r2 — negation coverage**: the open-claim detector covers "not open", "not open anymore/any more", "isn't/wasn't/never was open" and `no longer|never was|isn't|wasn't` + unresolved/pending/blocked/outstanding/broken — while a bare `not` before other markers no longer suppresses the whole observation ("issue still open, deploy not blocked" still flags).
- **`get_callers` is permanently dropped**: callers use `traverse_graph` with `direction: "incoming"`, `relation_types: ["calls"]` — documented in `docs/mcp_tools.md`.
- **Service split**: `CompactionReviewService`'s apply half moved to `CompactionReviewApplier` — both files back under the 500-line rule, public API unchanged.
- **First-time import performance**: observation de-duplication plucks active contents ONCE per entity (cached) — entities created by the run itself never touch the detector, and pre-existing empty entities degrade to exact matching, so a first import issues zero detector queries instead of ~3 per observation; per-node `memory_observations_count` recount pairs are replaced by one grouped reconcile inside the same transaction; the relations pass preloads endpoint project/type once (no per-edge query) and matches existing triples with a composite `(from_entity_id, to_entity_id, relation_type) IN (...)` row-value clause on the unique index; `ImportMatchingStrategy` shares the same per-entity content cache; `GraphifyImporter.build_stats` walks `@edges` once. Multi-pass semantics, idempotence, semantic dedup on re-import, deferred embeddings, and transaction boundaries are unchanged.
- **structure.sql dump guard**: `db:schema:dump` now snapshots the file pre-dump and `StructureDumpGuard` restores it when a fresh dump comes from a DB missing the indexed embedding schema (NOT NULL columns, VECTOR KEYs, insert triggers) — an unindexed machine can no longer silently degrade the committed structure.sql. When the degraded dump carries schema_migrations versions the snapshot lacks (a new migration ran on that DB), the guard refuses to restore — the snapshot is written back and the task aborts non-zero so new DDL is never silently discarded; bypass with `GRAPH_MEM_ALLOW_UNINDEXED_DUMP=1` when indexes were dropped intentionally. `StructureDumpCleaner` also strips `AUTO_INCREMENT=N` counters — they reflect whichever local DB produced the dump and are pure diff noise (schema:load starts tables at 1; prod `db:prepare` migrates an existing DB and never loads the file).

## [1.51.0] - 2026-10-12
- **C3a — observation `perspective` (world/experience split, Hindsight port)**: `memory_observations` gains a nullable `perspective` varchar(16) — `world` for external facts, `experience` for work-log entries. CLOSED two-value vocabulary (hard inclusion validation — deliberately NOT the soft `suggestion()` pattern used for entity/relation types, since the filter semantics are binary). Writable via `graph_write` (observation attrs), `create_observation`, `graph_edit`/`update_observation`; serialized on every observation payload; NOT an `EMBEDDING_FIELDS` member (re-typing never re-embeds). `search` gains a `perspective` hard filter — `world` surfaces only factual observations, `experience` only work-log entries, omitted returns both (applies to obs-text matching, surfaced payloads, and the vector obs channel). Code-structure imports stamp `world` automatically (payload value wins, custom producers stay NULL — same conservative rule as the migration backfill, which types only `graphify`/`rails_ast_extractor` obs).
- **C3b — `caused_by` relation type (approved option A)**: canonical causal edge reads BACKWARD — `Effect -[caused_by]-> Cause`. Variants: `resulted_from`, `triggered_by`, `consequence_of`. Forward verbs (`led_to`, `resulted_in`, `triggered`) are deliberately NOT variants — mapping them would store the edge inverted (same trap as `contains`/`part_of`); they stay usable as literal types.
- **C4 — stale-memory revalidation (`StaleMemoryScanJob`)**: periodic scan (dev hourly, prod 4:30am) behind `Settings → enable_stale_memory_scan`, seeding `stale_memory` rows on the compaction review queue. DESIGN RULE (documented in code): staleness is DISCOVERY-ANCHORED, never time-anchored — there is no age-based detector on purpose; an old-but-undisputed fact (a to-do on a bug that was never addressed) keeps surfacing. Detectors: `valid_until` elapsed (the expiry the writer chose), `addressed_by_newer_edge` (Issue/Task obs still claiming open + a solves/replaces/resolves/fixes edge written AFTER the obs = discovered already addressed during traversal), `unrooted_after_rescan` (importer-stamped obs on entities no longer reachable from any Project tree), plus bounded vector contradiction detection (candidates limited to obs newer than the last scan's watermark — a cost bound, not a staleness criterion). Apply marks flagged observations obsolete via `mark_obsolete!` (keeps the audit trail); re-runs dedupe on entity+sorted-observation signature.
- **r19 fix — `conflict_hint` movers**: the `(moving: …)` list is now derived from the backfill's own apply batch (`membership` map passed through on the mid-apply re-raise, DB error kept as `cause`) — scope>0 lists batch rows targeting the clash scope, scope 0 lists stamped-but-unrooted rows. Without batch context the list narrows to unbacked stamps only, and never names same-name rows correctly rooted in other projects (a bare `name LIKE` scan misled operators and could crowd out the real mover).
## [1.50.0] - 2026-10-11
- Follow-up cleanup PR: service split + review-queue UX + accumulated nits.
- Service split: `RailsAstExtractor` constant indexing walks moved to `RailsAstExtractor::ConstIndex` and DSL/route emitters to `RailsAstExtractor::DslEmitters`; `GraphifyImporter`'s headless-import decision + reference-stub helpers extracted to `GraphifyImporter::Matching` (extended in — `GraphifyImporter.seed_ambiguous_relations`/`headless_decisions` keep their call sites). All files back under the 500-line rule.
- Review queue UX: kind filter tabs with counts scoped to the current status filter (status counts likewise respect the kind filter); `q` search over row payload values (JSON keys no longer match); "Apply selected" bulk action (iterates `apply`, skips non-actionable rows, reports per-row failures in the flash); per-row cards render inside `turbo_frame_tag` and row actions answer with turbo streams — the acted card is replaced/removed in place and the flash updates, no scroll reset and no stale flash.
- `delete_entity` rows now show a children warning split into "N children queued for deletion too" vs "N children will be left parentless" — applying a row NEVER cascades into child entities, by (possibly temporary) design choice documented in code.
- Extractor fixes from PR #101 review: restated-path resolution restricted to multi-segment heads matched against any enclosing segment (`module Admin; class Admin` → `Admin::Admin`, `module A; module B; class A::X` → `A::X`); absolute names (`::User`, `class ::TopLevel`) resolve top-level only; `source_type:` on through associations wins over `source:`; mixin stubs emit `Module` type; `class << self` defs emit `Owner.self.name` Method nodes (`def self.name` receiver form emits `Owner.name` — different labels by approved design choice).
- `module` declarations emit `entity_type: "Module"` everywhere (index, parents, edge targets, DSL owners, stubs) instead of duplicating a `Class:` node; on import EXECUTION a stored Class↔Module collision retypes only for unclaimed reference stubs or entities already inside the imported project's subtree (v1.49 leftovers) — match/preview stays read-only. Project-scoped names make true cross-repo same-name collisions impossible, so the declared-name skip is narrowed, not gone: two declarations of the same NAME coexist under their own scopes, but a foreign Class↔Module DECLARATION of an already-declared constant still skips (retype only reaches reference stubs and own-subtree leftovers).
- **Project-scoped entity names** (Steve-approved design option b): `memory_entities` gains a nullable `project_id` FK to the owning Project root plus a generated `project_scope` column (`COALESCE(project_id, 0)`) backing `UNIQUE(project_scope, name)` — entity names are unique within a project scope, globally only in the shared `project_id IS NULL` namespace. Import execution scopes every match/create to the imported project's scope (the first Project-typed tree root claims it); `ImportEntityResolver` resolves `name`/`entity_id` args inside the client's context-project scope first (matching tools get `project_id` on every serialized entity). Reference stubs stay global (`project_id NULL`): a repo that only *references* a foreign constant parks it in the shared namespace, and the first repo that *declares* it claims it into its project via a `part_of` replace + `ProjectMembership.sync!`; two or more declaring projects leave the stub global and queue `AMBIGUOUS`/`repoint` proposals. `graph_mem:backfill_project_ids` rewrites existing rows' `project_id` from `part_of` ancestry (`dry_run` supported, migration reversible — rolling back with a duplicate global name left fails `down` non-atomically since MariaDB DDL auto-commits, so dedupe global names before rolling back; a re-run `up` repairs); the backfill walk skips stub-tagged edges and does not descend into nested Projects (each Project scope is its own), and compute+apply run under a shared advisory lock (`GET_LOCK graph_mem.project_membership`, also taken by `ProjectMembership.reassign!` and every part_of writer that routes through it) so a live re-parent can't be stamped under its old project. The lock name is `graph_mem.project_membership:<database>` (DB-namespaced), acquired by every outermost membership entry point — importer execute, node ops move/merge/delete, `graph_write` create ops, `graph_delete` call/execute_one, compaction-review deletes — BEFORE opening its transaction (mid-transaction `GET_LOCK` deadlocks); MCP writes wait up to 60 s on it, and a timeout raises the retryable `LockTimeout` (mapped to `OperationFailed` concurrency — "retry shortly", never a name-conflict message). Lock statements (`GET_LOCK`/`RELEASE_LOCK`, membership and embeddings locks alike) bypass the ActiveRecord query cache — a cached release never reaches MariaDB and would leave the pooled session holding the lock until recycle. Note for `relations_cross_repo` readers: the counter now also includes in-subtree edges targeting the repo's OWN global reference stubs (previously uncounted bridge candidates).
- `part_of` gains `is_part_of` variant only — `member_of`/`component_of` are NOT part_of (membership is many-to-many); `import_upload` rejects files over 64 MB with a friendly error pointing at the rake imports; reference-stub detection batched once per import; scan_review rows record the real producer name (UI upload path included); passthrough observation confidence clamps numeric values to [0,1] while a missing/non-numeric key stays NULL; `flash[:error]` now renders (alert styling); extractor parse cache cleared after the emit pass. Backfill apply is atomic — every stamp rolls back on a mid-apply conflict (rake task and migration surface a `conflict_hint` instead of a raw `RecordNotUnique`: the occupying rows are looked up by scope + LIKE prefix and reported by id, branching the wording on a global-scope vs in-project clash — never parsed out of the DB message, which misleads on apostrophe or truncated names); reference stubs annotate their referrers with the CANONICAL stored relation type (`imports_from` → `depends_on`) so second-declarer re-imports re-match the stored edge instead of parking a new stub; `import_project_entity_id` pins scope through the payload ROOT's own merge decision only (a nested child merging into another Project can't hijack it).
## [1.49.0] - 2026-10-10
- Added `RailsAstExtractor` (`app/services/rails_ast_extractor.rb`): a deterministic Prism-only extractor that walks `app/models`, `app/controllers`, and `config/routes.rb` and emits a graphify-compatible `graph.json` — classes/modules with `def` methods, `belongs_to`/`has_many`/`has_one`/HABTM association edges (`class_name:` wins, else Zeitwerk-order symbol→constant resolution; `through:`/`source_type:`/`foreign_key:` kept in `properties`), `include`/`extend`/`prepend` → `mixes_in`, `scope`/`enum` → Method nodes, `delegate ... to:` → `delegates_to`, and `resources`/`resource`/verb routes → `Route` entities (`GET /swimmers/:id`) `part_of` routes.rb with `routes_to` edges to `Controller#action` Method nodes. Every edge carries `properties.provenance = "RAILS_DSL"` and `source = "rails_ast_extractor"` so rescan diffing stays in its own bucket.
- Producer-namespaced rescans: `GraphifyRescan` methods take a `source:` (default `"graphify"`), and a payload may declare `"producer"` — importer stamps that name on provenance observations, `properties.source`, and the `rescan` marker, so a rails_ast rescan diffs only rails_ast facts and never flags graphify's (or another producer's) observations/edges. The claimed name is gated by a `KNOWN_PRODUCERS` allowlist (`graphify`, `rails_ast_extractor`) — an uploaded payload cannot mint arbitrary trust sources.
- Resolution semantics: lexical (enclosing-namespace-outward) matches are `EXTRACTED`; a basename that matches exactly one constant in any namespace is an `INFERRED` reference to it; several distinct matches is `AMBIGUOUS` → withheld to `scan_review`; none is an honest dangling reference (`INFERRED`) that merges when the owning repo is imported.
- Folded-A4 cross-repo bridging: `apply_relations` skips edges whose SOURCE lives in an excluded foreign subtree, and skips in-subtree → foreign-endpoint edges too UNLESS the far endpoint is a reference-only stub (`endpoint_reference` flag) — declared-name collisions between repos still skip (the second repo's own subtree is dropped, follow-up scope). Bridged edges are tagged `properties.cross_repo = true` and counted in `ImportReport.relations_cross_repo`.
- Vocabulary: `belongs_to`, `has_one`, `delegates_to`, `routes_to` are canonical relation types (alongside `has_many`); `belongs_to` is no longer a `part_of` variant — association edges are cross-cutting, not hierarchical, and would otherwise have been rejected or silently re-parented. `EDGE_RELATION_MAPPINGS` covers the Rails DSL edge names; `classify` honors a producer `entity_type` hint (so `Route` nodes keep their type).
- Rake: `rails_ast:extract REPO=… [PROJECT=…] [OUT=…]` writes `graph.json`; `rails_ast:import REPO=… [PROJECT=…]` extracts and runs the whole pipeline headless with the same `RESCAN=0` opt-out.
- Reference stubs & claiming: unresolved extractor targets emit no provenance and a stub-tagged `part_of` edge (`relation_properties.reference_stub`); a later import that actually declares the entity replaces the stub edge with its real parent (single-parent `part_of` semantics), so the referencing repo's rescan cannot diff the declaring repo's facts as its own — the A→B→A flap is closed. Cross-repo bridging in `apply_relations` fires only for endpoints tagged `endpoint_reference` (importer-created stubs), never for operator-created entities.
- Rails DSL hardening: superclass now emits an `inherits` edge (retired by rescan relation diffing — no permanent "Superclass:" text contradiction); `enum` option kwargs (`prefix:`/`suffix:`/`default:`/`scopes:`/`validate:`/…) are parsed as options and accessor names are composed Rails-style (`prefix: true` → `state_free?`); `delegate` only reaches real associations; nested `resources` inside a `namespace`/`scope` keep the enclosing controller namespace and the parent's `:<singular>_id` segment; `root to:` and bare verb routes map by Rails convention.
- Safety & scale: each file is parsed once via a memoized cache with a 2 MB cap (`files_too_large` stat); `File.realpath` guards skip symlinks escaping the repo root — including `config/routes.rb`; constant and node lookups use O(1) basename/id indexes; passthrough node observations are re-stamped `source = producer_name` so uploads can't spoof trust; a rescan never proposes `delete_entity` for an entity another producer's active provenance still owns.
## [1.48.0] - 2026-10-09
- Added incremental rescans to `graphify:import`: payloads translated by `GraphifyImporter` carry `"rescan" => true`, and `ImportExecutionStrategy` auto-detects a re-import when the root already has graphify-sourced descendants — a second `graphify:import` of the same project reconciles stored provenance instead of only merging. `RESCAN=0` opts out (purely additive import).
- Design contract (documented in code): a Graphify `graph.json` is the FULL repository scan — absence of a previously imported entity/edge means the code was removed, not unscanned — so no coverage heuristic; the diff is scoped to the root's own `part_of` subtree and nothing is ever auto-deleted.
- Phase-1 observation diff (inside the import transaction, before the tree applies): entities vanished from the new payload get every active provenance observation `mark_obsolete!` ("removed in graphify rescan"); present entities whose `Defined at` lines drifted get `supersede!` with the replacement content ("moved in graphify rescan") — the merge pass then dedups the supersede replacement instead of creating a duplicate, and operator observations are never touched.
- Phase-2 relation diff (after `apply_relations`): stored graphify-sourced edges (`properties.source == "graphify"`) absent from the new payload — with both endpoints still present — are flagged.
- Post-commit, vanished entities and edges are queued as actionable `delete_entity`/`delete_relation` items in the `scan_review` queue (Project roots stay apply-protected); `ImportReport` gains `rescan`, `rescan_entities_flagged`, `rescan_relations_flagged`, `rescan_reparents_flagged`, `observations_obsoleted`, `observations_superseded`. Rescan logic lives in `GraphifyRescan` (`app/services/graphify_rescan.rb`), split out of `GraphifyImporter`.
- Same-tree moves: a stored entity whose `part_of` parent still sits inside the root's subtree is NO LONGER excluded as a foreign subtree — `foreign_subtree_paths` only excludes cross-project parenting (a class moved `lib/a.rb` → `lib/b.rb` keeps receiving its new provenance instead of ending with none). The move itself becomes a `reparent_entity` review item — unattended imports never re-parent, the operator applies `NodeOperationsStrategy#move_to_parent`.
- Restored items retire stale proposals: a pending `delete_entity`/`delete_relation` row whose target the new scan brought back is auto-dismissed ("restored in graphify rescan") so it can never be applied to live data.
- `PROVENANCE_PATTERN` accepts Graphify's `L<digits>` locations (`Defined at app/x.rb:L5`) so line-only drift supersedes instead of obsoleting.
- Rescan scoping honors the operator's merge decision: the root to diff is the merge `target_id` when picked, not the payload's namesake project; a failed import reports no rescan activity (the phase-1 diff rolls back with the transaction).

## [1.47.0] - 2026-10-09
- Added `GraphifyImporter` service: translates a Graphify `graph.json` (node-link format) into graph_mem's import-tree payload — Project → File → Class/Module → Method/Constant containment via `part_of`, one provenance observation per entity (`"Defined at <file><line>"`, `source: "graphify"`), and non-tree code edges (`calls`, `inherits`, `mixes_in`, `imports_from`→`depends_on`) emitted as name+type-addressed relations with `EXTRACTED`/`INFERRED` provenance in `properties`. `AMBIGUOUS` edges are withheld for review, never auto-applied.
- Import payloads now accept a top-level `relations` array: `ImportExecutionStrategy` applies them as a second pass inside the same transaction, resolving endpoints via `ImportEntityResolver` (name+canonical type); unresolved endpoints are counted (`relations_unresolved` in `ImportReport`) instead of failing.
- New canonical vocabulary: entity types `Method`, `Module`, `File`; relation types `calls`, `inherits`, `mixes_in` (+ `contains`, `imports`/`imports_from` mapped onto `part_of`/`depends_on`). `RelationshipDiscoveryStrategy::ALLOWED_RELATION_TYPES` accepts the new code relations so review proposals can apply them.
- Type-mapping seeds are now upsert-capable (`find_or_initialize_by` + update) so the moved `module` variant (Class → Module) and new variants land on existing databases.
- Added rake tasks: `graphify:translate GRAPH=… PROJECT=… [OUT=…]` writes a reviewable import file; `graphify:import GRAPH=… PROJECT=…` runs the headless flow (match → auto-accept decisions → execute with progress tracking) and queues ambiguous edges as `relationship_proposal` items in `scan_review`.
- Headless hardening (review-driven): root nodes merge only on an exact name+type match (never a fuzzy suggestion — `match.import_node` now carries the name/type); children whose existing `part_of` parent belongs to a different tree get the new counted no-op `exclude` action so whole foreign subtrees stay untouched (the `skip` create-fallback could orphan descendants).
- `graphify:translate` writes with `max_nesting: false`; malformed graph.json (non-object payload, non-array nodes/links, id-less nodes) raises `ArgumentError` up front; duplicate node ids are deduped first-wins, over-long labels (>255) are dropped, containment cycles and sub-trees deeper than `MAX_TREE_DEPTH` (64) are promoted to the project root — all counted in `stats` (`nodes_skipped_duplicate_ids`, `nodes_skipped_overlong`, `nodes_promoted_to_root`).
- Relation pass hardening: hierarchical (`part_of`) entries in `relations` are rejected and counted (`relations_skipped` in `ImportReport`), a single invalid edge skips-and-counts instead of rolling back the import, endpoints resolve via one (name, canonical type)→id map with preloaded existing-triple dedupe, and `ActiveRecord::StatementInvalid` (e.g. a truncated-`Too long` insert) surfaces as a failed report rather than escaping `execute`.
- Scale: `execute` suppresses inline embeddings and per-edge trust-score recompute during the transaction, enqueues a `backfill` maintenance job on success whenever any rows were created or merged (merge-only imports included — an alias merge clears `embedded_at` without creating anything), and recomputes trust once per touched entity; `EntityTypeMapping.canonicalize`/`RelationTypeMapping.canonicalize` are memoized (with `reset_canonicalize_cache!` called by the seeds). `graphify:import` also runs the embedding backfill synchronously after a successful execute, and observation de-duplication degrades to exact matching (instead of raising) while stored rows await their backfill.
- Embedding lifecycle is now explicit: `memory_entities`/`memory_observations` gained a dedicated `embedded_at` timestamp (indexed, back-filled for rows holding a real vector) tracking "has a real vector" — `with_embedding`/`missing_embedding` scopes are the single classification every embedding-related query goes through (the BEFORE INSERT trigger keeps filling the NOT NULL column with placeholder zero-vectors, which can no longer rank as distance-0 matches). `store_vector` writes the vector and the stamp atomically.
- Write serialization around bulk embedding: `ImportExecutionStrategy#execute` and `EmbeddingService.backfill_all` share a database-namespaced named lock (`GET_LOCK("graph_mem:<db>:embeddings")`) — the import waits up to 5 s, the backfill defers non-blocking (`backfill_all` returns `deferred: true`, `EmbeddingsMaintenanceJob` re-enqueues with a 60 s delay, and the maintenance report records `deferred` so a deferred run isn't logged as an empty success). `backfill_all` rescues per-row failures (incl. lock timeouts) leaving the row pending, and counts only rows actually written. `store_vector` is a compare-and-set on `updated_at` so a stale vector can never overwrite a row edited mid-embed, and `before_update` on both models clears `embedded_at` inside the same UPDATE whenever embedded fields change — even when the in-memory copy is stale — so a stamp landed between load and save cannot hide staleness.
- Fixed (pre-existing): `VectorSearchStrategy#search` no longer filters `entity_type IS NULL` for untyped searches (a dead filter since `62a46ca` that emptied the vector channel), and `search_observations` orders on the raw `MIN(VEC_DISTANCE_COSINE(...))` expression — `.pluck` rewrites `SELECT`, so ordering on the `vec_distance` alias raised "Unknown column" and the swallowed error made observation vector search always return `[]`. Both vector-distance queries also order on the computed expression `(vec_distance + 0)` to defeat MariaDB's ANN index scan, which fetches globally-nearest rows before applying `WHERE` and could starve the result on zero-vector placeholders. Relation endpoint lookup downcases name *and* type so unmapped entity types match case-insensitively.

## [1.46.0] - 2026-10-08
- Added temporal recall to read tools: `occurred_after`/`occurred_before`/`as_of` strict ISO 8601 params on `search`, `search_subgraph`, `get_entity`, `get_entities`, `get_subgraph_by_ids`, `summarize`, and the REST entity-search and summarize endpoints.
- Added `TemporalQueryParser`: temporal phrases inside `query` itself ("in October 2026", "during 2024", "Q3 2026", "last week", "past 6 months", "last spring", "since 2025", "as of …") derive a window automatically; explicit params win. Question filler words ("what", "changed", "tell me about", …) are ignored when judging whether a query is time-only, and invalid calendar dates are rejected.
- Added `TemporalWindow` semantics: dated observations match when `[valid_from, valid_until]` intersects the window (open bounds infinite); undated observations fall back to retention time (`created_at`); `as_of` is a point-in-time snapshot.
- Added a deterministic temporal channel to `HybridSearchStrategy`, boost-only for text queries: it re-weights entities already matched by text/vector/observation channels (in-window candidates rank first, then the rest) and never injects unrelated hits. Purely temporal queries — or queries whose residual terms match nothing (`retrieval.temporal.fallback: "temporal_only"`) — search by time alone, capped at 500 candidates (`candidates_truncated` flags the cap).
- Added `max_tokens` token-budget packing to the same read tools: validated strictly (integer 1–100_000; digit strings coerce, `0x10`/`5.7`/`1e3`/`+5` rejected), applied per page in `search` summary mode — the response envelope is estimated once (`envelope_tokens`) including a reserve for the MCP wrapper fields (`version`/`next_move`/`context`, conditional on an active context), items dropped from the requested page don't migrate (`dropped_on_page` + `retrieval.next_move` hint), with `retrieval.token_budget` / `token_budget` diagnostics (`max_tokens`, `estimated_tokens`, `truncated`).
- Added covering index `index_memory_observations_temporal_cover` on `memory_observations(status, memory_entity_id, valid_from, valid_until, created_at)` for the temporal channel.
- Resolved windows are echoed as `retrieval.temporal`; documented the feature in `docs/mcp_tools.md`.
- Fixed: migration class name for `change_action_mcp_session_capabilities_to_json_text` so fresh `db:migrate` works under Zeitwerk.
- Fixed: `db/structure.sql` trigger bodies no longer carry `/*application='GraphMem'*/` marginalia — fresh `db:schema:load` on MariaDB 11.8 works again; `db:schema:dump` post-processing strips the tag on future dumps.
- Note: the new covering index requires `db:migrate` on existing databases.
- Changed: temporal-only retrieval and the temporal fallback now treat an active project context as a ranking boost only — `scope: "global"` searches/summaries no longer drop other projects' in-window facts; a hard scope applies only when explicitly requested (`scope_entity_ids` or `scope: "context"`).

## [1.45.0] - 2026-10-08
- Pinned the GitHub-only FastMCP `v1.7.1` release at immutable commit `b10243c218c3d8a1a9f20e033314b647595938ca`, which adds `filter_prompts`.
- MCP prompts now follow connection profiles: prompts declare profiles via `mcp_metadata(profiles: ...)` and a `filter_prompts` block applies them to `prompts/list` and `prompts/get`. All concrete prompts explicitly declare their profiles; `mcp_profiles` inherits from the superclass when unset. The `MCP_PROFILE_NAMES` constant in both base classes now references `GraphMem::McpProfile::NAMES`.
- **Behaviour change on the readonly profile (HTTP and stdio):** `persist` is no longer listed there, and `prompts/get` for `persist` now returns JSON-RPC error `-32602` "Prompt not found: persist". `orient` and `recall` are unchanged; `/mcp` and `/mcp/maintenance` still serve all three prompts. The stdio runner (`GRAPH_MEM_MCP_PROFILE=readonly`) now correctly excludes `persist` at registration time.
- `McpServerPatch` boot-time guard: raises at startup if the fork's `handle_tools_list` signature changes (parameter check + version pin spec).
- Resource registration is now idempotent: `McpToolRegistry.register_with!` clears existing resources before re-registering, preventing duplicates from development code-reload.

## [1.44.0] - 2026-09-18
- Pinned the GitHub-only FastMCP `v1.7.0` release at immutable commit `55bdc57fb2bca88a7c99a0423eee083e912f7519`.

## [1.43.0] - 2026-09-18
- Pinned merged FastMCP `1.7.0.pre.4` with request-scoped in-place tool/resource filtering.
- Removed profile server cloning, filtered-server caches, and the formatter propagation shim; the Streamable HTTP transport now passes its Rack request through FastMCP context.
- Kept compatibility aliases hidden-but-callable while enforcing connection-profile eligibility at `tools/call`.

## [1.42.0]
- Pinned merged FastMCP `1.7.0.pre.3` with JSON-safe legacy results, safe error formatting, and pluggable request authentication.
- Replaced GraphMem's custom tool dispatch/error methods with FastMCP's `error_formatter`; only list visibility and filtered-copy formatter propagation remain patched.

## [1.41.0] - 2026-09-17
- Added an authenticated operator tool-telemetry dashboard with bounded trends, per-tool latency/error metrics, client/error/signature breakdowns, filters, and paginated invocation details.
- Added configurable 90-day telemetry retention, manual pruning, daily garbage-collector integration, and dashboard query indexes.

## [1.40.0] - 2026-09-17
- Pinned FastMCP `1.7.0.pre.2` with opt-in `outputSchema` and dual `structuredContent`/JSON text results.
- Added post-envelope output schemas for all 12 default GraphMem tools.
- Moved composite response routing to FastMCP request context and replaced private Rack cache access with a public API.
- Kept maintenance-only and hidden compatibility tools on their existing text-only output during the staged rollout.

## [1.39.0] - 2026-09-17
- Pinned GraphMem to the tested `steveoro/fast-mcp` fork with native MCP prompts and truthful tool-list notifications.
- Added `orient`, `recall`, and `persist` prompts plus additive version, context, `_meta`, and success `next_move` guidance.
- Folded context clearing into nullable `set_context`; `clear_context` and `get_version` remain hidden callable aliases.
- Standardized entity/relation possible-duplicate responses and added soft type examples with non-blocking typo hints.

## [1.38.0] - 2026-09-17
- Consolidated ten mutation tools into atomic `graph_write`, `graph_edit`, and `graph_delete` operation batches.
- Added shared mutation services with indexed errors, full rollback, Project protection, audit-reason preservation, and merge delegation.
- Added batch-wide entity duplicate preflight: a possible duplicate prevents every write and returns candidate details.
- Kept all prior mutation names callable but hidden from `tools/list`, with compaction-valve and telemetry coverage retained.

## [1.37.0] - 2026-09-17
- Consolidated entity discovery into `search`, with uniform summary, subgraph, and catalog response envelopes.
- Added `get_entities` for one-or-many entity loads with explicit all/internal relation projections.
- Extended `traverse_graph` to cover direct endpoint, type, and global relation queries.
- Kept six legacy read-tool names callable but hidden from `tools/list` so existing clients continue working while telemetry measures alias traffic.

## [1.36.0] - 2026-09-17
- Added explicit MCP annotations and profile membership to all 35 registered tools.
- Added `/mcp/readonly` and `/mcp/maintenance` Streamable HTTP profiles; `/mcp` now hides the 10 maintenance tools.
- Applied profile filtering consistently to `tools/list` and `tools/call`, including the legacy SSE endpoint and stdio runner.
- Added `GRAPH_MEM_MCP_PROFILE` for selecting the stdio catalog.

## [1.35.0] - 2026-09-16
- Added privacy-safe, queryable MCP tool telemetry in `tool_invocations`; only top-level argument keys are stored, never argument values.
- Added `graph_mem:tool_usage` reporting for per-tool traffic share, error categories, p50/p95 latency, and never-called tools.
- Hardened telemetry so database write failures cannot affect MCP tool results.
- Fixed the MCP access-policy CIDR spec to preserve the no-public-unauthenticated invariant.

## [1.34.0] - 2026-09-10
- Improved all tool descriptions.

## [1.33.0] - 2026-08-11
- Added the Project Scan Skill Companion: a dashboard UI for the human-guided, multi-stage `project_scan` skill with deterministic, no-LLM depth scanning.
- New `project_scan_skill` operation type and `ProjectScanSkill` service covering `birds_eye`, `architecture`, `usage`, `ui`, and `tests_and_docs` depths.
- `ProjectScanSkillJob` processes one depth per run, then pauses and broadcasts progress; operators continue or stop from the dashboard.
- New dashboard card shows the depth stepper, live progress, and Continue/Stop actions, reusing `OperationProgressChannel` and the `operation-progress` Stimulus controller.

## [1.32.0] - 2026-08-11
- Added live, real-time progress updates to the Project Scans dashboard card: active scan rows subscribe to `OperationProgressChannel` and update status, phase, percentage, and progress bar via ActionCable without page reloads.
- `ProjectScansController` now creates a pending `OperationProgress` record immediately when a scan is triggered, so the dashboard can subscribe before the background job starts.
- `ProjectScanJob` and `ProjectScanner` broadcast `OperationProgress` snapshots at each phase and on completion/failure.

## [1.31.0] - 2026-08-11
- Added dashboard form to trigger project source scans (`ProjectScanJob`) with project root, mode, dry-run, and optional project name/aliases/file globs.
- Added filesystem-root allow-list validation before enqueuing scans, with the allowed roots configurable by operators via a new **Project Scans** tab in System Settings.
- `ProjectScansController` resolves `project_scan_roots` from `AppSettings` (with `PROJECT_SCAN_ROOTS` env fallback) and rejects paths outside the configured roots.

## [1.30.0] - 2026-08-10
- Added project scan feature + dedicated skill for manual execution without local LLM support for summarization.

## [1.26.0] - 2026-08-10

- Refactor streamable HTTP transport with thread-safe session management and stream lifecycle handling.
- Replace per-session response_queue with per-request thread-local queues to prevent concurrent POST races.
- Introduce session leasing with active_requests counter and last_active_at tracking under @sessions_mutex.
- Implement per-stream state (queue, io, closed flag, mutex) via register_stream/unregister_stream; each GET opens its own stream.
- Add lazy session reaper (60s interval, 30min timeout) to prevent stale sessions to bloat memory.

## [1.25.0] - 2026-08-09

- Implemented Streamable HTTP transport alongside legacy SSE for MCP.

## [1.21.0] - 2026-07-31

- Implement import observation duplicate distance settings and validation; enhance import handling with relation direction support. Vers. 1.21.0.

## [1.20.0] - 2026-07-31

- Improved SummarizeTool with a focused context parameter; bundle updates; enhance data exchange and memory entity handling with new relation validation and improved observation ranking; hardened relation-integrity, context scopes, import matching, ranked and ordered observation limits, dream-state discovery and focused specs

## [1.11.0] - 2026-07-30

- Added entity_type as a parameter for CreateEntityTool, SuggestMergesTool and VectorSearchTool; updated documentation + bundle updates; improved DreamStateCompactor with more strategies from GraphIntegrityService

## [1.10.1] - 2026-07-18

- Added `summary_observations_per_entity` setting to control how many observations are included in each entity summary
- Fixed parameter inversion in a private method call in SummarizeService
- Add compaction review UI with editable suggestions and suppression tracking
- Replace in-memory report items with `MaintenanceReportRow` model for persistent review queue
- Add `MaintenanceReportSuppression` model to track dismissed suggestions and prevent duplicates
- Support editing merge targets, relation endpoints, and parent assignments before applying
- Add status filters (active/dismissed/approved/ignored) and kind filters (entity_merge/relationship_proposal/orphan_parent)
- Implement bulk dismiss


## [1.9.8] - 2026-07-15

- Add `summarize` MCP tool and `POST /api/v1/summarize` for query-scoped summarization with deterministic source-backed evidence
- Add optional LLM synthesis via `SummarizationConfig`, `SummaryGenerationClient`, and operator **System Settings → Summaries** tab
- Deterministic fallback when LLM summarization is disabled, unconfigured, or provider-unavailable; embedding and summary models remain independent
- Documentation: `docs/summarization.md`, updates to MCP tools, REST API reference, and app settings reference

## [1.9.6] - 2026-07-14

- Dream-state compactor: process one entity per batch with per-entity transaction isolation, advance cursor before processing, and skip per-entity errors instead of halting the run
- Harden `tree_walk` vector similarity query by using an in-memory `VEC_FromText` literal instead of a subquery against `memory_entities` and by running merge scan before deduplication
- `GarbageCollectionRunner` now deletes duplicate observations and repairs `memory_observations_count` counters
- `GraphIntegrityService` orchestrates `RelationIntegrityRepairer`, `GarbageCollectionRunner`, and a full counter recount; called by `GarbageCollectionJob` and before each new dream-state run
- Add OperationProgress tracking to import, export, compaction, and garbage collection jobs with real-time broadcasting
- Add CircleCI config

## [1.9.4] - 2026-07-13

- Prevent concurrent compactor runs; compactor review UI; increased concurrent stability

## [1.9.3] - 2026-07-10

- Fixes for multi-agent client tool usage; documentation update; dream state compactor 3rd phase: relationship suggestion + integration tests

## [1.9.1] - 2026-07-10

- Fixes for embeddings generation and connection testing; bundle update

## [1.9.0] - 2026-06-26

- MCP clients dashboard card: per-agent project context, recent activity, and last tool used (via `X-MCP-Client`)
- Embeddings operator dashboard v2: AppSettings-backed config (AppSettings → ENV → defaults) with dedicated Settings tab
- `EmbeddingConfig` module and `EmbeddingService.reset_instance!` for live config reload
- `EmbeddingIndexManager` with operator add/drop ANN index actions (rake tasks delegate to the service)
- `embedding_maintenance` MaintenanceReport from backfill/regenerate jobs; scheduled daily backfill via `EmbeddingScheduledBackfillJob`
- Embeddings page: config source badges, last job report, pending job hints; operator guide at `docs/operator/embeddings.md`

## [1.8.3] - 2026-06-26

- Operator audit log browse page with filters, pagination, and dashboard stat-chip link
- Standalone prune action for audit logs older than 90 days (with confirmation)
- Operator embeddings dashboard: coverage stats, connection test, and background backfill/regenerate jobs

## [1.8.2] - 2026-06-24

- Settings page behind front-end sign-in for operators; API & MCP remain auth-less
- Auto-backup feature

## [1.8.1] - 2026-06-24

- Protect Project nodes from being garbage-collected (urgh! +_+ ): no more "stale" nodes clean-up

## [1.8.0] - 2026-06-24

- Improved dashboard, with compactor run and garbage collector states, plus force run/pause controls

## [1.7.0] - 2026-06-10

- Added support for per-agent project context scoping via `X-MCP-Client` header
- Added "dream state" background job to periodically review knowledge base for "compactification" opportunities

## [1.6.0] - 2026-03-18

- Support for both camelCase and snake_case arguments; support for @modelcontextprotocol/server-memory-like syntax (models have been already trained excessively on that, so graph_mem syntax is prone to misunderstanding); improved ruleset with quick reference; updated docs

## [1.5.0] - 2026-03-12

- Improve search results with more nuanced weighting and ranking (cosine distance + quality gate)

## [1.4.2] - 2026-03-12

- Improved coherence in tool parameters naming; updated default global rules

## [1.4.1] - 2026-03-11

- Full OpenAPI compliance with metadata generation and improved API coherence
- Full CORS support for usage with browser-based UIs (e.g.: OpenWebUI)


## [1.3.0] - 2026-03-05

- Update to Rails 8.1.2
- Context persistance using Mutex (single-user, single conversation, thread-safe)


## [1.2.0] - 2026-03-04

### Added

- **Search box on landing page**: node search with both text & vector based strategy (switchable)

### Improved

- **Container setup**: README notes; simplified update process with just `docker compose up -d --build`; now container uses host network for an easier LAN sharing of the MCP service


## [1.0.0] - 2026-02-27

### Added

- **Vector semantic search**: Native MariaDB 11.8 VECTOR(768) columns with cosine distance indexing for entity and observation embeddings
- **Embedding service**: Configurable `EmbeddingService` using Ollama (or OpenAI-compatible) API via `OLLAMA_URL` env var; supports LAN-wide embedding host architecture
- **Hybrid search**: `HybridSearchStrategy` combining text-based tokenized search with vector similarity using Reciprocal Rank Fusion (RRF)
- **Entity type canonicalization**: `EntityTypeMapping` table normalizes free-text entity types to canonical forms (e.g., "workspace" -> "Project"), preventing graph fragmentation
- **Entity description field**: New `description` column on `memory_entities` for richer semantic context
- **FULLTEXT index**: Combined fulltext index on `(name, aliases)` for faster text search
- **Auto-deduplication**: `CreateEntityTool` checks for similar existing entities via vector search before creating; warns if a close match exists
- **Context scoping**: New `set_context`, `get_context`, `clear_context` tools to scope operations to a specific project
- **Merge suggestions**: New `suggest_merges` tool finds potential duplicate entities using vector similarity
- **Bulk operations**: New `bulk_update` tool for creating multiple entities, observations, and relations in a single atomic transaction
- **Docker Compose**: Production-ready `docker-compose.yml` with MariaDB 11.8 and Rails app; `docker-compose.override.yml` for development with hot reload
- **Docker MCP wrapper**: `bin/docker-mcp` script for stdio MCP transport via containerized graph_mem
- **Embedding backfill**: `rake embeddings:backfill` and `rake embeddings:regenerate` tasks

### Changed

- Upgraded to MariaDB 11.8 (Docker image) for native vector support
- `SearchEntitiesTool` now uses `HybridSearchStrategy` (text + semantic) by default
- `SearchSubgraphTool` merges vector search results with text search results when embeddings are available
- Dockerfile updated: includes MariaDB client libs, exposes port 3030, removes Thruster dependency for flexibility
- All entity-returning tools now include `description` field in responses

### Removed

- Dropped 5 unused `action_mcp_*` tables from the legacy ActionMCP gem

## [0.9.3] - 2026-01-28

### Changes

- Added data-exchange/management feature in graph_mem server landing page, with dedicated clean-up tab for manual node merging/moving/deletion
- Add also missing observations in skipped nodes during data-import
- Added support for relation edit/deletion in context menu
- Bundle update

## [0.8.6] - 2025-12-07

### Changes

- Generalized RVM sourcing in runner script to support multiple installation paths
- Bundle update

## [0.8.5] - 2025-08-02

- Set default value for `memory_observations_count` to 0
- Added tests for `delete_duplicates` API endpoint
- Added "delete duplicates" action to graph visualization in observation details show pop-up menu

## [0.8.4] - 2025-08-01

- Substitute deprecated :unprocessable_content status code with :unprocessable_content; bundle updated
- Fixed merge operation on node-to-node action in graph visualization
- Removed legacy `observations_count` (proper counter cache column: `memory_observations_count`)

## [0.8.3] - 2025-07-18

- Improved "knowledge graph visualization": contextual menu for nodes and edges, with options to navigate to related entities and observations; double-click to close up to a node subgraph; editable entity data

## [0.8.2] - 2025-07-02

- Tokenized search for entities, by name, aliases and entity_type, with overall relevance score (float)

## [0.8.1] - 2025-06-16

- Preliminary graph visualization with Cytoscape.js + Stimulus.js using the localhost Rails server


## [0.8.0] - 2025-06-13

- `update_entity_tool` to update an existing entity
- support for entity names aliases as pipe-separated strings


## [0.7.1] - 2025-06-10

- `db:append_json` task to merge matching objects in legacy memory.json data files into existing database rows
- `db:merge_entity` task to merge a single entity into an existing entity
- `db:project_report` task to generate a consolidated Markdown report with Mermaid diagrams for all projects in the database


## [0.7.0] - 2025-06-09

- MCP Resources for higher-level structured access:
  - `memory_entities` resource with advanced filtering, sorting, and relation inclusion
  - `memory_observations` resource with text search and entity inclusion
  - `memory_relations` resource with bidirectional entity inclusion
  - `memory_graph` resource for graph traversal starting from any entity
- Comprehensive documentation in `/docs` directory
- Support for pagination in all list operations
- Integration with Windsurf via STDIO transport
- Improved error handling with custom error classes

- Refactored MCP tools to use unified application tool base class
- Improved response formatting for better compatibility with Cascade MCP client
- Enhanced JSON serialization for better performance
- Updated README with more detailed installation and usage instructions

### Fixed

- Monkey-patched `FastMcp::Server#handle_tools_call` to fix tool instantiation issue
- Fixed response formatting for Cascade compatibility
- Corrected CORS configuration for cross-origin requests
- Resolved N+1 query issues in relationship traversal

## [0.6.0] - 2025-05-20

- SSE transport for real-time updates
- Support for complex graph traversal operations
- `get_subgraph_by_ids` tool for retrieving connected subgraphs
- Improved entity search with partial name matching

- Updated to fast-mcp 1.4.0
- Enhanced entity serialization with observation counts
- Better error handling and validation for tool parameters

## [0.5.0] - 2025-04-12

- Complete RESTful API at `/api/v1` for non-MCP clients
- Swagger API documentation
- Authentication framework (disabled by default)
- Database indices for improved performance

- Moved to Ruby 3.4.1
- Updated Rails to 8.0.2
- Refactored database schema for better performance
- Enhanced model validations

## [0.4.0] - 2025-03-05

- Relation management tools:
  - `create_relation`
  - `delete_relation`
  - `find_relations`
- Support for typed relationships between entities
- Database migrations for relation model

## [0.3.0] - 2025-02-18

- Observation management tools:
  - `create_observation`
  - `delete_observation`
- Support for attaching multiple observations to entities
- Observation count tracking

### Fixed

- Entity deletion cascade to associated observations
- Proper JSON-RPC error codes for common error scenarios

## [0.2.0] - 2025-01-27

- Entity management tools:
  - `create_entity`
  - `get_entity`
  - `search_entities`
  - `list_entities`
  - `delete_entity`
- Basic entity schema with name and type
- Integration with MariaDB

- Updated project structure to Rails 8.0 conventions
- Enhanced tool parameter validation

## [0.1.0] - 2025-01-06

- Initial project setup
- Basic MCP server implementation
- `version` tool
- Configuration for fast-mcp gem
- Project documentation and license
