# UI-5 → graph_mem 1.58.0: Review & Fix (grouped queue, digest, group actions, policies, contradictions, undo in the UI)

**Written 2026-10-26 (Europe/Rome)** for Claude, from the 1.57.0 code (`e826476`, UI-4a / #127 merged and tagged).
**Revised 2026-10-26 evening:** Steve's answers are in. `contradiction` rows are **in** UI-5 (A5, B2 moved to UI-5b to
keep both PRs under the limit); the split, policy batch size, old URLs and `ignore` → snooze are confirmed.
Every file:line below was checked against that commit. If a line has moved, find the code by the quoted text; if the
code no longer matches the description, **stop and ask Steve** instead of improvising.

Context: `ui-dashboard-plan.md` §2.5 (the Review & Fix design: model changes, page, policies, limits at the source),
§5.1-§5.4 (guardrails, confirm levels, change sets, role matrix) and §6 UI-5. `ui-4a-plan.md` and
`docs/architecture.md` "Change sets and undo (UI-4a, 1.57.0)" describe the undo API this PR builds on. This file
**replaces** §6 UI-5 as the step list: where they differ, this file wins (the differences are listed under "Decisions"). It is self-contained; read the other plans only for background.

## Brief

| | |
|---|---|
| **Branches / PRs** | **Two PRs by default** (see "Size and split"; Steve may ask for one). **Two PRs** (Steve confirmed). **UI-5a** `claude/ui-5a-review-backend`, title `UI-5a: review data model, limits, policies and contradiction rows`: steps A1-A5, B1 and their docs; CHANGELOG under `## [Unreleased]`, **no version bump**. **UI-5b** `claude/ui-5-1.58.0` (off `main` after UI-5a merges), title `UI-5: Review & Fix (1.58.0)`: steps B2, C1-C3, the rest of D, release R. Steve merges and tags; never merge, tag, push tags or run `rake release`. |
| **Commits** | In this order: **A1** schema + models, **A2** classifier + seeding + backfill + symmetric dedupe, **A3** limits at the source + SQL pagination + expiring suppressions + cleanup, **A4** change-set links on rows (`resolved_by`, `change_set_id`, the undo handle), **A5** `contradiction` rows (signature, classification, seeding from the stale scan, apply = keep one side, old-page buttons), **B1** policy runner + job + schedule + the policy settings fields — **end of UI-5a** — **B2** Settings › Review policies panel (audited), **C1** apply preview + group actions, **C2** `ReviewController`, routes, views, toasts with Undo, error mapping, **C3** keyboard, nav badge, removal of the old review actions, **D** docs, **R** release. Review fixes go in new commits; no force-push after review starts. |
| **Scope** | §2.5 minus the items listed under "Out". New routes only under `/review` (operator only) plus the existing `/operator/settings`. **No MCP tool changes beyond keeping today's four review tools working** (plus the additive `keep_observation_id` in `apply_maintenance_review`'s `action_params`, A5), **no `/api/v1` endpoint.** `detect_contradictions` (MCP) and `POST …/detect_contradictions` (`/api/v1`) keep their behaviour: they never seed review rows. |
| **Data** | Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Beta Service`, a factory script for the 1,000-row check). Never real data, real credentials or a production dump. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `ui-dashboard-plan.md` §0.1 (implementer brief: spec hygiene, test-DB truncate, done criteria), `docs/architecture.md` "Change sets and undo". |

## What the code looks like today (verified at `e826476`)

- **Stack.** Rails 8.1.4, Ruby 3.4.1, MariaDB 11.8 with `vector(768)` columns. `config/application.rb:38`
  `schema_format = :sql`: **`db/structure.sql` is the schema**; `db/schema.rb` is stale and must not be edited or
  regenerated. Latest migration: `20261026120100_add_change_set_id_to_audit_logs.rb`.
- **Review rows.** `app/models/maintenance_report_row.rb` (53 lines): `STATUSES = %w[active ignored approved dismissed]`
  (6), scopes 16-23 (`pending` = active + ignored, 23), JSON `payload`/`edited_payload` (25-26), `effective_payload`
  (29-32). Table `maintenance_report_rows` (`db/structure.sql:131-156`): no group, anchor, project, priority,
  confidence, expiry, resolver or change-set column; generated `stale_entity_id` + `index_mrr_stale_candidates`.
- **Suppressions.** `app/models/maintenance_report_suppression.rb` (17 lines): `suppressed?(report_type, signature)`
  is a plain `exists?` (12-14). Table (`structure.sql`, `CREATE TABLE maintenance_report_suppressions`): unique
  `(report_type, signature)`, `kind`, `dismissed_at`, `reason`; **no `expires_at`, no `source`**.
- **Reports.** `app/models/maintenance_report.rb`: `REPORT_TYPES` (4-5) has no `review_policy_run`;
  `MAX_REPORTS_PER_TYPE = 30` pruned `after_create` (6, 17-24).
- **Queue service.** `app/services/compaction_review_service.rb` (630 lines, already over the ~500 rule; UI-5 must
  move code out, not add to it):
  - `items` (23-33) loads the whole filtered scope `.to_a`, filters `q` in Ruby (`filter_by_query` 495-502, values
    only, not JSON keys), sorts in Ruby (`sort_rows` 485-489: `root_first?` 362-368, then `item_score` 370-372 =
    `payload["score"].to_i`) and pages with `Kaminari.paginate_array` (32). `list_maintenance_review`
    (`app/tools/list_maintenance_review_tool.rb:34-48`) uses its `total_count`/`total_pages`.
  - `status_counts`/`kind_counts` (42-52) are SQL `group.count`.
  - Actions: `apply` (92-97), `dismiss` (99-108), `bulk_dismiss` (110-119), `bulk_apply` (124-126 → `bulk_apply_rows`
    408-437, **no kind whitelist**: any selected kind, merges and `delete_entity` included, is applied), `restore`
    (128-144, deletes the row's suppressions), `ignore` (146-152, status `ignored`, no suppression, never expires).
  - `apply_row` (376-406): status check, `ProjectMembership.with_membership_lock` **then** `row.with_lock` + reload +
    re-check, `CompactionReviewApplier.apply`, then `track_review_row { update!(status: "approved", applied_at:) }`;
    `LockTimeout` propagates to the caller.
  - `seed_report` (154-200): ER_CHECKREAD retry around the whole transaction (`with_checkread_retry` 463-474, own
    `transient_lock_error?`/`checkread?` 476-483 that duplicate `TransientDbError`), skips suppressed signatures (182),
    pending duplicates (183) and absorbed `stale_memory` (184, `absorb_stale_memory?` 211-258, which sets the losers to
    `ignored`, 256). **No classification, no ceiling, no per-run cap.**
  - `suppressed?(kind, payload)` (260-266) = suppression **or any row with the signature** (any status).
  - `signature_for` (268-358): `relationship_proposal` is `"relationship_proposal|from|to|type"` (276-282), **not
    ordered for symmetric types**.
  - `suppress` (608-621) uses `create_or_find_by!` and sets `reason = row.resolution_reason` **before** `dismiss`
    writes the new reason (102-106), so the suppression keeps the old (usually nil) reason; an existing suppression is
    found and left as is.
- **Change recording (UI-4a).** `app/services/compaction_review_service/change_recording.rb`: `REVIEW_FIELDS =
  %w[status applied_at dismissed_at resolution_reason]` (9), `record_review` opens `review.<action>` (23-26, returns
  the block's value, **not the set's uuid**), `track_review_row` notes before/after (30-35), `note_suppressions` (48-50).
  `ChangeSet` (`app/models/change_set.rb`): `KINDS` (15-19), `KIND_PATTERNS` reserve `policy.*` and `explore.*`
  (20-21), `NOT_UNDOABLE_REASONS` (23), `WINDOWS` merge 7 days / audit 30 days (24), `MAX_SNAPSHOT_BYTES = 4 MB` (25).
  `ChangeSet::Context` (`app/models/change_set/context.rb`): `attr_reader :uuid, …, :id` (19), `persist!` (48-54).
- **Undo (UI-4a).** `ChangeSetUndo.call(uuid, actor:)` (`app/services/change_set_undo.rb:55-90`): valve pause,
  `Current.set(change_set: nil)`, membership lock, inline embeds suppressed, one transaction; `Result` statuses `:ok`,
  `:conflict`, `:not_undoable`, `:not_found`, `:busy` (30-33); `LockTimeout` and `TransientDbError.busy?` → `:busy`
  (82-89). `dispatch` (109-115) runs `AuditInverse` or `Merge`, then **always** `ReviewRows`. `refusal_reason`
  (117-123): already undone / strategy `none` / window passed. `ChangeSetUndo::ReviewRows`
  (`app/services/change_set_undo/review_rows.rb`): reverts a row only while it is still in its "after" status, else
  skips and reports (27-38); deletes created / re-inserts deleted suppressions (40-59).
  `ChangesController` (`app/controllers/changes_controller.rb`, 39 lines): `POST /changes/:uuid/undo`
  (`config/routes.rb:114-116`), operator only, `STATUSES` ok 200 / conflict 409 / not_undoable 422 / not_found 404 /
  busy 503 (7-10); Turbo Stream → `turbo_stream.update("toasts", partial: "layouts/flash_messages")` with that status;
  HTML → `redirect_back` with flash (16-26); messages from `ui.changes.*` (`config/locales/ui.en.yml:29-32`).
  `app/services/transient_db_error.rb`: `checkread?` (16-19), `retryable?` (23-25), `busy?` (29-31).
- **What can't be undone today** (`docs/architecture.md` "Strategies and windows"): sets with `hard_delete` (a
  `delete_entity` review apply → `entity.destroy!`, `compaction_review_applier.rb:189-207`), `mixed_merge` (a merge plus
  any other write in one set, e.g. today's unrestricted `bulk_apply` with a merge row and a relationship row),
  `audit_incomplete`, `snapshot_too_large`. `delete_observation` is an obsolete mark (217-229) and stays undoable.
  A single `entity_merge` apply is a merge set (7 days); everything else 30 days.
- **Applier.** `app/services/compaction_review_applier.rb` (286 lines): `apply` dispatch per kind (7-36);
  `create_relation` (85-120, `part_of` takes the membership lock in a savepoint); **no `preview`**.
  `apply_maintenance_review` `dry_run` (`app/tools/apply_maintenance_review_tool.rb:39-47`) only echoes the payload.
- **Web UI.** `DataExchangeController` (921 lines): `compaction_review` (241-265), `compaction_review_action`
  (267-333: edit/apply/dismiss/bulk_dismiss/bulk_apply/restore/ignore/approve; **no rescue for
  `ProjectMembership::LockTimeout`**, so a busy lock is a 500), `review_action_turbo_streams` (335-367),
  `compaction_review_import_suggest_merges` (369-394), helpers (`review_report_type` … `compaction_edit_params`, 746-776). Routes `config/routes.rb:87-90`. Views
  `app/views/data_exchange/compaction_review.html.haml` (64), `_compaction_review_item.html.haml` (204),
  `_compaction_review_confirm.html.haml` (64), `_compaction_review_tabs.html.haml` (20),
  `_compaction_review_item_frame.html.haml` (2); JS `app/javascript/controllers/compaction_review_controller.js` (80,
  entity autocomplete). Other entry points: the dashboard scan card posts `apply`/`dismiss` to
  `compaction_review_action` (`app/views/pages/dashboard/_project_scans_card.html.haml:92-98`) and links at 101;
  `_dream_state_compactor_card.html.haml:88` and `_reports_details.html.haml:8` link to the old page.
- **Shell (UI-1).** `app/views/ui/_sidebar.html.haml:4-27` (review links + `ui_review_backlog_count` badge);
  `app/helpers/ui_helper.rb`: `REVIEW_BACKLOG_CACHE_KEY` (10), `can_write?` (16), `ui_review_backlog_count` (55-59,
  active rows, cached 30 s). Toasts: `app/views/ui/_toasts.html.haml` (`#toasts`), `app/views/layouts/_flash_messages.html.haml`
  (text-only toasts), `app/javascript/controllers/toast_controller.js` (notices auto-remove after 6 s, 13-16).
  CSP: `config/initializers/content_security_policy.rb` (nonce `script-src`, no inline handlers).
- **Roles.** `RoleAuthorization` (`app/controllers/concerns/role_authorization.rb`): deny by default, `allow_guest`
  (25) opts in. `spec/requests/role_matrix_spec.rb` walks every dispatcher route; `record_counts` (68-70) =
  entities, observations, relations, audit logs, review rows, change sets. Actors:
  `ApplicationController#set_current_actor` (35-45); jobs have no actor.
- **Settings.** `app/models/app_settings.rb` (190 lines): fields 8-57 (`compaction_review_row_retention_days` 52-54),
  uncached boolean readers via `read_boolean_setting` (181-189). `Operator::SettingsController` (261 lines):
  `bulk_update` (13-78, per-tab validators, writes any defined field, **no audit row**), `group_settings_by_category`
  (128-165, tabs), panels in `app/views/operator/settings/` (`index.html.haml` 132 lines + `_*_panel` partials).
- **Generators that seed rows** (all through `CompactionReviewService.seed_report`): `DreamStateCompactor`
  (`app/strategies/dream_state_compactor.rb`: proposals 147, `orphan_parent` 177-194, `entity_merge` 272-283,
  `entity_error` 291-298, `flush_review_queue!` 301-309), `DreamStateCompactionJob:76` (integrity sweep),
  `StaleMemoryScanJob:18`, `GraphIntegrityService:46`, `GraphifyRescan:245`, `ProjectScanner:847`,
  `GraphifyImporter::Matching:56` (band `low`, `score = confidence × 10`, 47-48), `DataExchangeController:382`
  (suggest merges). `RelationshipDiscoveryStrategy` (245 lines): `MAX_PROPOSALS_PER_ENTITY = 3` (7), `ordered_pair`
  (212-214), `dedupe_and_limit` (216-221); **no `MIN_QUEUE_SCORE`**. `RelationSemantics::SYMMETRIC_TYPES =
  %w[relates_to]` (8), `symmetric?` (27-29). `StaleMemoryScanner.still_flagged_ids` (177-192).
  `GraphifyRescan` dismisses rows directly at 314 and 381 (outside `CompactionReviewService`).
- **Contradictions.** `app/services/contradiction_detector.rb` (138 lines): `Result = Struct(:observation_id_1,
  :observation_id_2, :distance, :confidence)` (20); `detect(entity_id, …, persist: true)` (28-39) returns `[]` unless
  `AppSettings.contradiction_detection_enabled?` and `EmbeddingService.vector_enabled?` (29-30), compares active
  observations of the entity and its 1-hop neighbours (32, 43-55), de-duplicates `(a,b)`/`(b,a)` by sorted ids and
  sorts by confidence (94-97); `contradiction_confidence` = `min((1 − distance) × 1.1, 0.99)` (113-117);
  `create_report` (119-136) writes a `contradictions` `MaintenanceReport` (in `REPORT_TYPES`, `maintenance_report.rb:4`)
  with the candidate ids only. **No review row, no signature, no apply path.** Callers: `StaleMemoryScanner.scan`
  (53-59) → `detect_contradictions` (144-161: entities with observation activity since the watermark, best-effort,
  returns the previous watermark on error); `DetectContradictionsTool` (`app/tools/detect_contradictions_tool.rb:34`);
  `Api::V1::MemoryObservationsController#detect_contradictions` (39-46). `StaleMemoryScanJob` seeds `result[:items]`
  into `compaction_review` (17-24) and writes `by_signal` (30).
- **Retiring an observation is already undoable.** `MemoryObservation#mark_obsolete!` (`memory_observation.rb:78-88`,
  no-op when inactive) is an `update!`; `Auditable#audit_update` (`app/models/concerns/auditable.rb:18-25`) writes the
  `from`/`to` of `status`, `obsoleted_at`, `obsolescence_reason` into the open change set, and
  `ChangeSetUndo::AuditInverse` writes them back (it only skips the derived columns in `IGNORED`, 9) after refusing
  when the observation changed since (`check_later_changes!`, 34-50). `delete_observation` (applier 217-229) and
  `stale_memory` (40-73) already rely on this. `supersede!` (97-114) is not usable for contradictions: it creates a
  replacement and requires the same entity (151), while detector pairs span 1-hop neighbours.
- **Review plumbing a new kind needs.** `signature_for` returns `nil` for unknown kinds (357-358), and `seed_report`
  skips items without a signature (180-181), so a `contradiction` item is dropped today. `edit_item` (80-90) +
  `validate_edits!` (540-560) accept **any** edit for kinds without a `when` branch. `apply_maintenance_review` takes a
  free-form `action_params` hash (`apply_maintenance_review_tool.rb:28`); its description (16-21) is pinned by
  `spec/mcp/tools_list_snapshot_spec.rb` (re-record per its line 9). The old page permits action params in
  `compaction_action_params` (`data_exchange_controller.rb:764-767`) and renders kinds in two `case` blocks of
  `_compaction_review_item.html.haml` (`stale_memory` details 119-129 and description 188-193; buttons 194-204).
- **Jobs.** `config/recurring.yml`: production compaction 3:00, stale scan 4:30, embedding backfill 4:00, row cleanup
  5:15, change-set prune 5:30 (GMT). `MaintenanceReportRowCleanupJob` (25 lines) deletes approved/dismissed/ignored
  rows older than the retention (19-23); **suppressions are never pruned**.

## Scope

In (UI-5a): the §2.5.1 columns and indexes, `expired` status, expiring suppressions with `source`; **`contradiction`
rows** (signature, classification, seeding from the stale scan, apply = keep one side, undo through the existing
`review.apply` set, minimal buttons on the old page);
`ReviewRowClassifier` (group key, anchor, project, confidence, priority, `RUN_CAPS`) called at seed time plus an
idempotent backfill; symmetric `relates_to` dedupe; backlog ceiling, per-run caps, `MIN_QUEUE_SCORE` (default 0);
SQL pagination; `resolved_by` / `change_set_id` on rows and the undo handle returned by review actions; a server-side
safe-bulk whitelist; `ReviewPolicyRunner` + `ReviewPolicyJob` (hygiene policies on, auto-apply off) with
`review_policy_run` reports and the policy `AppSettings` fields (defaults only; no panel yet).

In (UI-5b): Settings › Review policies (panel, range validation, audited); `CompactionReviewApplier.preview`
(including `contradiction`); the contradiction detail pane; `ReviewGroupActions` (preview, apply safe-bulk groups, dismiss,
snooze; cap 100); `ReviewDigest`; `ReviewController` and `/review` routes with the left rail, digest, grouped lists,
detail pane, Resolved view with Undo/Restore and the "not undoable" reason, Policies view; Undo in toasts through
`POST /changes/:uuid/undo`; keyboard shortcuts; nav badge = attention groups; removal of the `data_exchange`
review actions and views (GET redirects to `/review`); release 1.58.0.

Out (later PRs): contradiction detection itself (the polarity heuristic, thresholds and when it runs stay as they are);
seeding from the MCP/API `detect_contradictions` calls; Home/Activity cards for policy runs (UI-2); the Explore merge
dialog and `EntityMergePreview` (UI-4b); moving the settings panel under System (UI-7); the "Generate" panel's
buttons beyond links to the existing maintenance actions; any MCP or `/api/v1` write path to the policy settings;
undo of hard deletes.

## A1. Schema and models

1. Migration `add_review_grouping_to_maintenance_report_rows` (timestamp after `20261026120100`), reversible:
   - `maintenance_report_rows`: `group_key` varchar(191) NULL, `anchor_entity_id` bigint NULL, `project_id` bigint
     NULL, `priority` int NOT NULL DEFAULT 0, `confidence` decimal(4,3) NULL, `expires_at` datetime(6) NULL,
     `resolved_by` varchar(64) NULL, `change_set_id` bigint NULL.
   - Indexes: `(report_type, status, priority)`, `(report_type, status, group_key)`, `(project_id, status)`,
     `(expires_at)`, `(change_set_id)`. No foreign keys (rows outlive change sets the prune job empties; anchors can be
     deleted: that is what the `dangling` policy looks for).
   - `maintenance_report_suppressions`: `expires_at` datetime(6) NULL (NULL = permanent), `source` varchar(16) NOT NULL
     DEFAULT `'dismissed'` (`dismissed`, `snoozed`, `expired`, `policy`), index `(expires_at)`.
   - **Schema only, no data backfill in the migration** (Decision 3). `git diff db/structure.sql`: only these lines
     change; every `vector(768)`, `VECTOR KEY` and trigger line stays.
2. `MaintenanceReportRow`: `STATUSES` gains `expired`; scopes `expired`, `resolved` (approved/dismissed/expired),
   `snoozed` (ignored with `expires_at`), `attention(threshold)` (`active.where("priority >= ?", threshold)`),
   `by_group`, `by_project`; `resolved?` includes `expired`. `RESOLVERS = %w[operator agent policy generator]` checked
   by prefix (`policy:<name>`).
3. `MaintenanceReportSuppression`: `SOURCES`; scope `in_force` (`expires_at IS NULL OR expires_at > NOW()`);
   `suppressed?` uses `in_force`; `self.replace!(report_type:, signature:, kind:, reason:, source:, expires_at:)`
   deletes any existing row for the pair and creates the new one, returning `[deleted_attrs, created]` so callers can
   `note_suppressions!(created:, deleted:)` (the unique key means an expired or snoozed suppression must be replaced,
   never silently kept: see A4).
4. `MaintenanceReport::REPORT_TYPES` gains `review_policy_run`.
5. `CompactionReviewService::STATUSES` follows the model; `list_maintenance_review` accepts `expired` in its
   description (`app/tools/list_maintenance_review_tool.rb:20, 29`); the four MCP review tools keep their arguments.

## A2. Classification at seed time, backfill and symmetric dedupe

1. New `app/services/review_row_classifier.rb` (target < 300 lines; move per-kind lookups to
   `review_row_classifier/anchors.rb` if needed). `ReviewRowClassifier.call(row_or_attrs)` returns
   `{ group_key:, anchor_entity_id:, project_id:, confidence:, priority: }`:
   - **Anchor and group key** (§2.5.1): single-anchor kinds `orphan_parent`, `stale_memory`, `entity_error`,
     `embedding_backfill_failed`, `lifecycle_corruption`, `delete_entity`, `reparent_entity` → `"<kind>|<entity_id>"`;
     pair kinds `entity_merge`, `relationship_proposal`, `relation_integrity` → `"<kind>|<min>-<max>"` (both
     directions collapse; anchor = the lower id); `contradiction` → `"contradiction|<min>-<max>"` over the **owner entities** of its two observations (`<id>-<id>` when
     both belong to one entity; anchor = the lower owner id; owners come from the payload, A5.2); observation kinds
     `delete_observation`, `move_observation` →
     `"<kind>|obs:<owner entity id>"` (owner looked up from `observation_id`); `delete_relation` → pair key of the
     relation's endpoints (looked up from `relation_id`; a missing relation gives `"<kind>|row:<id>"` and the
     `dangling` policy picks it up); `dismiss_compaction_review` → `"<kind>|<review_item_id>"`; unknown kinds →
     `"<kind>|row:<row_uuid>"`. Payload keys vary per generator (see the seed sites above): read them through
     `effective_payload`, never assume one shape, and pin every generator's real shape in the spec table.
   - **project_id** = the anchor's `project_id` (NULL = global or anchor gone).
   - **confidence** and **impact**: exactly the §2.5.1 table (constants `CONFIDENCE`, `IMPACT`, one spec table pins
     them). `relationship_proposal`: band high 0.9 / medium 0.6 / low 0.3, nudged by `score` inside the band (±0.05,
     never across bands). `entity_merge`: `min(score / 24, 1) × (1 − cosine_distance)`. `orphan_parent`: top
     suggestion score ÷ the matcher's max. `stale_memory`: per signal. Errors: 1.0. Scan destructive kinds: 0.7. `contradiction`: the detector's
     `confidence` from the payload (already ≤ 0.99), impact 0.6 (the §2.5.1 row).
   - **priority** = `round(100 × (0.6 × impact + 0.4 × confidence) × age_boost)` clamped 0-100, `age_boost = 1 +
     min(age_days, 14) / 28`, plus `DEGREE_BUMP` when the anchor has > 20 relations (one COUNT per anchor, cached per
     call). Error kinds get at least `ATTENTION_FLOOR_ERRORS` (= the attention threshold) so they always surface.
   - `RUN_CAPS = { "relationship_proposal" => 200, "entity_merge" => 100, "orphan_parent" => 100, "contradiction" => 100 }`.
   - `DESTRUCTIVE_KINDS = %w[entity_merge delete_entity delete_relation delete_observation reparent_entity
     move_observation]`, `SAFE_BULK_KINDS = %w[relationship_proposal stale_memory]`, `CHOICE_KINDS = %w[contradiction]` (apply
     needs a per-row choice: never bulk-, group- or policy-applied, but dismiss and snooze work as for any kind). These
     constants are the one source of truth for A3, A5, B1 and C1.
2. `seed_report` (`compaction_review_service.rb:154-200`): classify each item before `create!` and write the five
   columns. Keep the ER_CHECKREAD retry and the absorb path exactly as they are (the r2-r5 concurrency specs must stay
   green unchanged); an absorbing `stale_memory` row is re-classified after the merge of observation ids.
3. **Symmetric dedupe.** `signature_for("relationship_proposal")` orders `from`/`to` when
   `RelationSemantics.symmetric?(relation_type)` (276-282). `ReviewRowClassifier.backfill!(batch_size: 1_000)`
   (idempotent, resumable: works on rows with `group_key IS NULL`, then on active symmetric proposals whose stored
   signature differs from the recomputed one) rewrites those signatures and, where two pending rows now collide,
   keeps the older and dismisses the newer with `resolution_reason "duplicate of #<id>"`, `resolved_by "generator"`.
   Suppressions with an old unordered symmetric signature get an ordered twin (same reason/source), so a dismissed
   B→A keeps blocking A→B. Each batch is its own short transaction; no long transaction on a large table.
4. Run the backfill from (a) `ReviewPolicyRunner` as its first step (bounded to `BACKFILL_PER_RUN = 5_000` rows) and
   (b) `bin/rails review:backfill` (new `lib/tasks/review.rake`, prints progress). Until a row is classified the
   digest treats it as its own group with priority 0 (`COALESCE(group_key, CONCAT(kind, '|row:', id))`).

## A3. Limits at the source, SQL pagination, expiring suppressions, cleanup

1. **Backlog ceiling** (§2.5.4.1): in `seed_report`, per kind, if `active` count ≥ `AppSettings.review_backlog_ceiling`
   (new field, default 300, 50-5,000), seed an item only when its priority beats the current lowest active priority of
   that kind; count the rest as `skipped_backlog_full` in the report's `data`. One COUNT + one MIN per kind per seed
   call, not per item.
2. **Per-run caps** (§2.5.4.2): `seed_report` keeps the top `RUN_CAPS[kind]` items per call by priority and records
   `skipped_run_cap`. `DreamStateCompactor#flush_review_queue!` (301-309) flushes several times per run, so the cap
   is tracked per `source_ref` (sum of earlier reports with the same `source_ref` and kind), not per call.
3. **`RelationshipDiscoveryStrategy::MIN_QUEUE_SCORE = 0`** applied in `dedupe_and_limit` (216-221). No behaviour
   change at 0; the policy-run stats (B1) record apply/dismiss rates per kind and score so Steve can raise it later.
4. **SQL pagination** for `items` (23-33): `scope.order(priority: :desc, id: :asc).page(page).per(PER_PAGE)`
   (Kaminari on the relation, so `total_count`/`total_pages` keep working for `list_maintenance_review`). Keep
   `root_first?` as a tie-breaker only through priority (Project roots get `IMPACT` bump in the classifier) and keep
   `item_score` for MCP output compatibility. `q` stays a values-only search (Decision 8): apply it in Ruby to an
   SQL-ordered scope capped at `SEARCH_SCAN_CAP = 2_000` rows, then `Kaminari.paginate_array`; the page says when the
   cap was hit.
5. **Expiring suppressions in the seed path.** `MaintenanceReportSuppression.suppressed?` honours `expires_at`
   (A1.3). `CompactionReviewService.suppressed?` (260-266) ignores rows in `expired` status (their suppression decides)
   and keeps today's "any other row with the signature" rule.
6. **Safe-bulk whitelist on the server.** `bulk_apply_rows` (408-437) skips any row whose kind is not in
   `ReviewRowClassifier::SAFE_BULK_KINDS`, counting it as "not bulk-applicable" in the message. This closes the
   current gap where a merge or `delete_entity` can be bulk-applied (and a merge mixed with other writes makes the set
   `mixed_merge`, not undoable).
7. **Cleanup.** `MaintenanceReportRowCleanupJob` (19-23) also prunes `expired` rows, and deletes suppressions whose
   `expires_at` passed more than `retention_days` ago. Keep the set-based deletes and the re-check comment.
8. **Shrink the service.** Move the read side (`items`, counts, `delete_children_info`, `filter_by_query`,
   `payload_values`) into `app/services/compaction_review_service/queries.rb` (extended like `ChangeRecording`) and
   replace the private `transient_lock_error?`/`checkread?` (476-483) with `TransientDbError.retryable?` (same
   behaviour). `compaction_review_service.rb` ends under ~500 lines.

## A4. Change-set links on rows and the undo handle

1. **`resolved_by`** is derived from `Current.actor` when a row reaches `approved`/`dismissed`/`expired` (and cleared on
   `restore`): `operator:*` → `operator`, `mcp:*`/`api:*` → `agent`, `policy:<name>` → itself, nil/other →
   `generator` (`GraphifyRescan` 314/381 and `ProjectScanner:787` set `generator` explicitly).
2. **`change_set_id`**: inside `track_review_row`, after the row update, call `Current.change_set&.persist!` and write
   `change_set_id` with the row update (so the review fields "after" include it). Add `resolved_by`,
   `change_set_id` and `expires_at` to `ChangeRecording::REVIEW_FIELDS` (9) so `ChangeSetUndo::ReviewRows` restores
   them. Entries written by 1.57.0 lack these keys: `ReviewRows#revert_row` slices `entry["before"]` (36), so missing
   keys are left untouched; pin that with a spec using a 1.57.0-shaped entry.
3. **The undo handle.** `record_review` (23-26) returns the block's value merged with `change_set_uuid:` (nil when no
   row was written) and `undoable:`/`not_undoable_reason:` read from the persisted set, for hash results only. Every
   action keeps its current hash keys (`success`, `message`, `error`), so MCP tools and specs are unaffected.
4. **Suppressions through `replace!`.** `suppress` (608-621) writes the new reason (take it as an argument from
   `dismiss`/`bulk_dismiss` instead of reading the stale `row.resolution_reason`) and uses
   `MaintenanceReportSuppression.replace!` with `source: "dismissed"`, `expires_at: nil`, so dismissing a snoozed or
   expired signature makes it permanent; both the deleted and the created suppression are noted, so undo restores the
   expiring one.
5. **Snooze** (new `CompactionReviewService.snooze(item_id, days: 30)`, kind `review.snooze` added to
   `ChangeSet::KINDS` and `PAST_TENSE`): status `ignored`, `expires_at = now + days`, suppression `replace!` with
   `source: "snoozed"` and the same `expires_at`. `ignore` (146-152) becomes `snooze` with the default 30 days
   (Decision 5); `dismiss_maintenance_review action: ignore` keeps working and now snoozes. Rows already `ignored`
   (including absorbed `stale_memory` losers, 256) keep `expires_at NULL` and are never auto-restored.

## A5. `contradiction` rows (backend; Steve's decision: in UI-5)

The detector and its report stay as they are; A5 adds a review row per candidate pair found by the **scheduled** stale
scan, an apply that keeps one observation and retires the other, and undo through what UI-4a already ships.

1. **Signature (order-independent).** `signature_for` gets a `when "contradiction"` branch (before the `else`,
   357-358): `ids = [payload[:observation_id_1], payload[:observation_id_2]].compact.map(&:to_i).uniq.sort`; `nil`
   unless `ids.size == 2`; result `"contradiction|<low>-<high>"`. `(a,b)` and `(b,a)` give the same signature, so the
   existing pending-duplicate check (`seed_report` 183) and suppressions (182) dedupe re-detections, and a dismissal
   ("both are right") suppresses the pair for good. Spec both orders.
2. **Payload.** `ContradictionDetector.review_item(result)` (new public class method, one query for both
   observations): `{ kind: "contradiction", observation_id_1: low, observation_id_2: high, entity_id_1:, entity_id_2:,
   entity_name_1:, entity_name_2:, content_1:, content_2:` (each truncated to 300 characters for display; apply always
   re-reads the live observations) `, distance:, confidence:, detected_at: }`, ids normalised low → high whatever the
   `Result` order. Returns `nil` when either observation is gone or inactive.
3. **Seeding path (scheduled scan only).** `StaleMemoryScanner.detect_contradictions` (144-161) collects the `Result`s
   that `ContradictionDetector.detect(entity_id)` already returns (154; `persist: true` stays, so the `contradictions`
   report is still written) and maps them through `review_item`, de-duplicated by signature across entities. `scan`
   (53-59) returns them under a **new key** `contradiction_items:` (the `items` array and its specs stay unchanged); on
   error the pass returns `[]` with the previous watermark, as today. `StaleMemoryScanJob` (17-24) seeds `items +
   contradiction_items` in the same `seed_report` call (same `source_ref`), and its report gains
   `contradictions_seeded:` next to `by_signal` (30). MCP `detect_contradictions` and `/api/v1 …/detect_contradictions`
   don't seed rows (they stay read-and-report tools).
4. **Classification and limits.** A2's classifier handles the kind (group key over owner entities, confidence from the
   payload, impact 0.6); `RUN_CAPS["contradiction"] = 100` and the A3 backlog ceiling apply like any kind.
5. **Apply = keep one side.** `CompactionReviewApplier.apply` (7-36) dispatches `contradiction` to a new
   `CompactionReviewApplier::Contradiction.apply(effective, action_params)` (new file
   `app/services/compaction_review_applier/contradiction.rb`, keeps the applier small):
   - `action_params[:keep_observation_id]` is required and must be one of the pair; otherwise `{ success: false,
     error: "Choose which observation to keep (##{low} or ##{high})" }` (no write, no change set: `record_review`
     only persists a set once a row or audit write happens).
   - Re-check at apply time (the graph moves between scan and apply, as `apply_stale_memory` does): the kept
     observation must exist and be active, else fail with "Observation #N is no longer active; dismiss this row or
     restore it first". If the retired side is already inactive or gone, succeed without a write ("already
     inactive") so the row is closed.
   - Otherwise `retired.mark_obsolete!(reason: "Contradicted by observation ##{keep_id} (contradiction review)")`.
     Nothing is created, re-parented or merged; the kept observation is not touched.
   - Runs inside `apply_row` (376-406) exactly like every kind: membership lock first, then row lock + re-check.
6. **Undo: no new kind.** The apply runs under the existing `record_review("apply", …)` → change set kind
   **`review.apply`**, strategy **`audit`**, window **30 days**: the obsolete mark is one audited `update`
   (`Auditable#audit_update`), so `ChangeSetUndo::AuditInverse` re-activates the observation (status, `obsoleted_at`,
   `obsolescence_reason` back to their `from` values) and `ReviewRows` puts the row back to `active`. If the
   observation was edited since, undo answers **409** with "changed since" (existing `check_later_changes!`), as for
   `delete_observation`. An "already inactive" apply has only the row in its set; undo reopens the row. Dismiss =
   `review.dismiss` (permanent suppression), snooze = `review.snooze` (A4.5), group dismiss/snooze in UI-5b =
   `review.group_dismiss` / `review.group_snooze`. A spec applies, undoes and re-applies (redo) one row end to end.
7. **Edits refused.** `validate_edits!` (540-560) gets a `when "contradiction"` branch that raises the same
   invalid-edit error the other kinds use ("Contradiction rows can't be edited; choose which observation to keep"),
   so `edited_payload` can never point the row at other observations.
8. **MCP.** `apply_maintenance_review`'s description (16-21) and the `action_params` text (28) mention
   `contradiction` rows and `keep_observation_id`; re-record the MCP list snapshots as
   `spec/mcp/tools_list_snapshot_spec.rb` (line 9) asks and say so in the PR. `dry_run` keeps echoing the payload
   until C1 adds the preview.
9. **Old page (throwaway, removed in C3).** `compaction_action_params` (764-767) permits `:keep_observation_id`; the
   item partial gets `when "contradiction"` in both `case` blocks (the two observations with their entities, distance,
   confidence) and, for this kind only, replaces the single Apply (197) with **Keep #low** / **Keep #high** buttons
   (`name: "keep_observation_id"`, same `turbo_confirm`) and hides Save. About 30 lines; keeps UI-5a usable on
   today's page.

## B1. Policy runner, job and schedule

1. New `app/services/review_policy_runner.rb` (< 300 lines; one small class per policy under
   `app/services/review_policies/` if it grows). `ReviewPolicyRunner.call(trigger:)` → a summary hash; it writes one
   `MaintenanceReport` (`review_policy_run`) with per-policy counts, skipped reasons, the change-set uuids, and
   apply/dismiss rates per kind and score bucket (for `MIN_QUEUE_SCORE` tuning).
2. Order per run: backfill step (A2.4) → priority refresh of active rows (batches of 1,000, `update_columns`, no
   change set: priority is derived data) → `snooze_expiry` → `dangling` → `no_longer_flagged` →
   `expire_low_confidence` → `auto_apply_expired_validity` → `auto_apply_relationships`.
3. Policies (each reads its `AppSettings` toggle **uncached** at the start of the run):

   | Policy | Default | Does | Change set |
   |---|---|---|---|
   | `dangling` | on | active/ignored rows whose referenced entities, observations or relations are gone, or whose effect already holds (relation exists, observation obsolete, entity already under the parent; for
`contradiction`: either observation gone or no longer active) → `dismissed`, reason `"dangling: entity #12 gone"`, **no suppression** | `policy.dangling` |
   | `no_longer_flagged` | on | active `stale_memory` rows where `StaleMemoryScanner.still_flagged_ids` is empty → `dismissed`, no suppression | `policy.no_longer_flagged` |
   | `expire_low_confidence` | on, 30 days | active rows with `confidence < 0.4` and `updated_at` older than N days → `expired` + suppression `source "expired"`, `expires_at = now + 90 days` | `policy.expire_low_confidence` |
   | `auto_apply_relationships` | **off** | active `relationship_proposal`, band `high`, `confidence ≥ threshold` (default 0.90, 0.80-1.00), canonical type ≠ `part_of` → apply through `CompactionReviewService.apply`; max 50 per run | `policy.auto_apply_relationships` |
   | `auto_apply_expired_validity` | **off** | active `stale_memory` with signal `valid_until_elapsed` → apply (obsolete marks); max 100 per run | `policy.auto_apply_expired_validity` |
   | `snooze_expiry` | always | `ignored` rows with `expires_at` passed → `active`, `expires_at NULL`, delete the `snoozed` suppression | `policy.snooze_expiry` |

4. **Hard rule:** before any apply, the runner refuses kinds in `ReviewRowClassifier::DESTRUCTIVE_KINDS` or
   `CHOICE_KINDS` and any kind not in `SAFE_BULK_KINDS`, whatever the settings say (a spec tampers with the settings and the kind list).
5. **Change sets.** One set per policy per batch of at most `POLICY_BATCH = 200` rows, actor `policy:<name>`, kind
   `policy.<name>` (already accepted by `KIND_PATTERNS`), summary like `"policy dangling: dismissed 37 rows"`. Rows get
   `resolved_by "policy:<name>"` and `change_set_id`. Hygiene policies only touch review rows and suppressions (strategy
   `audit`, undone by `ReviewRows`); auto-apply sets contain relation creates or obsolete marks (strategy `audit`, 30
   days). No policy can produce a `merge`, `mixed_merge` or `hard_delete` set.
6. **Locks and concurrency.** Hygiene policies: per row `row.with_lock` + reload + status re-check (an operator action
   in between wins; the row is skipped), no membership lock. Auto-apply goes through `CompactionReviewService.apply`
   (membership lock first, then row lock: the advisory-first rule). A batch that hits `TransientDbError.retryable?` is
   retried in a fresh transaction up to 3 times, then skipped and counted as `busy`; `ProjectMembership::LockTimeout`
   ends the auto-apply step for this run (`busy`), never the job.
7. `app/jobs/review_policy_job.rb` (`queue_as :low_priority`, `limits_concurrency` key `review_policy` or an advisory
   guard so two runs never overlap). Enqueued: nightly in `config/recurring.yml` (development and production, e.g.
   `at 5:00am every day`, before the 5:15 cleanup), and with `perform_later(trigger:)` at the end of
   `DreamStateCompactionJob`, `StaleMemoryScanJob` and a finished project scan (`ProjectScanner`), only when at least
   one row was seeded. Add a "Run policies now" button (operator, `POST /review/policies/run` in C2).
8. **Settings fields (UI-5a; the panel is B2 in UI-5b).** `AppSettings` fields: `enable_review_policy_dangling` (true),
   `enable_review_policy_no_longer_flagged` (true), `enable_review_policy_expire_low_confidence` (true),
   `review_expire_low_confidence_days` (30, 7-365), `enable_auto_apply_relationships` (**false**),
   `auto_apply_relationship_min_confidence` (0.90, float, 0.80-1.00), `enable_auto_apply_expired_validity` (**false**),
   `review_backlog_ceiling` (300, 50-5,000; used by A3), `review_attention_threshold` (40, 1-100). Uncached readers via
   `read_boolean_setting` (`app_settings.rb:181-189`) and a matching uncached numeric reader that clamps to the
   range. Until UI-5b ships the panel they keep their defaults (Steve can change them from the Rails console); no
   `/api/v1` or MCP write path.

## B2. Settings › Review policies (UI-5b, first commit; operator only, audited)

Moved from UI-5a to UI-5b to make room for A5 (see "Size and split"). The fields already exist (B1.8).

1. Nothing to add to `AppSettings`; the panel edits the B1.8 fields.
2. `Operator::SettingsController#group_settings_by_category` (128-165): new tab `review_policies`; partial
   `app/views/operator/settings/_review_policies_panel.html.haml` (toggles, threshold, days, ceiling, threshold, one line
   per policy explaining what it does and how to reverse it; no inline JS).
3. `bulk_update` (13-78): `validate_review_policies_settings` rejects out-of-range values with **422** (re-render the
   tab with the error, nothing saved), for this tab and for any request that carries these keys. After a successful
   save, write one `AuditLog` per changed key: `auditable_type "AppSettings"`, `auditable_id` = the settings row id,
   `action "update"`, `actor Current.actor`, `changed_fields { key => { from:, to: } }`. Make sure
   `Operator::AuditLogsController` renders such rows (it must not assume a graph record).
4. Neither `/api/v1` nor MCP gets a write path to these fields (no tool, no endpoint).

## C1. Apply preview and group actions (UI-5b)

1. `CompactionReviewApplier.preview(row, action_params = {})` (new `compaction_review_applier/preview.rb` to keep the
   applier under ~500 lines): the same lookups as `apply`, **no writes**, returns `{ ok:, effects: [String],
   warnings: [String], undo: "7 days" | "30 days" | "not undoable: hard delete" }`. Per kind: merge (observations that
   move, relations re-pointed/destroyed, children reparented; reuse the counts `merge_into_once` would see, read-only),
   `relationship_proposal` (exists already? part_of membership effect), `orphan_parent`/`reparent_entity` (subtree
   size), `delete_relation`, `delete_observation` (obsolete mark), `delete_entity` (observations and relations that go,
   children left parentless, **"can't be undone"**), `stale_memory` (observations marked obsolete),
   `relation_integrity`, `move_observation`, `contradiction` (with `keep_observation_id`: "#B marked obsolete, #A
   kept, undoable 30 days"; without it: both outcomes; warns when either side is no longer active). `apply_maintenance_review` `dry_run` returns `preview` too (additive key).
2. New `app/services/review_group_actions.rb`:
   - `preview(group_key:, op:, min_confidence: nil)` → rows included (≤ `GROUP_CAP = 100`, highest priority first),
     rows excluded with the reason (destructive kind, below confidence, not active, over the cap), and the summed
     effects; plus a `token` = SHA256 of the sorted included row ids + op + `min_confidence`.
   - `apply(group_key:, row_uuids:, token:, min_confidence: nil)`: only `SAFE_BULK_KINDS`; re-computes the token over
     the rows still eligible; a mismatch → `:conflict` (409) with the rows that changed, nothing written. One change
     set `review.group_apply` (add to `KINDS`) around per-row `CompactionReviewService.apply` calls.
   - `dismiss(group_key:, row_uuids:, reason:)` (any kind, writes suppressions; `review.group_dismiss`) and
     `snooze(group_key:, row_uuids:, days: 30)` (`review.group_snooze`).
   - Destructive kinds and `CHOICE_KINDS` have no group apply: `preview(op: "apply")` lists every such row as excluded
     ("choose a side per row" for `contradiction`). Group dismiss and snooze include them.

## C2. `ReviewController`, routes, views, toasts with Undo

1. Routes (operator only; none in the role matrix `guest_allowed`):
   - `GET /review` (`index`; `view=attention|kind|project|errors|scan|resolved|policies`, `kind`, `project_id`, `q`,
     `page`), `GET /review/group?key=` (`group`, lazy Turbo Frame, SQL-paginated at 20),
     `GET /review/rows/:uuid` (`show`, detail pane frame), `GET /review/rows/:uuid/preview`,
     `PATCH /review/rows/:uuid` (edit), `POST /review/rows/:uuid/{apply,dismiss,snooze,restore}`,
     `GET /review/group/preview`, `POST /review/group/{apply,dismiss,snooze}`, `POST /review/policies/run`,
     `POST /review/import_suggest_merges` (moved from `data_exchange`).
   - `GET /data_exchange/compaction_review` → `redirect("/review")` (301, keep `report_type=scan_review` as
     `view=scan`); delete `POST /data_exchange/compaction_review_action` and the import route (`routes.rb:87-90`).
2. `app/services/review_digest.rb`: SQL only, constant query count. Attention groups = active rows grouped by
   `COALESCE(group_key, …)` with `MAX(priority) ≥ review_attention_threshold`, ordered by max priority, `LIMIT 10`;
   per group: kind, anchor (one `MemoryEntity.where(id:)` for the page), count, high-confidence count, max confidence,
   oldest `created_at`; plus "N more in M groups below the threshold", "policies resolved X this week" (from
   `review_policy_run` reports), next compaction time from `recurring.yml`. Spans `compaction_review` and `scan_review`.
3. `app/controllers/review_controller.rb` (< 300 lines; result → response mapping in a small concern
   `ReviewResponses`). Response codes, matching `ChangesController::STATUSES`:

   | Case | Status | Toast |
   |---|---|---|
   | success | 200 (Turbo Stream) / 303 redirect (HTML) | message + **Undo** button when `change_set_uuid` present and undoable; otherwise "can't be undone: <reason>" |
   | row not found | 404 | "That suggestion no longer exists." |
   | not actionable (status changed), invalid edit, destructive kind in a group apply | 422 | the service's error |
   | group preview token mismatch | 409 | rows that changed; "Review the preview again" |
   | `ProjectMembership::LockTimeout` or `TransientDbError.busy?` | 503 | `ui.changes.busy` |

   Turbo Stream responses update `#toasts`, the row/group frame (replace or remove, as
   `review_action_turbo_streams` does today, 335-367) and the rail counts.
4. **Undo in the toast and the Resolved view.** `layouts/_flash_messages` gains an optional undo entry
   (`flash[:undo] = { "uuid" => …, "label" => … }`) rendered as `button_to t("ui.changes.undo"),
   undo_change_path(uuid), method: :post, form: { data: { turbo_frame: "_top" } }` (HTML path of `ChangesController`:
   redirect back with its flash, so the page shows the restored state). Undo toasts are not `ui-toast--notice`, so
   `toast_controller.js` doesn't auto-remove them (13-16). The **Resolved** view lists approved, dismissed and expired
   rows with `resolved_by`, time, and per row: **Undo** while the linked set is undoable (`change_set.undoable?`),
   **Restore** otherwise; for `none` sets the reason in words ("entity deleted: can't be undone", "merge mixed with
   other writes: can't be undone"). The **Policies** view lists `review_policy_run` reports with one Undo per change
   set.
5. Views `app/views/review/`: `index` (left rail, digest cards or grouped list), `_digest_card`, `_group_row`,
   `_group` (frame), `_row`, `_detail` (frame) with per-kind partials `kinds/_<kind>.html.haml` split out of the
   204-line `_compaction_review_item.html.haml`, `_preview_card` (confirm card for destructive applies and group
   actions), `kinds/_contradiction.html.haml` (the two observations side by side with entity, age, distance and
   confidence; **Keep this** on each side posts `apply` with `keep_observation_id` through the preview card; Dismiss is
   labelled "Both are right"; Snooze as usual), `_inbox_zero`, `_resolved`, `_policies`. Entity pickers reuse `_entity_search_select` and
   `compaction_review_controller.js` (rename to `review_entity_picker_controller.js`). Confirm levels per §5.2:
   `turbo_confirm` for dismiss/snooze group; a server-rendered preview card (no JS confirm) for destructive applies
   and group apply. Haml escaping only; no `!=`/`html_safe` on payload text.

## C3. Keyboard, nav badge, removal of the old review UI

1. `app/javascript/controllers/review_keys_controller.js`: `j/k` next/previous, `Enter` open, `a` apply (opens the
   preview card for destructive kinds), `d` dismiss, `s` snooze, `e` edit, `r` restore, `x` select, `/` search, `1`/`2` keep the first/second observation of a `contradiction` row (opens
   the preview card, never applies directly), `?`
   help dialog (`<dialog>`, built with `lib/dom.js`, no `innerHTML`). Ignored inside inputs, textareas, selects and
   contenteditable; focus moves to the next item after an action. Pinned in `config/importmap.rb` by the
   controllers' existing pin.
2. Sidebar (`ui/_sidebar.html.haml:4-27`): Review & Fix → `/review`, Scan review → `/review?view=scan`.
   `ui_review_backlog_count` (`ui_helper.rb:55-59`) → `ReviewDigest.attention_group_count`, same cache key and 30 s
   expiry; 0 → no badge.
3. Remove `DataExchangeController#compaction_review`, `#compaction_review_action`, `#review_action_turbo_streams`,
   `#compaction_review_import_suggest_merges` and the helpers only they use (746-776), the five
   `app/views/data_exchange/_compaction_review*` / `compaction_review.html.haml` views (with A5.9's contradiction
   buttons and the `:keep_observation_id` permit), and
   `spec/requests/data_exchange_spec.rb` examples for them (move what still applies to `spec/requests/review_spec.rb`).
   Repoint the dashboard scan card forms (`_project_scans_card.html.haml:92-98`) to
   `POST /review/rows/:uuid/{apply,dismiss}` and the links (101; `_dream_state_compactor_card.html.haml:88`;
   `_reports_details.html.haml:8`) to `/review`.

## D. Docs

- `docs/architecture.md`: a "Review & Fix (UI-5)" section: columns, classifier, digest, limits, policies (table,
  defaults, hard rule), change sets `policy.*`/`review.snooze`/`review.group_*`, `contradiction` rows (seeded by the
  scheduled scan only, keep-one-side apply, undone as `review.apply`), what can't be undone and how the UI says
  so; update "What records a set".
- `docs/guides/ui-guide.md`: the Review page (rail, digest, inbox zero, keyboard shortcuts, Undo/Restore, policies
  panel).
- `docs/mcp_tools.md`: `apply_maintenance_review` on `contradiction` rows needs `action_params.keep_observation_id`;
  `detect_contradictions` unchanged (still no review rows); `ignore` now snoozes for 30 days; `list_maintenance_review` accepts `expired`; `dry_run` returns
  a preview.
- `docs/garbage_collector.md` (or wherever retention is listed): expired rows and suppressions pruned; nightly policy
  run at 5:00.
- `ui-dashboard-plan.md` is not edited by these PRs (Steve updates the plan).

## Specs

All synthetic, test-DB truncate before and after (`ui-dashboard-plan.md` §0.1), full suite run alone.
- UI-5a:
  - `spec/models/maintenance_report_row_spec.rb` / `maintenance_report_suppression_spec.rb`: `expired`, scopes,
    `in_force`, `replace!` (returns deleted + created).
  - `spec/services/review_row_classifier_spec.rb`: the §2.5.1 table per kind with each generator's real payload shape;
    both directions of a pair share a group key; age boost and degree bump; error floor; `backfill!` idempotent and
    resumable, symmetric rewrite keeps the older row and twins old suppressions.
  - `spec/services/compaction_review_service_spec.rb` additions: classification at seed; the ceiling skips
    low-priority seeds and records `skipped_backlog_full`; run caps across several flushes with one `source_ref`; an
    expired suppression lets a signature back in, a snoozed one doesn't until it expires; symmetric dedupe; SQL
    pagination keeps `total_count`; `q` cap; `bulk_apply` skips non-safe kinds; dismiss over a snoozed signature makes
    it permanent and undo brings the snooze back; `change_set_uuid` in results; `resolved_by` per actor. **The r2-r5
    concurrency specs and the `stale_memory` absorption specs stay green and unchanged.**
  - `spec/services/change_set_undo/review_rows_spec.rb` additions: the new fields round-trip; a 1.57.0-shaped entry
    (without them) still undoes.
  - `spec/services/review_policy_runner_spec.rb`: each policy on and off; defaults on a fresh install; destructive
    kinds never applied even with tampered settings/constants; per-run limits; batches of 200 → one set each; every
    action has `resolved_by`/`change_set_id` and its set undoes it; an operator action between select and lock wins;
    `review_policy_run` report contents.
  - `spec/services/review_policy_concurrency_spec.rb` (`self.use_transactional_tests = false`, clean up in `after`):
    a policy batch racing an operator apply on the same row: one wins, the other skips; never a 500, a partial state or
    a leftover lock.
  - `spec/jobs/review_policy_job_spec.rb` (no overlap; enqueued after compaction/stale scan/project scan only when
    rows were seeded); `spec/jobs/maintenance_report_row_cleanup_job_spec.rb` additions.
  - Contradictions (A5): `spec/services/compaction_review_service_spec.rb` (signature equal for both orders, `nil`
    for one id; a re-detected pair is not seeded twice; a dismissed pair stays suppressed; edits refused);
    `spec/services/contradiction_detector_spec.rb` (`review_item` normalises low → high, `nil` for an inactive side);
    `spec/services/stale_memory_scanner_spec.rb` / `spec/jobs/stale_memory_scan_job_spec.rb` (with the detector stubbed
    to return synthetic `Result`s: `contradiction_items` seeded with the scan's `source_ref`, `contradictions_seeded`
    in the report, a detector error seeds nothing and keeps the watermark; `items` and `by_signal` unchanged);
    `spec/services/compaction_review_applier/contradiction_spec.rb` (missing or foreign `keep_observation_id` → error,
    nothing written; kept side inactive → error; retired side already inactive → success without a write; normal
    apply marks only the other side obsolete); `spec/services/change_set_undo/contradiction_undo_spec.rb` (apply →
    `review.apply` set, strategy `audit`, 30 days → undo re-activates the observation and reopens the row → redo;
    an edit to the retired observation in between → 409 conflict); classifier table row and group key over owner
    entities; `dangling` dismisses a pair with an inactive side; `bulk_apply` and the policy hard rule skip
    `contradiction`; `spec/tools/apply_maintenance_review_tool_spec.rb` (`keep_observation_id` passes through);
    the old page's Keep buttons in `spec/requests/data_exchange_spec.rb`; MCP list snapshots re-recorded.
  - `spec/models/app_settings_spec.rb` additions: B1.8 defaults (both auto-apply toggles off) and numeric clamping.
  - `spec/requests/role_matrix_spec.rb`: add `MaintenanceReportSuppression.count` to `record_counts` (68-70).
- UI-5b:
  - `spec/requests/operator/review_policy_settings_spec.rb` (B2): fresh install both auto-apply toggles off; each
    toggles independently; threshold 0.79 / 1.01 → 422 and nothing saved, 0.85 → saved and used by the next run; guest
    403, signed out → login; each change writes an `AuditLog` row; the audit log page renders it.
  - `spec/services/compaction_review_applier_preview_spec.rb`: preview == apply effects for merge, reparent,
    delete_relation, delete_observation, stale_memory, relationship_proposal, contradiction (each side); `delete_entity` says not undoable; the
    preview writes nothing (no audit rows, change sets, row or suppression changes).
  - `spec/services/review_group_actions_spec.rb`: destructive kinds and `contradiction` excluded from group apply, nothing changed;
    group dismiss/snooze include `contradiction`; cap 100; the preview
    lists exactly the rows applied; token mismatch → conflict, nothing written; snooze writes an expiring suppression;
    one change set per group action, undoable.
  - `spec/services/review_digest_spec.rb`: top 10 groups by priority; inbox zero when nothing ≥ threshold; query count
    constant from 10 to 1,000 rows (`ActiveSupport::Notifications` counter); unclassified rows show as single groups.
  - `spec/requests/review_spec.rb`: every route and action per kind; 200/404/409/422/503 as in the C2 table
    (stub `LockTimeout` and a `TransientDbError.busy?` error); toast has Undo when undoable and the reason when not;
    guest 403 and signed out → login on every route; CSRF required; the old GET redirects with `view=scan`.
  - `spec/system/review_spec.rb`: digest → apply a high-confidence group (preview card) → Undo from the toast → inbox
    zero; keyboard `j`/`d` moves focus and dismisses, and shortcuts don't fire inside the search field; a
    `contradiction` row: Keep this → preview card → applied → Undo from the toast brings the observation back.
  - `spec/system/navigation_spec.rb`: badge counts attention groups; guest sees no Review link.
  - `spec/javascript_sinks_spec.rb` stays green (no new `innerHTML` sinks).
- All existing review, dream-state, scan and undo specs stay green **unchanged** (except adding assertions and moving
  the removed `data_exchange` examples).

## Release: 1.58.0 (commit R, UI-5b)

- `lib/graph_mem/version.rb:4`: `"1.57.0"` → `"1.58.0"`.
- `skills/graph-mem-mcp-toolset/SKILL.md:18`: `graph-mem-version: "1.57.0"` → `"1.58.0"`
  (`spec/docs/agent_text_sync_spec.rb` checks they match).
- `CHANGELOG.md`: rename UI-5a's `## [Unreleased]` lines into `## [1.58.0] - <merge date>` with `### Added` (grouped
  Review & Fix page, digest and inbox zero, group actions with preview, apply preview, review policies and their
  settings, `contradiction` review rows with keep-one-side apply, Undo/Restore in the UI, keyboard shortcuts), `### Changed` (`ignore` snoozes for 30 days; queue sorted by
  normalized priority; generation limits; symmetric `relates_to` dedupe; nav badge counts attention groups; old review
  URLs redirect), `### Removed` (the `data_exchange` review actions), `### Fixed` (bulk apply could include destructive
  kinds; a busy membership lock on a review apply returned 500; dismiss reason missing on the suppression).

## Size and split

Estimate (revised with `contradiction` rows): **about 5,900-6,600 changed lines, roughly half specs** (A1-A4 ≈ 1,500,
A5 ≈ 550 (≈ 200 code incl. ~30 throwaway old-page lines, ≈ 350 specs), B1 ≈ 800, B2 ≈ 400, C ≈ 2,300 + ≈ 200 for the
contradiction pane/preview/keys, D+R ≈ 280). For reference, UI-4a was estimated at 2,400-2,800 and landed at ~3,100
(`v1.56.0..v1.57.0`: 50 files, +2,994/−113).

**Two PRs (Steve confirmed).** With A5 added to the original UI-5a (A1-A4, B1, B2), UI-5a would be ≈ 3,350-3,650, past
the ~3,500 stop line. **Move applied: B2 (the settings panel, its validation and the settings audit) goes to UI-5b**;
its fields stay in UI-5a (B1.8) because the runner and the ceiling read them.
- **UI-5a** (A1-A5, B1, D for those parts), **≈ 3,000-3,300**: data model, classifier, limits, expiring suppressions,
  undo links, `contradiction` rows, policies with default settings. CHANGELOG under `## [Unreleased]`, **no version
  bump**. Branch `claude/ui-5a-review-backend`. It works on today's page (rows get classified, limited and cleaned up;
  contradiction rows get Keep buttons).
- **UI-5b** (B2, C1-C3, rest of D, R), **≈ 2,900-3,300**: settings panel, preview, group actions, digest, the page,
  keyboard, removal, **1.58.0**. Branch `claude/ui-5-1.58.0`. Group actions and the preview stay here because the page
  is their only consumer (the same reasoning as UI-4a's Decision 2).
If either PR still passes ~3,500 lines: from UI-5a, move A5.9 (old-page buttons) out and let contradiction rows wait for
the new page; from UI-5b, move C3.1 (keyboard) to a follow-up. Stop and propose; don't move steps on your own.

## Decisions

Steve answered on 2026-10-26: decisions marked **(Steve)** are his and are not to be changed in the PRs; the rest stay
changeable defaults.

1. **Two PRs (Steve, confirmed)**: UI-5a and UI-5b as in "Size and split" (B2 moved to UI-5b for size).
2. **No new undo machinery.** Every UI-5 write goes through `ChangeSet.record` and is undone by the existing
   `ChangeSetUndo` + `ReviewRows`; UI-5 only adds kinds (`review.snooze`, `review.group_apply`,
   `review.group_dismiss`, `review.group_snooze`, plus `policy.*` already allowed) and review fields.
3. **Backfill outside the migration.** The migration is schema-only; `ReviewRowClassifier.backfill!` runs from the
   policy runner (bounded per run) and `bin/rails review:backfill`. Migrations calling app code break later; a bounded
   job can't hold a long transaction.
4. **Policy change sets: one per policy per batch of ≤ 200 rows (Steve, confirmed)**, so "Undo run" is one click and a set stays far under
   the 4 MB snapshot cap; undoing one batch is all-or-nothing for that batch.
5. **`ignore` becomes snooze (30 days) (Steve, confirmed)** everywhere, including the MCP tool; existing `ignored` rows keep
   `expires_at NULL` and never auto-return. Row `expires_at` is only the snooze end; `expire_low_confidence` uses
   `updated_at`.
6. **`contradiction` rows are in UI-5 (Steve, changed from "deferred").** Backend in UI-5a (A5: order-independent
   signature `contradiction|<low obs id>-<high obs id>`, seeding from the scheduled stale scan only, apply = keep one
   side via `keep_observation_id` and mark the other obsolete); page in UI-5b (detail pane, preview, keys). No new
   change-set kind: the apply is a `review.apply` set with strategy `audit` (30 days), undone by the existing
   `AuditInverse` + `ReviewRows`. Never bulk-, group- or policy-applied (`CHOICE_KINDS`).
7. **Digest spans compaction and scan review**, ranked together by normalized priority; the Scan review view stays.
8. **Search stays values-only**, in Ruby over at most 2,000 SQL-ordered rows (no new search column or full-text index).
9. **Old URLs (Steve, confirmed):** the old GET redirects to `/review` (301); the old POST and import routes are removed (only the app
   used them); MCP tools are unchanged apart from Decision 5.
10. **Settings panel in `/operator/settings`** (tab `review_policies`), audited as `AuditLog` rows on `AppSettings`;
    UI-7 moves it under System.
11. **Undo toasts don't time out**; the Resolved and Policies views are the durable Undo entry points for the whole
    window (UI-4b owns the 10-minute toast rule for Explore).
12. **Hygiene policies start on** (Steve's §2.5.3 decision) but drain gradually: per-run caps (`dangling` and
    `expire_low_confidence` ≤ 500 rows per run) so the first nightly run after deploy can't dismiss the whole queue
    at once; every batch is undoable for 30 days.

## Acceptance criteria

- With 1,000 synthetic rows (factory script), `/review` shows ≤ 10 decisions by default; its query count doesn't
  depend on queue size; inbox zero appears when nothing is ≥ the threshold.
- Nothing destructive or `contradiction` can be bulk-, group- or policy-applied (server-side, specs try); `bulk_apply`
  skips non-safe kinds.
- A contradiction pair found by the scheduled scan appears once (either order), applying "keep A" marks only B
  obsolete, and Undo re-activates B and reopens the row; MCP/API `detect_contradictions` writes no review row.
- Policies are on/off exactly per the B1 defaults on a fresh install; each action has a `policy.<name>` change set,
  `resolved_by` and `change_set_id`, and can be undone from the Policies view or restored per row.
- Every review action's toast offers Undo when its set is undoable and says why when not (hard delete, mixed merge);
  undo answers 200/409/422/404/503 through the existing endpoint; review actions answer 404/409/422/503 as in C2.
- Guests get 403 on every `/review` route and the settings tab, and no row, suppression or change set is written
  (role matrix); `/mcp*` and `/api/v1` unchanged apart from Decision 5.
- Migration reversible; `db/structure.sql` keeps every vector column, `VECTOR KEY` and trigger; `db/schema.rb`
  untouched; CSP enforced with zero new violations (no inline scripts or handlers).
- Required specs green; the **full suite run alone** green; `bin/rubocop` and `bin/brakeman` clean; the test DB has 0
  rows in every table before and after; files under ~500 lines (`compaction_review_service.rb` included), methods
  under ~60; no `alert()`/`confirm()`, no `innerHTML` with interpolated data.
- UI-5b: version 1.58.0 in `version.rb` and `SKILL.md`; CHANGELOG entry; docs updated; PR body with screenshots on
  synthetic data (digest, group preview, Resolved with an Undo and a "can't be undone", Policies, inbox zero).
- Each PR against `main`, CI green; fix the review bot's should-fix findings with new commits; no force-push after
  review.

## Stop and ask Steve if

- any quoted line no longer matches the code, or `main` isn't at 1.57.0 (UI-5a) / doesn't contain UI-5a (UI-5b) when
  you start;
- a generator's payload shape doesn't let the classifier find an anchor without guessing;
- the contradiction apply would need anything beyond an obsolete mark (a supersede, a new observation, a merge), undo of
  it would need a new change-set kind or strategy, or the scanner change would alter the `items` its specs pin;
- an existing review, dream-state, scan or undo spec needs changing (not just extending) to pass, especially the
  r2-r5 concurrency and `stale_memory` absorption specs;
- the migration diff drops or rewrites a vector column, `VECTOR KEY` or trigger line;
- a policy or group action would need a `merge`, `mixed_merge` or `hard_delete` set, or a lock outside the
  advisory-first order;
- the audit log page can't render an `AppSettings` audit row without a larger change;
- a route can't be classified in the role matrix, or anything seems to need an MCP tool or `/api/v1` endpoint;
- either PR grows past ~3,500 changed lines (then propose the move in "Size and split").
