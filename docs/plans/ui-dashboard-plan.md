# graph_mem operator UI plan: declutter, one operator flow, safe edits (FINAL)

**Final version, 2026-10-21 (Europe/Rome)**, written for Steve, for **Claude** to implement locally, with simple step lists for Devin.
**Oct 22-b update** (Steve's answers, 10:44; `ui-dashboard-plan.2026-10-22-b.md` is the version before it). Only the release train changed: the agent-rules rewrite ships first as graph_mem 1.53.0, the hardening bundle (incl. UI-0) is now **1.54.0**, PR-4 / fast-mcp 1.9.0 is replaced by a migration to the official `mcp` gem (1.55.0–1.58.0), and the UI series is renumbered to **1.59.0–1.66.0** (UI-1 … UI-7). No UI content changed.
**Oct 22-c update** (17:15; `ui-dashboard-plan.2026-10-22-c.md` is the version before it). **UI-0 is DONE** in PR #106 (merged Oct 22 as `f9febd6`, PR head `bbda8b9`, CI green). #106 adds a `## [Unreleased]` › Security section and doesn't bump the version, so UI-0 is released with the next release commit, **1.53.0** (the rules rewrite). **No version number moved.** 1.54.0 is now PR-0 + PR-2. #106's leftover low items are small tasks in mcp plan PR-2 §2.20 (§6 UI-0 below lists them). §6.D-4 is shorter because #106 already deleted `data_manage.js`. Step 0 has its real status (§0.3 row 0).
**Oct 26 update** (Steve, Oct 26). The MCP track is **done**: everything up to the migration to the official `mcp` gem shipped as 1.53.0–1.55.2 (last PRs #118, #119, #120, #121). The order of the remaining work is now: the chores **D-1, D-2 and D-3 as one PR → 1.55.3** (step list: `docs/plans/chores-d1-d3-plan.md`), then **UI-1 → 1.56.0**, then **UI-4a and UI-5** pulled ahead of UI-2, UI-3 and UI-4b. §0.3 and the §6 headings carry the new versions; the §0.3 table is authoritative, and older version numbers quoted elsewhere in this file (1.59.0–1.66.0 for the UI series) are the pre-Oct-26 numbering. M-D1 and M-D2 were never merged; their branches are deleted and the work is carried as §6.D D-7 and D-8. The completed plans folder (`docs/plans/done/`) and the streamlined migration plan were removed.
**Oct 26-b update.** **UI-1 is DONE** as two PRs, UI-1a (#123) and UI-1b (#124), released as **1.56.0**. **UI-4a is next**; its step list is `docs/plans/ui-4a-plan.md` (verified against the 1.56.0 code). It replaces §5.3 and §6 UI-4a where they differ; the main differences: the merge preview, `EntityMergeService` and the digest check move to UI-4b, change sets are written lazily (no new transaction or lock), one set can hold several merge snapshots, and §5.3 step 8 is dropped (merges don't close review rows).
**Oct 26-c update.** **UI-4a is DONE** in PR #127 (merged and tagged as **1.57.0**, `e826476`). **UI-5 is next**; its step list is `docs/plans/ui-5-plan.md` (verified against the 1.57.0 code). It replaces §6 UI-5 where they differ. What UI-4a's real outcome changes for UI-5: review actions are already recorded as `review.*` change sets and undone by `ChangeSetUndo` (incl. review rows and suppressions), and `policy.*` kinds are already accepted, so UI-5 adds no undo machinery, only kinds, row fields (`resolved_by`, `change_set_id`) and the UI on top of `POST /changes/:uuid/undo` (200/409/422/404/503); hard-delete and mixed-merge sets are not undoable, so the Resolved view must say why. Found while verifying: `bulk_apply` has no server-side safe-bulk whitelist (a merge or `delete_entity` can be bulk-applied today) and a busy membership lock on the old review action is a 500; UI-5a fixes the first, UI-5b the second (it removes the old actions; the new ones answer 503). UI-5 is planned as **two PRs** (Steve confirmed): UI-5a (data model, limits, policies, `contradiction` rows backend; `[Unreleased]`, no bump) and UI-5b (settings panel and the page; **1.58.0**). Steve's answers (Oct 26 evening): `contradiction` rows are **in** UI-5 (keep-one-side apply, undone as a `review.apply` set); policy change sets per batch of 200, old GET URLs → 301 and `ignore` → 30-day snooze confirmed. Later (Steve, Oct 26): root-first stays the first sort key for the old page and `list_maintenance_review`; the UI-5b digest and `/review` rank by priority alone. UI-5a is PR #128; `ui-5-plan.md` "UI-5a as shipped" lists what it built (as of `416e45b`).
**Oct 28 update.** **UI-5 is DONE** as UI-5a (#128, no bump) and UI-5b (#129, **1.58.0**), and **UI-2 is DONE** as UI-2a (#133, **1.58.3**) and UI-2b (#134, **1.59.0**). **UI-3 (Search, 1.60.0) is next**; it has no step list yet (`docs/plans/ui-3-plan.md` still to be written). A small follow-up found in the #134 review, MCP errors that never reach the log, is §6.F **F-1**.
Previous drafts: `ui-dashboard-plan.2026-10-21-pre.md` (the Oct 20 draft with the open questions); `ui-dashboard-plan.2026-10-21-b.md` (Oct 21 morning, before Steve's 1:32 PM answers on guest credentials, auto-apply policies and PR-4).
Base: `steveoro/graph_mem` `origin/main` @ `57d9524` (v1.52.1), re-checked on 2026-10-21 in a detached read-only worktree. `origin/main` hasn't moved.
Method (Oct 20): I read every route, controller, view, partial, Stimulus/JS module and stylesheet, then booted the app against a throwaway DB seeded with **synthetic data only** (`ui-shots/seed_synthetic.rb`). The screenshots are in `ui-shots/`. Oct 21: I re-read the review queue, the proposal generators, the merge path, auditing and settings caching to ground §2.4, §2.5 and §5. Nothing was pushed, posted or opened on GitHub.

Companion plans: `mcp-update-plan.md` and, since Oct 22, `agent-rules-plan.md` (same folder). All three share **one release train** (§0.3). UI-0 (the security baseline) is **done** (PR #106) and is released in **graph_mem 1.53.0**, ahead of the scan mounts (mcp plan PR-0) and the MCP hardening (mcp plan PR-2), which form 1.54.0.

---

## 0.1 Implementer brief (read first)

| | |
|---|---|
| **Repo** | `steveoro/graph_mem`. Rails 8.1, Ruby 3.4.1 (RVM gemset `ruby-3.4.1@graph_mem`), MariaDB **11.8+**, Haml, importmap, Stimulus/Turbo, Tailwind v4, Cytoscape. Read `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*` and `docs/architecture.md` first. |
| **Who does what** | **[Claude]** items need design judgement (auth, undo, merges, the queue redesign, JS rewrites). Claude implements them locally. **[Devin-simple]** items are mechanical, with exact files and steps, and carry no design decisions. If a Devin-simple step turns out to need a decision, Devin stops and asks; it does not improvise. |
| **Branches** | One branch per plan item, off current `main`: `claude/ui-<n>-<slug>` or `devin/ui-<n>-<slug>`. No force-push after review has started. Agents never merge, tag, push tags or run `rake release`. Steve merges and tags. The review bot (graphy-review[bot]) reviews every PR. Fix should-fix findings before Steve merges. |
| **Versions** | `lib/graph_mem/version.rb` + `CHANGELOG.md` (Keep a Changelog). Each **[Claude]** release PR bumps the version given in §0.3. **[Devin-simple]** PRs don't bump. They add a line under `## [Unreleased]`, and the next release PR folds it in. UI-0 (PR #106) wrote `## [Unreleased]` without a bump, so the 1.53.0 release commit folds it in. The two 1.54.0 PRs are stacked: PR-0 writes `## [Unreleased]`, and PR-2 renames it to `## [1.54.0]` and bumps. |
| **Running specs safely** | Always `source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem && …`. Export `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`; nothing may listen on 11434 and no spec may reach a real embedding/LLM service. **Truncate the test DB before and after** the suite (snippet below). Run the **full suite on its own** (no parallel suites on the same test DB). Never kill processes you didn't start: other agents share the box. Leave no scratch specs (`zz_*`) or temp files behind. |
| **Fixtures** | Synthetic only (`SynthWidget`, `Alpha Service`, `Dir.mktmpdir` trees). **Never use private client code, not even read-only, for tests, benchmarks or perf probes, and don't mention it in PRs or commits.** For real-app perf probes, use open-source apps (Steve's goggles repos, Mastodon, Discourse) or synthetic data. |
| **Schema** | `db/structure.sql` is the source of truth. After any migration, `git diff db/structure.sql` and make sure no `vector(768)` line, VECTOR KEY or embedding trigger disappears. `StructureDumpGuard` restores the dump if one does: fix the DB, don't bypass the guard. |
| **Done criteria (every PR)** | Required specs from the item below are green. The full suite is green run alone, plus `bundle exec rubocop` and `bin/brakeman`. The test DB is left with **0 rows**. CHANGELOG and docs are updated. The PR description lists manual checks with results and screenshots for UI changes (synthetic data). No `alert()`/`confirm()` added. No `innerHTML` with interpolated data. Files stay under ~500 lines and methods under ~60. |

Test-DB truncate (before **and** after the suite):
```bash
RAILS_ENV=test bin/rails runner '
  c = ActiveRecord::Base.connection
  c.execute("SET FOREIGN_KEY_CHECKS=0")
  (c.tables - %w[schema_migrations ar_internal_metadata]).each { |t| c.execute("TRUNCATE TABLE #{c.quote_table_name(t)}") }
  c.execute("SET FOREIGN_KEY_CHECKS=1")'
# verify: every table count is 0 (audit_logs and tool_invocations included)
```

## 0.2 Decisions (Oct 21, 2026), Steve's answers applied

1. **Accounts:** one **operator** login with full write access, plus an optional **guest** role that is read-only and **exists only when a guest password is configured** (ENV or Rails credentials; there is no hardcoded guest password, §2.1). The guest can only use Search (entities + observations) and Explore (read-only). No Home, Review & Fix, Projects & Data, System, settings or write API. It is enforced **server-side**, deny-by-default (§2.1, §5.4), not by hiding UI.
2. **`/api/v1` has no external consumers**, so auth is required immediately with **no compatibility flag** (UI-0).
3. **Explore edits for the operator:** retire observation and remove relation are direct. **Manual merges (drag'n'drop or context menu) are also direct**, with a confirm dialog showing a preview of what moves, a full snapshot and undo (§2.4, §5.3). **Deletes stay proposals** (reasoning in §2.4). Guests get no edit affordances at all.
4. **Review & Fix:** bulk apply stays limited to `relationship_proposal` and `stale_memory`. The queue is redesigned around groups, a "needs attention" digest, group actions with previews, audited and reversible auto-resolution policies, generation limits at the source, and an inbox-zero state (§2.5).
5. **Scans:** the default mount is the host user's home, read-only, at the **same path** inside the container (`${HOME}:${HOME}:ro`). A runtime subfolder filter defaults to `Projects` (comma list allowed). A hard denylist protects dotfolders and secrets. Details are in mcp plan PR-0. This plan only consumes it (UI-6).
6. **Hosts:** Linux Docker is the tested target. Rootless Podman is documented as best-effort and isn't CI-tested (mcp plan PR-0 §0.7).
7. **Versions:** no v1.52.2. fast-mcp 1.8.0 comes first, then (renumbered Oct 22-b) graph_mem 1.54.0, which bundles the scan mounts and the MCP hardening (§0.3). *(Oct 22-c: UI-0 left the bundle; it merged early in #106 and is released in 1.53.0, decision 12.)*

**Added Oct 21, 1:32 PM (Steve):**

8. **Guest credentials:** no default and no hardcoded guest password. Guest login is **disabled unless a guest password is set** in ENV (`GRAPH_MEM_GUEST_PASSWORD`) or Rails credentials (`guest.password`; Steve adds a `guest` entry with username + password to credentials in his next commit). When a password is set, guest is available; the runtime toggle `enable_guest_access` (**default on**) can still turn it off without a restart. The guest stays strictly read-only, enforced server-side. The "no `changeme` in production" rule concerns the **operator** credentials only (the guest has no fallback at all). Note: a guest can read **all** graph content (§2.1).
9. **Auto-apply policies start off** and are toggled on in Settings, per kind, with the relationship confidence threshold editable there; **operator only** (§2.5.3).
10. **PR-4 confirmed** (Oct 21), **replaced Oct 22-b:** 2026-07-28 now comes through graph_mem's migration to the official `mcp` gem (mcp plan §MG, D-20; MG-5 = 1.57.0), not fast-mcp 1.9.0.

**Added Oct 22-b (Steve):**

11. **Train renumbered:** the agent-rules rewrite (one Claude branch, `claude/ar-rules-rewrite`) is graph_mem **1.53.0**; UI-0 + PR-0 + PR-2 are **1.54.0** *(Oct 22-c: UI-0 left the bundle, merged in #106 and released in 1.53.0, decision 12; 1.54.0 = PR-0 + PR-2)*; PR-3 is 1.54.1; the migration track MG-1 … MG-6 is 1.55.0 … 1.58.0; **UI-1 … UI-7 are 1.59.0 … 1.66.0** (§0.3). UI-0's content and its "inside the mount release" rule are unchanged.

**Added Oct 22-c (Steve, after PR #106):**

12. **UI-0 done early.** PR #106 (`claude/ui-0-security-baseline`, merged Oct 22 as `f9febd6`) delivered UI-0, reviewed in five rounds; the last one ended "Looks good to me — ready for Steve". It has no version bump: its entries sit under `## [Unreleased]` › Security, so the **1.53.0** release commit (rules rewrite) releases them. Nothing is renumbered. The "UI-0 before the mount" rule is met, because PR-0 now builds on a `main` that already has UI-0. #106's leftover lows (spec rows for refused bearer writes, whose code fix landed in `bbda8b9`; the import-review inline script nonce; wording nits; `allow_guest` appending, the old DataExchange CSRF skip) and a test-hygiene item go into **mcp plan PR-2 §2.20–2.21**.

Answered and dropped from the open questions: all four Oct 20 UI questions (accounts, `/api/v1` consumers, the Explore safe set, the bulk whitelist).

## 0.3 Release train (shared with mcp-update-plan.md)

| # | Item | Repo / version | Who | Depends on |
|---|---|---|---|---|
| 0 | ✅ CircleCI fixes: done in #106 | n/a | | done |
| 1 | ✅ **AR** rules & skills rewrite (#107) | graph_mem **1.53.0** | [Claude] | done |
| 1a | **AR-E** eval harness, then the post-release eval. **Not started; not scheduled.** | graph_mem `[Unreleased]` (dev tooling) | [Claude] builds, Steve runs | 1.53.0 ✅ |
| 1b | **AR-F<n>** follow-up text fixes, only if the eval shows new worse than old | next patch | [Claude] | eval result |
| 1c | **AR-D4** docs follow-ups (`agent-rules-plan.md` §D). Open; not scheduled | `[Unreleased]` | [Devin-simple] | 1.53.0 ✅ |
| 2 | ✅ **PR-1** fast-mcp 1.8.0; graph_mem moved to it in 1.54.0 and dropped fast-mcp entirely in 1.55.1 | fast-mcp 1.8.0 | [Claude] | done |
| 3 | ✅ **UI-0** security baseline (#106) | released in **1.53.0** | [Claude] | done |
| 4 | ✅ **PR-0** home mount, ScanRootPolicy, subfolder filter, denylist (#111) | graph_mem **1.54.0** | [Claude] | done |
| 5 | ✅ **PR-2** MCP hardening (#112) | graph_mem **1.54.0** | [Claude] | done |
| 6 | ✅ **PR-3** interop specs/scripts and protocol compatibility doc (#113, #114); follow-up fixes (#115 → 1.54.2) | graph_mem **1.54.1**, 1.54.2 | [Claude] + [Devin-simple] | done |
| D | ✅ **M-D3** docs line-refs (#116 → 1.54.3). **M-D1** query cap and **M-D2** description-length spec: **dropped** as branches (never merged, written for fast-mcp, far behind `main`; branches deleted Oct 26). The work is carried as §6.D **D-7** and **D-8** | 1.54.3 | [Devin-simple] | done / see §6.D |
| 7–14 | ✅ **MG** track (MG-0 … MG-6, MG-D1), streamlined into three PRs: the engine swap (#118 → **1.55.0**), the Claude client-check script (#119, released in 1.55.1), fast-mcp removal (#120 → **1.55.1**), docs and the migration guide (#121 → **1.55.2**). Decisions D1–D14: `docs/guides/migrating-fast-mcp-to-mcp-gem.md` §2 | graph_mem **1.55.0–1.55.2** | [Claude] | done |
| C | ✅ **Chores D-1, D-2, D-3** (§6.D) as **one PR** (#122): review button labels, schedule the row cleanup job, no re-embedding inside the merge lock. Step list: `docs/plans/chores-d1-d3-plan.md` | graph_mem **1.55.3** | [Claude] | done |
| 15 | ✅ **UI-1** app shell, design system, roles incl. guest, CSP enforced, as UI-1a (#123) and UI-1b (#124). Step list: `docs/plans/ui-1-plan.md` | graph_mem **1.56.0** | [Claude] | done |
| 16 | ✅ **UI-4a** change sets, merge snapshots, undo (backend) (#127). Step list: `docs/plans/ui-4a-plan.md` | graph_mem **1.57.0** | [Claude] | done |
| 17 | ✅ **UI-5** Review & Fix, as UI-5a (#128: data model, limits, policies; no bump) + UI-5b (#129: page, release). Step list: `docs/plans/ui-5-plan.md` | graph_mem **1.58.0** | [Claude] | done |
| 18 | ✅ **UI-2** as UI-2a (#133: editable MCP allowlists + `bin/up`, **1.58.3**) + UI-2b (#134: Home, **1.59.0**). Step list: `docs/plans/ui-2-plan.md` | graph_mem **1.58.3** + **1.59.0** | [Claude] | done |
| 19 | **UI-3** Search. Step list: not written yet | **1.60.0** | [Claude] | UI-1 ✅; **next up** |
| 20 | **UI-4b** Explore | **1.61.0** | [Claude] | UI-3 (panel), UI-4a |
| 21 | **UI-6** Projects & Data | **1.62.0** | [Claude] | PR-0 ✅, UI-1 |
| 22 | **UI-7** System (settings schema, backups, access) | **1.63.0** | [Claude] | UI-1 |
| UD | The other Devin-simple chores (§6.D: D-4 … D-8) | `[Unreleased]` | [Devin-simple] | as listed |
| F | Small follow-ups (§6.F: F-1, MCP errors never reach the log) | a patch (1.59.1) or folded into the next PR; Steve decides | [Claude] | none |

Rows 0, 1, 1a–1c come from `agent-rules-plan.md`; rows 2, 4–6, 7–14 and D from `mcp-update-plan.md` (both done apart from 1a–1c). `D-nn` numbers refer to the mcp plan's decisions.

**Order from Oct 26 (Steve).** The chores first, as one small patch release (1.55.3), so UI-4a starts on a merge path without HTTP calls inside the lock (D-3) and the review queue shows real labels (D-1) and stops growing (D-2) before its redesign. Then UI-1, because every UI PR builds on its shell and roles. Then UI-4a and UI-5, which have the biggest payoff (Review & Fix) and need only UI-1 and UI-4a. UI-2, UI-3 and UI-4b follow; UI-6 and UI-7 only need UI-1 and close the series. The version numbers above follow that order (my numbering, one minor version per UI PR); if Steve reorders again, only the numbers change, not the content. Claude doesn't swap on its own.

**Why UI-0 had to come before the mount (met: #106 merged first, released in 1.53.0).** 1.54.0 mounts the operator's **whole home folder** into the container. Without UI-0, anyone on the LAN can `POST /api/v1/scan` and then read the scanned content back through the unauthenticated `GET /api/v1/memory_entities/...`, and scanned file text becomes entity names and observations that today reach `innerHTML` (F1). So API auth and the JS escaping are preconditions of the mount, not polish. PR-0 must not merge before UI-0 (done). CSP went in as **report-only** (#106) and is enforced in UI-1, once the shell rewrite has removed the inline handlers. The guest role needs the new nav, so it lands in UI-1. UI-0 already stores `session[:role]` so that UI-1 needs no session migration.

UI-5 (Review & Fix) has the biggest payoff for Steve. UI-4a deliberately comes before it, because auto-resolution and group actions reuse change sets and undo. **Decided Oct 26:** UI-4a and UI-5 jump ahead of UI-2/UI-3/UI-4b (rows 16–17).

---

## 0. Findings that ship before any redesign (security, verified Oct 20, re-checked Oct 21)

F1–F4 go into **UI-0**, F5 into §6.D (Devin-simple). F6–F8 are new on Oct 21, from reading the code (they weren't run).

| # | Finding | Evidence | Severity | Fixed in |
|---|---|---|---|---|
| F1 | **HTML injection / stored XSS in the graph UI.** Entity names, types, aliases and observation text go straight into `innerHTML`. These strings come from MCP agents, LLM scan output and (after 1.54.0) files under the operator's home. There is no CSP (`config/initializers/content_security_policy.rb` is fully commented out). | `graph/tooltip.js:14`, `graph/context_menu.js:29-50, 87-103`, the context-menu edit form `value="${nodeData.label}"`, `graph/drag_drop_manager.js:88`, `graph/observation_renderer.js` (`${obs.content}`), `controllers/compaction_review_controller.js:36-41`. **Verified:** a synthetic entity named `html-probe <b>bold</b>` renders a real `<b>` (`ui-shots/16-tooltip-html-injection.png`). | **High** | UI-0 ✅ (#106) |
| F2 | **`/api/v1/*` has no authentication.** `Api::V1::BaseController` does `skip_before_action :authenticate_operator!` and nothing replaces it. Anyone reaching port 3030 can read, edit, merge or delete, and `POST /api/v1/scan` queues a scan of any directory. | `app/controllers/api/v1/base_controller.rb:6`. **Verified:** `curl /api/v1/memory_entities` with no cookie → 200. | **High** | UI-0 ✅ (#106) |
| F3 | **Login hardening.** (a) The `operator`/`changeme` fallback applies in every environment, and `docker-compose.yml` passes neither `OPERATOR_USERNAME` nor `OPERATOR_PASSWORD`, so a compose install runs on the fallback unless credentials are set. (b) No `reset_session` on login (session fixation). (c) No rate limit. (d) No expiry. | `application_controller.rb:13-25`, `operator/sessions_controller.rb:9-21`, `docker-compose.yml` `app.environment` | Medium | UI-0 ✅ (#106) |
| F4 | **ActionCable and `/api-docs` are unauthenticated.** | `app/channels/application_cable/connection.rb` (comment: "we don't require authentication"), `config/routes.rb:2-3` | Low | UI-0 ✅ (#106) |
| F5 | **Review buttons show raw values** (`edit / apply / dismiss / ignore`). | `_compaction_review_item.html.haml` | Low (UX) | §6.D-1 |
| F6 | **`MaintenanceReportRowCleanupJob` is never scheduled.** `config/recurring.yml` has no entry for it, nothing enqueues it, and `compaction_review_row_retention_days` (setting, default 30) isn't in the Settings UI. Resolved rows are never pruned, so the queue tables only grow. | `app/jobs/maintenance_report_row_cleanup_job.rb`; `grep -rn MaintenanceReportRowCleanupJob app lib config` → only the class and its spec | Low (new bug) | §6.D-2 |
| F7 | **Dangling proposals.** Rows that reference an entity that was later merged or deleted stay `active`: no generator or delete path invalidates them (only `GraphifyRescan` retires its own `scan_review` rows). They fail on Apply ("Source node not found") and pad the queue. | `CompactionReviewService` / `CompactionReviewApplier`; `grep MaintenanceReportRow app` shows no invalidation in `NodeOperationsStrategy`, `GraphDeleteService` or `merge_into` | Medium (queue noise, new) | UI-5 (`dangling` auto-dismiss policy) |
| F8 | **Merge calls the embedding service per observation inside the DB transaction and the membership `GET_LOCK`.** `transfer_observations!` → `EmbeddingService.embed_observation` for each moved observation (open timeout 10 s, read timeout 30 s, up to 4 attempts per observation: `MAX_RETRIES = 3`, backoff 0.5/1/2 s). `compose_observation_text` uses only content/source/tags, so the vector doesn't change when the entity does: the call is pure cost, and with Ollama slow or unreachable a merge can hold the global membership lock for up to ~2 minutes per moved observation. Other writers wait. They don't race, but the lock is held far too long. | `app/strategies/node_operations_strategy.rb:289-296`, `app/services/embedding_service.rb:109-116, 258-263, 308-309` | Medium (new bug) | §6.D-3 (and UI-4a relies on the fix) |

---
## 1. Current-state inventory

### 1.1 Stack
- Rails 8.1, Haml (`haml-rails`), importmap, Turbo + Stimulus, `tailwindcss-rails` 4.3 (Tailwind v4, `app/assets/tailwind/application.css` is just `@import "tailwindcss"`), Kaminari (+ `kaminari-tailwind`), Cytoscape.js 3.31.4 (vendored ESM), Mission Control Jobs, rswag UI.
- **Three styling systems at once:** BEM classes in `dashboard.css` (1,177 lines, used by home/settings/telemetry/audit/embeddings/login), BEM in `graph.css` (925 lines, 64 of them for the orphaned `dm-*` modal), and raw Tailwind utilities (review queue, import review/report, graph page header). Pagination uses the Tailwind theme in two places and the default theme elsewhere.
- No ViewComponent, no shared partials beyond `layouts/_flash_messages`. 5 Stimulus controllers (`graph`, `compaction_review`, `operation_progress`, `import_threshold`, generated `application`) plus 9 plain ES modules under `app/javascript/graph/`.
- **Tests:** request specs exist (`spec/requests/pages_spec.rb`, `data_exchange_spec.rb`, `operator/*`, `project_scans_spec.rb`, …). **No system specs** (`test/system/.keep` is a leftover minitest skeleton; Capybara + selenium-webdriver are in the Gemfile but unused).

### 1.2 Auth today (at `57d9524`, before #106; F2–F4 are closed by UI-0)
- One shared operator login: `OPERATOR_USERNAME` / `OPERATOR_PASSWORD` ENV → credentials → `operator`/`changeme`. Session flag `session[:operator_signed_in]`. No Devise, no `has_secure_password` (bcrypt is commented out in the Gemfile).
- `ApplicationController#authenticate_operator!` guards every HTML controller and Mission Control (`config.mission_control.jobs.base_controller_class = "Operator::JobsDashboardController"`, basic auth disabled).
- `/api/v1/*`: unauthenticated (F2). `/mcp`: bearer token + IP allowlist (`docs/mcp_access_control.md`). No link between the UI session and the MCP token.
- `Current.actor` is `"<ip>:<controller>"` or `"api:<X-MCP-Client>"`, so the audit log can't tell the operator's UI edits from anonymous API calls.

### 1.3 Pages (HTML)

| Page | Route → action | Purpose today | Problems | Verdict |
|---|---|---|---|---|
| Login | `GET/POST /operator/login` → `operator/sessions#new/create`, `DELETE /operator/logout` | Single shared operator login | F3; rendered inside the app's flex `main` with a dashboard card, so it looks like a half-loaded dashboard (`00-login.png`) | **Keep**, restyle as a centred auth layout, harden (UI-0) |
| Dashboard | `GET /` → `pages#home` | Everything: stat chips, two hub links, six state cards (compactor, GC, embeddings, MCP clients, project scans, guided-scan "skill companion"), maintenance report `<details>` with raw JSON | 2,225 px tall at 1440 wide, 3,779 px on mobile (`01-dashboard.png`, `15-dashboard-mobile.png`). Mixes status, configuration and **actions**: two different free-text scan forms, Start/Pause compaction, Run GC, Repair relations, and **Approve/Dismiss scan-review rows straight from the home page** (`_project_scans_card.html.haml`, `return_to: "dashboard"`). Raw `JSON.pretty_generate` dumps ×4. Each card has its own "Refresh" button that reloads the page. | **Rebuild** as a status-only Home (UI-2) |
| Search | `GET /search` → `search#results` | Text or vector entity search | Only `text`/`vector`. The MCP `search` tool supports hybrid ranking, observation matching, `perspective`, `occurred_after/before`, `as_of`, subgraph projections; the UI exposes none. No snippets, scores or "why it matched", no project or type filter. Vector merge logic is re-implemented in the controller (`search_controller.rb:37-64`) instead of reusing the tool's service. Results only link to `/graph?scoped_entity_id=`. The same form is duplicated on `/graph`. | **Merge** into one Search page (UI-3) |
| Graph explorer | `GET /graph` → `pages#graph` | Cytoscape canvas, Root/Full/scoped views, hover tooltip, right-click context menu, drag-node-onto-node menu | Duplicate search form on top. No detail panel: observations open in a modal or `alert()`. 24 `alert()`/`confirm()` calls in the live graph code (46 counting the orphaned `data_manage.js`). **Destructive actions are one click away:** context menu "Delete" (hard delete), "Delete all duplicate observations", and drag'n'drop "Merge Nodes" (merges whole subgraphs behind a browser `confirm`). F1 sinks. Writes go through two different back ends (`/api/v1/...` and `/data_exchange/...` JSON, CSRF skipped on the latter). "Move to another parent" exists only in the orphaned `data_manage.js`, so **re-parenting isn't reachable from the UI today**. | **Rebuild** as Explore (UI-4) |
| Maintenance hub | `GET /maintenance` → `maintenance#index` | Export (checkbox list of roots, sync download), Import upload, a "Cleanup" card that only contains text pointing elsewhere | A page whose third card is a signpost. Async export with progress (`export_async`, `ExportJob`, `ExportProgressChannel`) exists but only the orphaned `data_manage.js` uses it. | **Drop**; export/import move to Projects & Data (UI-6) |
| Compaction / stale / scan review | `GET /data_exchange/compaction_review[?report_type=scan_review]`, `POST …/compaction_review_action`, `POST …/compaction_review_import_suggest_merges`, `GET …/entity_search` | One queue page for `report_type=compaction_review` (kinds `entity_merge`, `relationship_proposal`, `orphan_parent`, `relation_integrity`, `stale_memory`, `entity_error`, …) and, via a query param, `scan_review` (`delete_entity`, `delete_relation`, `reparent_entity`, `move_observation`, `delete_observation`) | Two queues hidden behind a URL param, no link between them except dashboard buttons. "Seed from Suggest Merges" form at the top of the inbox. Status tabs + kind chips + search + bulk bar + per-row forms all stacked (`07-compaction-review.png`). **Bulk "Apply selected" works for every kind**, including `delete_entity` and `entity_merge`. No preview of what Apply will do. F5 labels. N+1: `MemoryEntity.find_by` per row in the partial. `CompactionReviewService.items` loads the whole filtered queue then `paginate_array` (`compaction_review_service.rb:30`). The `approve` action and `_compaction_review_confirm.html.haml` are dead (the view never reads `@confirm_action`/`@current_item`). | **Move** into Review & Fix (UI-5) |
| Import review | `GET /data_exchange/import_review`, `POST import_execute`, `DELETE import_cancel` | Per-root match decisions for an uploaded export / Graphify translation | Raw Tailwind styling unlike the rest; errors redirect to `/` (dashboard) instead of back to the upload | **Move** under Projects & Data › Imports, restyle (UI-6) |
| Import report | `GET /data_exchange/import_report` | Result of the last import | Only the *last* import (session-based); no history | **Move** under Imports as a run detail (UI-6) |
| Settings | `GET/PATCH /operator/settings?tab=…`, backup run/restore/delete | 7 tabs: feature flags, database backup, embeddings, summaries, imports, project scans, telemetry | Two `AppSettings` fields are **not reachable** in the UI: `enable_contradiction_detection` and `compaction_review_row_retention_days`. Backup **restore and delete** (destructive) sit in a settings tab next to text fields, guarded only by `turbo_confirm`. Generic tab renders every field by hand-rolled type switch; four tabs have bespoke partials. `project_scan_roots` lets the UI widen the scan boundary to any path, including `/` (see mcp plan PR-0). | **Keep** under System, regroup, move backups out (UI-7) |
| Embeddings | `GET /operator/embeddings` + test/backfill/regenerate/add_indexes/drop_indexes | Coverage, config, index status, maintenance actions | Fine content; "Regenerate" and "Drop indexes" are heavy and only `turbo_confirm`-guarded; duplicated "test connection" button also on the Settings › Embeddings tab | **Keep** under System (UI-7) |
| Tool telemetry | `GET /operator/telemetry`, `POST prune` | MCP tool usage, errors, clients, argument signatures, invocations | Good page; filters and tables use their own CSS classes | **Keep** under System (UI-7) |
| Audit logs | `GET /operator/audit_logs`, `POST prune` | Audit trail with filters | 3,459 px tall default page; actor strings are IPs + controller names | **Keep**, becomes System › Activity and feeds Home's "Recent activity" (UI-2/UI-7) |
| Jobs | `/operator/jobs` (Mission Control engine) | Queue/job inspection | Outside the app layout (own chrome), reached from top nav and an Embeddings button | **Keep**, link from System › Jobs |
| API docs | `/api-docs` (rswag) | Swagger UI | Unauthenticated (F4) | **Keep**, put behind the operator session, link from System |
| `up` | `GET /up` | Rails health | Bare 200/500 | **Keep**; add a richer `/system/health(.json)` (UI-7) |

### 1.4 JSON endpoints used by the UI, and dead code

| Endpoint | Used by | Verdict |
|---|---|---|
| `GET /api/v1/graph_data` | `graph/api_client.js` | Keep for the canvas, behind session-or-token auth |
| `/api/v1/memory_entities/:id` GET/PATCH/DELETE, `merge_into`, observations index, `delete_duplicates`, `POST /api/v1/memory_relations` | `context_menu.js`, `drag_drop_manager.js` | UI stops calling write endpoints; Explore gets its own CSRF-protected HTML/Turbo endpoints with audit and undo (UI-4) |
| `/data_exchange/update_relation`, `delete_relation` (CSRF skipped) | `context_menu.js` | Replace in UI-4 |
| `/data_exchange/root_nodes`, `orphan_nodes`, `duplicate_relations`, `delete_duplicate_relations`, `move_node`, `merge_node`, `delete_node`, `export_async` | **only `graph/data_manage.js`, which nothing imports** (`DataManageManager` is never referenced) | **Dead from the UI.** Remove the JS (568 lines) and its 64 `dm-*` CSS rules in UI-4; keep or remove the endpoints after UI-6 re-homes async export and UI-5 owns orphan/duplicate fixes |
| `GET /data_exchange/entity_search` | review autocomplete | Keep, escape output (F1) |
| `POST /data_exchange/compaction_review_action` `review_action=approve` + `_compaction_review_confirm.html.haml` | nothing renders the confirm partial | **Dead**, remove in UI-5 |
| `app/views/pwa/*` | routes commented out | Dead; remove or wire up (not needed) |
| `test/` (minitest skeleton) | nothing | Remove when system specs land under `spec/system` (UI-1) |

### 1.5 Inconsistent patterns (what the design system must unify)
- **Flash:** `:notice` / `:alert` / `:error` all handled by one partial, but the graph uses `alert()` and the review page uses turbo-stream flash; there are no toasts and no undo affordance.
- **Tables:** five bespoke table classes (`search-results-table`, `project-scans-table`, `agent-contexts-table`, `telemetry-table`, `audit-logs-table`) plus Tailwind tables on import review.
- **Filters:** three filter-form styles (telemetry, audit, review), none of which keep state in a reusable way.
- **Page headers:** `dashboard-header` on operator pages, centred `h1.text-3xl` on graph/search, `h1.text-2xl` on review; "Back to dashboard" links on almost every page instead of a nav highlight/breadcrumb.
- **Buttons:** `dashboard-btn--*`, `graph-btn--*`, and raw Tailwind `bg-green-600` buttons.
- **Live progress:** `operation_progress_controller.js` over ActionCable is good and reusable; keep it as the one progress mechanism.

---
## 2. Target information architecture

Five top-level sections plus sign-in. Navigation: a slim left sidebar on ≥1024 px (it collapses to a top bar on small screens), with a global search box and the review-backlog badge. **What a guest sees** is in the right-hand column.

```
                         operator                 guest (read-only, only if a guest password is configured)
Sign in                  ✓                        ✓ (same form)
Home          /          ✓                        → redirects to /search
Search        /search    ✓                        ✓
Explore       /explore   ✓ (edits)                ✓ (no edit affordances; writes 403)
Review & Fix  /review    ✓  [badge]               403
Projects & Data /projects ✓                       403
System        /system    ✓                        403 (incl. settings, jobs, api-docs)
```

Old URLs (`/graph`, `/maintenance`, `/data_exchange/compaction_review`, `/operator/*`) redirect (301) to the new ones for one release, then go (§6.D-6).

### 2.1 Sign-in, roles and the guest

**Credentials**
- Operator: `OPERATOR_USERNAME` / `OPERATOR_PASSWORD` (ENV) → credentials `operator.username/password`. **No `changeme` fallback in production:** the login page shows "Operator credentials are not configured (set OPERATOR_USERNAME / OPERATOR_PASSWORD)" and no form, and boot logs an error. The fallback stays for development/test only. `docker-compose.yml` gains `OPERATOR_USERNAME: ${OPERATOR_USERNAME:-}` / `OPERATOR_PASSWORD: ${OPERATOR_PASSWORD:-}` so the values can reach the container at all (F3a).
- Guest: username `GRAPH_MEM_GUEST_USERNAME` (ENV) → credentials `guest.username` → `guest`; password `GRAPH_MEM_GUEST_PASSWORD` (ENV) → credentials `guest.password`. **There is no default or hardcoded guest password.** No password configured (blank counts as none) → guest login is **disabled**: the username `guest` is treated like any unknown username (same generic "Invalid credentials", same constant-time path), and nothing guest-related is offered. Steve adds a `guest:` entry (`username`, `password`) to Rails credentials in his next commit, so his install gets the guest from that.
- **Guest availability = a password is configured AND the runtime toggle is on.** The toggle is `enable_guest_access` (new `AppSettings` boolean, **default on**, read uncached like `read_boolean_setting` so it takes effect without a restart). Default on because configuring a guest password is already the deliberate opt-in; the toggle exists to switch the guest off temporarily without editing credentials or restarting. The password stays in ENV/credentials, **never in the settings table**: settings are in every DB backup and export. Settings › Access shows "Guest access: not configured (no guest password) / available / turned off" plus the toggle (the toggle is disabled with a hint while not configured).
- A guest password equal to the operator password, or a guest username equal to the operator username, is refused: boot logs an error and guest stays disabled.
- The production rule "no `changeme` fallback" (above) is about the **operator** only. The guest has no fallback to refuse.
- **Note:** a signed-in guest can read **all** graph content (every entity, observation and relation in every project); there is no per-project scoping for guests.
- Why this shape and not user accounts: one owner, no user-management UI to build, and the existing secret handling is reused. Turning the toggle off locks guests out on their next request (below), without a restart or rotating the password.

**Login** (`Operator::SessionsController#create`)
- One form for both roles: the username picks the role, and both comparisons are constant-time (`secure_compare` on both pairs, so timing doesn't reveal which username exists).
- `reset_session`, then `session[:role] = "operator" | "guest"`, `session[:user] = <username>`, `session[:signed_in_at]`, `session[:last_seen_at]`. The legacy `session[:operator_signed_in]` is still read (as operator) for one release so existing cookies don't break mid-upgrade, then dropped (§6.D-6).
- `rate_limit to: 10, within: 3.minutes, only: :create` (Rails 8 built-in, cache store). The 11th attempt → 429 with the same login page.
- Expiry, checked in the auth before_action: operator idle 12 h / absolute 7 days, guest idle 2 h / absolute 24 h. Expired → `reset_session` and redirect to login with "Session expired".
- Guest sessions are re-validated **on every request**: a guest password is still configured, `enable_guest_access` is still on, and `session[:guest_cred_fp]` (a truncated SHA-256 of the configured guest username + password, stored at login) still matches, so rotating the guest password logs existing guests out after the restart that picks it up. Otherwise `reset_session` → login with "Guest access is disabled".
- `Current.actor` = `operator:<name>@<ip>` (guests never write, but reads are logged as `guest@<ip>` in request logs only).

**Enforcement (server-side, deny-by-default)** lives in a new `app/controllers/concerns/role_authorization.rb`, included in `ApplicationController`:
```ruby
# Every action requires :operator unless the controller opts in explicitly.
class_attribute :guest_actions, default: [].freeze
def self.allow_guest(*actions) = self.guest_actions = (guest_actions + actions.map(&:to_s)).freeze

before_action :authenticate!              # signed in at all (operator or guest), expiry, guest re-validation
before_action :authorize_role!            # operator → pass; guest → action_name in guest_actions or 403
```
- Opt-ins (the complete list, kept in one spec): `SearchController#results/index`, `ExploreController#show`, `Explore::EntitiesController#panel` (the read-only panel), `Explore::GraphController#data` (or `Api::V1::GraphDataController#index`, whichever the canvas uses after UI-4b), `PagesController#home` (only to redirect guests to `/search`), `Operator::SessionsController#destroy`.
- **`/api/v1`** (`ApiAuthentication`, UI-0): an operator session → all actions. A guest session → only `Api::V1::GUEST_READ_ACTIONS` = `graph_data#index`, `memory_entities#index/show/search`, `memory_observations#index/show`, `memory_relations#index/show`, `search#subgraph`, `graph_traversal#traverse/shortest_path`. Everything else → **403 JSON** `{error: "forbidden", role: "guest"}`, including read-ish POSTs like `search#subgraph_by_ids`, `summarize` (LLM cost) and `context`. Bearer token (`GRAPH_MEM_MCP_TOKEN`) → full, as the owner's machine credential. Nothing → 401.
- Explore write endpoints, `/changes/:id/undo`, Mission Control (`Operator::JobsDashboardController`), `/api-docs` and ActionCable all require the operator. Guests get no progress channels: nothing they can see uses them.
- Views use one helper, `can_write?` (= operator), to drop edit affordances. That's cosmetic only. The guarantee is the before_action plus the **route-matrix spec** (§6 UI-1): it iterates `Rails.application.routes` and asserts that a guest gets 403 (or a redirect for `home`) on every route not in the opt-in list, so a new controller is protected by default.
- MCP is unaffected: `/mcp*` keeps its own bearer + IP policy (`McpAccessPolicy`). The read-only MCP profile `/mcp/readonly` is the agent-side equivalent of the guest.

### 2.2 Home (operator only, status only; its only form is quick search)
1. **Health strip** (green/amber/red pills, each a link): Database; Embedding service reachable + vector search ready; Summaries (LLM on/off); Jobs (failed count, queue latency); Last backup age; **Scan mounts** (from mcp plan PR-0: mounted read-only / writable warning / nothing mounted); MCP access mode; Guest access (not configured / available / turned off).
2. **Counts:** entities, observations, relations, orphans, embedding coverage.
3. **Review digest:** the top 5 "needs attention" groups from §2.5 with one-click "Open", plus the inbox state ("Inbox zero ✓ · last auto-resolution 3 h ago: 12 dismissed as dangling"). Never approve/dismiss buttons on Home.
4. **Running and recent jobs:** compaction run, scans, backfills, exports, with live progress (existing `operation-progress` controller), and the last finished/failed with links.
5. **Recent activity:** the last 15 **change sets** ("operator merged A into B · Undo", "policy auto-dismissed 12 dangling proposals", "agent cursor-1 wrote 4 observations to Y"), with a link to System › Activity.
6. **Active MCP clients** (compact).
7. **Quick search** box (also global in the nav; `/` focuses it).

Everything else on today's dashboard moves: compactor/GC controls → Review & Fix › Generate; scan forms → Projects; raw JSON → System › Diagnostics.

### 2.3 Search (one page, all modes; operator and guest)
- One query box, mode switch **Auto (hybrid)** / Text / Semantic (vector; disabled with a reason when vectors aren't ready) / Exact name.
- Filters (chips, all in the URL so searches are linkable): project, entity type (multi), perspective (`world` / `experience` / both), time (`occurred_after/before` or `as_of`), include obsolete, "match in" (name / aliases / type / observations).
- Results: entity name, type, project breadcrumb, score + matched fields ("name", "observation #123"), the top 2 matching observation snippets with highlights (escaped first, then `<mark>` wrapped server-side), relation count. A click opens the right-side entity panel (the same Turbo Frame as Explore). "Open in Explore" centres the canvas on the entity.
- **Backend:** extract the body of `SearchTool#call` into a `GraphSearch` service so the UI and agents get identical results. `SearchController` becomes a thin adapter, and its private vector-merge code (`search_controller.rb:37-64`) is deleted.
- "Show as graph" sends the result set to Explore (`/explore?ids=…`) via `SubgraphSearchService`.
- Guest: identical, minus the "Open in Review" links on the panel.

### 2.4 Explore (graph canvas + entity panel)
Layout: a toolbar (scope picker: project / root view / full / "from search"; layout; depth; filter by type and relation type; fit), the canvas (left ~65%), and the entity panel (right ~35%, Turbo Frame `entity_panel`).

Entity panel: name, type, aliases, project path (breadcrumb of `part_of`), observations (paged, perspective badge, trust/obsolete state), relations in/out grouped by type, recent change sets for this entity, and "Open in Review" if rows reference it (operator only).

**Operator edits.** Each runs in a change set (§5.3), every one is audited, and every one shows an undo toast for 10 minutes:

| Edit | How | Guard / confirm level |
|---|---|---|
| Rename / edit type / edit aliases | Inline edit in the panel | Server validation (scoped name uniqueness); project roots: rename only. None (toast + undo) |
| Add observation | Panel form (text + perspective) | Same duplicate detector as imports; "similar existing observation" warning. None |
| Edit observation text / perspective | Inline | Keeps history via `superseded_by` (no destructive overwrite). None |
| **Retire observation** (mark obsolete) | Panel action | `mark_obsolete!`; reversible (undo / restore). None (toast + undo) |
| Add relation | **Drag node onto node** → popover: "Add relation…" → type picker (canonical types from `RelationSemantics`, suggestions first) → Create | Rejects duplicates; shows the canonical direction ("Effect caused_by Cause"). None |
| Move entity to another parent | Drag onto a Project/parent node → "Move under …" | Confirm card with subtree size and project change; `NodeOperationsStrategy#move_node` with the membership lock; project roots can't move |
| **Remove relation** | Edge context menu | Undo re-creates the triple with its **original id** from the snapshot. `turbo_confirm` |
| **Merge entities** (new: direct) | Drag node A onto node B → "Merge A into B…", **or** context menu "Merge into…" → entity picker (same type only) | **Merge dialog** (below). Change set with full snapshot; undo for 10 min from the toast and later from Activity (§5.3) |

**Merge dialog** (`Explore::MergesController#new` renders a Turbo Frame modal, `#create` executes):
- Header: "Merge **A** (source, will be removed) into **B** (survivor)", a **Swap direction** button, and the survivor-suggestion hint from `EntityMergeEvidence.pick_survivor` ("B looks canonical: older, more observations").
- Preview (`EntityMergePreview.new(source_id, target_id).call`, read-only, the same lookups as `merge_into_once`): observations that move (count + the first 5), relations re-pointed (out/in, by type), relations dropped as duplicates or A↔B self-edges (listed), aliases B gains, `part_of` children re-parented and **any project change** (amber "moves 3 entities from project X to Y"), and the review rows that will be closed as dangling (F7).
- Blockers (button disabled, reason shown): different `entity_type`, either side a project root, source == target, or the operator lacks write access.
- The dialog carries a **preview digest** (SHA-256 of the preview's id lists). `#create` recomputes it inside the lock and answers 409 "The graph changed since the preview, review again" on a mismatch, so a merge never does more than the operator saw.
- Execution: `EntityMergeService.call(source_id:, target_id:, actor:)` → change set + snapshot + `merge_into` (with the F8 fix) in one transaction. Then a toast "Merged A into B · Undo" and a canvas patch (`graph:changed` removes A and re-points its edges).

**Deletes stay proposals.** I'd keep it that way: `destroy!` cascades observations and relations (`dependent: :destroy`), orphans `part_of` children (`delete_children_info` documents the no-cascade choice), and MCP agents hold entity ids that would silently dangle. Undoing a delete would mean re-inserting a whole subtree of rows, which is heavier and riskier than undoing a merge. A merge keeps every fact (observations move, the name becomes an alias). A delete throws facts away, so it gets a second look in Review & Fix: context menu "Propose deletion" seeds a `delete_entity` row with `source: "operator"` and a link to it. "Delete all duplicate observations" is dropped from Explore. It becomes a Review & Fix group action on duplicate-observation rows.

**Guest:** the same canvas, toolbar and panel with **no** context-menu write items, no drag-to-act (dragging only repositions nodes locally), no inline editing, no Open in Review. Every write endpoint answers 403 regardless.

### 2.5 Review & Fix: from "hundreds of rows" to "a few decisions"

#### 2.5.0 What exists today (verified at `57d9524`)
- **Storage:** `maintenance_report_rows` (`report_type` ∈ `compaction_review`, `scan_review`; `kind`; `status` ∈ `active/ignored/approved/dismissed`; `signature`; JSON `payload`/`edited_payload`; `resolution_reason`; `applied_at`/`dismissed_at`; the generated `stale_entity_id`). `maintenance_report_suppressions` (`report_type`, `signature`, `kind`, `reason`, unique on type+signature) remembers **dismissals only**. `maintenance_reports` headers are pruned to 30 per type.
- **Generators → kinds:**
  - `DreamStateCompactor`: `orphan_parent` (top-3 project matches with score), `entity_merge` (`EntityMergeEvidence` integer score + cosine distance; near-identical pairs are **auto-merged** when distance < 0.10 and score ≥ 10), `relationship_proposal` (`RelationshipDiscoveryStrategy`: `confidence_band` high/medium, integer `score` 8–~20, max 3 per entity), `entity_error`.
  - `DreamStateCompactionJob` integrity sweep: `embedding_backfill_failed`, `lifecycle_corruption`.
  - `StaleMemoryScanJob`: `stale_memory` with `signal` ∈ `valid_until_elapsed`, `addressed_by_newer_edge`, `unrooted_after_rescan`. (Its contradiction pass writes a separate `contradictions` `MaintenanceReport`, not review rows. UI-5 seeds those as `contradiction` rows so they show up in the inbox.)
  - `GraphIntegrityService` → `RelationIntegrityRepairer`: `relation_integrity`.
  - `ProjectScanner` / `GraphifyRescan`: `scan_review` rows `delete_entity`, `delete_relation`, `delete_observation`, `reparent_entity`, `move_observation`.
  - `GraphifyImporter::Matching`: `relationship_proposal` in `scan_review`, band `low`, `score = confidence×10`.
  - Operator/MCP `suggest_merges`: `entity_merge`.
- **Dedupe today:** `signature_for` per kind; seeding skips suppressed signatures and signatures already **pending** (active or ignored); `stale_memory` absorbs into the existing active row. Generators also pre-check `suppressed?`, which matches *any* row with the signature.
- **Gaps:** no grouping and no priority beyond `root_first?` + `payload["score"].to_i` (scores aren't comparable across kinds); the whole filtered queue is loaded into Ruby and paginated with `paginate_array`; rows never expire; dangling rows stay active (F7); resolved rows are never pruned (F6); ignored rows aren't suppressed, so once pruned they would come back; there's no cap on how many rows a run may create; symmetric `relates_to` A→B and B→A have different signatures on paths that don't use `ordered_pair`.

#### 2.5.1 Model changes (one migration, UI-5)
Add to `maintenance_report_rows` (filled at seed time by a new `ReviewRowClassifier`, backfilled by the migration in batches):
- `group_key` varchar(191): `"<kind>|<anchor_entity_id>"` for single-anchor kinds (`orphan_parent`, `stale_memory`, `entity_error`, `embedding_backfill_failed`, `delete_entity`, `reparent_entity`), `"<kind>|<min_id>-<max_id>"` for pair kinds (`entity_merge`, `relationship_proposal` and `relation_integrity` across both directions), `"<kind>|obs:<entity_id>"` for observation kinds.
- `anchor_entity_id` bigint, `project_id` bigint (the anchor's `project_id`, NULL = global).
- `priority` int 0–100 and `confidence` decimal(4,3) 0–1, normalized per kind by `ReviewRowClassifier` (table below).
- `expires_at` datetime (NULL = never).
- `resolved_by` varchar(64) (`operator`, `policy:<name>`, `generator`).
- `change_set_id` bigint (the change set that applied/dismissed it; links to undo).
- Indexes: `(report_type, status, priority)`, `(report_type, status, group_key)`, `(project_id, status)`, `(expires_at)`.
- New `status` value **`expired`** (`MaintenanceReportRow::STATUSES` gains it; `status` is a varchar, so there's no enum migration).

`maintenance_report_suppressions` gains `expires_at` (NULL = permanent, as dismissals are today) and `source` (`dismissed`, `ignored`, `expired`, `policy`).

Confidence and priority normalization (`ReviewRowClassifier`, one spec table pins it):

| Kind | confidence | impact (0–1) | Notes |
|---|---|---|---|
| `relationship_proposal` | band high 0.9 / medium 0.6 / low 0.3, nudged by `score` within the band | 0.3 | graphify `low` band → 0.3 at most |
| `entity_merge` | `min(score / 24, 1) × (1 − cosine_distance)` | 0.8 (fewer duplicates = better recall) | destructive class |
| `orphan_parent` | top suggestion `score` normalized by the matcher's max | 0.5 | |
| `stale_memory` | `valid_until_elapsed` 0.95, `addressed_by_newer_edge` 0.75, `unrooted_after_rescan` 0.6 | 0.6 × min(obs count / 5, 1) | |
| `contradiction` (new, from the `contradictions` report) | detector similarity score | 0.6 | single-apply (retire one side) |
| `relation_integrity` | 0.9 | 0.4 | |
| `entity_error`, `embedding_backfill_failed`, `lifecycle_corruption` | 1.0 | 0.7 | error class: always surfaces |
| scan `delete_*`, `reparent_entity`, `move_observation` | 0.7 (scan says the source no longer matches) | 0.6 | destructive class |

`priority = round(100 × (0.6 × impact + 0.4 × confidence) × age_boost)`, where `age_boost = 1 + min(age_days, 14) / 28` (old items rise slowly), plus an impact bump when the anchor's degree > 20. Priority is recomputed by the nightly policy run, not per request.

#### 2.5.2 The page
- **Left rail:** Needs attention (default) · By kind · By project · Errors · Scan review · Imports · Resolved (approved, dismissed, expired: each row shows `resolved_by` and an Undo/Restore when the change set allows) · Policies.
- **Needs attention digest** (default view): at most **10 groups**, ranked by the group's max `priority`. Each card is one decision: "**Alpha Service**: 7 relationship proposals (5 high confidence) · Apply high-confidence (5) · Review · Dismiss all". "**SynthWidget ↔ Synth Widget**: probable duplicate (0.92) · Merge preview". "**Errors**: 3 embedding backfills failed since 02:00 · Open System › Embeddings". Under the cards: "**+ 214 more in 38 groups** (all below priority 40)" with a link to By kind. That's the honest backlog, but it isn't the default screen.
- **Grouped list** (By kind / By project): one line per **group**, not per row: kind badge, anchor entity, project, row count, max confidence, oldest age. Expanding a group shows its rows (lazy Turbo Frame, SQL-paginated at 20). Duplicates inside a group are collapsed: same pair in both directions, or the same target with different relation types ("relates_to, depends_on").
- **Detail pane** (right, Turbo Frame): payload rendered per kind, editable targets (entity pickers), and the **apply preview** (`CompactionReviewApplier.preview(row)`: the same lookups without writing, e.g. "merge A → B: 7 observations move, 3 relations re-point, 1 duplicate dropped").
- **Group actions** (operator only), each opening a preview card that lists exactly which rows and effects are included before anything is written:
  - **Apply group** only for safe-bulk kinds (`relationship_proposal`, `stale_memory`), optionally limited to "confidence ≥ x". Capped at 100 rows per action; the card says how many and which are excluded and why.
  - **Dismiss group** (any kind; writes suppressions) and **Snooze group 30 days** (status `ignored`, suppression with `expires_at`).
  - Destructive kinds (`entity_merge`, `delete_*`, `reparent_entity`, `move_observation`) have **no group apply**: they're applied one by one from the detail pane, with the confirm card repeating the preview.
- **Row actions:** Apply · Dismiss (optional reason) · Snooze · Edit/Save · Restore. Keyboard: `j/k` next/previous group or row, `Enter` expand/open, `a` apply (opens the confirm for destructive kinds), `d` dismiss, `s` snooze, `e` edit, `r` restore, `x` select, `/` search, `?` help. Shortcuts never fire inside inputs. Focus moves to the next item after an action.
- **Inbox zero:** with no active row at priority ≥ the attention threshold (default 40), the page shows a calm empty state: "Inbox zero ✓ · 38 low-priority items parked (view) · Policies resolved 57 items this week (view) · Next compaction run 03:00". The nav badge counts **attention groups**, not rows (shown "0" → hidden).
- **Generate panel** (collapsed, top right): Import suggest-merges, Start/Pause compaction, Run stale scan now, Run GC diagnostics, Repair relation duplicates (moved from the dashboard).

#### 2.5.3 Auto-resolution policies (Settings › Review policies, operator only; all audited and reversible)
A `ReviewPolicyRunner` job runs after each compaction run, stale scan and project scan, plus nightly. Each action runs inside a change set with actor `policy:<name>` and sets `resolved_by` / `change_set_id` on the row, so Undo (§5.3) and Restore work exactly as for operator actions. Settings are `AppSettings` fields read uncached (they take effect on the next run).

**Auto-apply policies start off and can be toggled on in Settings.** Exactly:
- `auto_apply_relationships` and `auto_apply_expired_validity` default to **off**. Each has its **own toggle** (per kind) in Settings › Review policies (UI-5 adds this panel to today's `/operator/settings`; UI-7 moves it under System › Settings).
- The confidence threshold for `auto_apply_relationships` (`auto_apply_relationship_min_confidence`, default **0.90**, accepted 0.80–1.00, validated server-side; out of range → 422) is edited in the same panel.
- **Operator only:** the panel and its `PATCH` sit behind the operator-only settings controller (guest → 403, pinned by the role-matrix spec). Neither `/api/v1` nor MCP gets a write path to these fields. Each change writes an `AuditLog` row (actor `operator:<name>@<ip>`, old → new value).
- The three hygiene policies below (`dangling`, `no_longer_flagged`, `expire_low_confidence`) only dismiss or expire review rows and never change the graph; they start on and have their own toggles in the same panel (`expire_low_confidence` days editable). `snooze_expiry` has no toggle.

| Policy | Default | What it does | Reversal |
|---|---|---|---|
| `dangling` | **on** | Dismiss rows whose referenced entities/observations no longer exist (F7), or whose effect already holds (relation already exists, observation already obsolete). `resolution_reason` "dangling: entity #12 gone". No suppression (the signature can't recur for a deleted id). | Restore |
| `no_longer_flagged` | **on** | `stale_memory` rows where `StaleMemoryScanner.still_flagged_ids` is empty → dismiss without suppression (the signal resolved itself). | Restore |
| `expire_low_confidence` | **on**, 30 days | Rows with `confidence < 0.4` (graphify `low` band, weak orphan matches) untouched for N days → `expired` + suppression with `expires_at = now + 90 days` (so they don't come straight back, but can resurface on new evidence later). | Restore (deletes the suppression) |
| `auto_apply_relationships` | **off** | `relationship_proposal` with band `high` and `confidence ≥ threshold` (default 0.9, adjustable 0.8–1.0) and not `part_of` → apply. Max 50 per run. | Undo the change set (deletes the created relations) |
| `auto_apply_expired_validity` | **off** | `stale_memory` with signal `valid_until_elapsed` (the writer set the expiry) → apply (mark obsolete). Max 100 per run. | Undo (restores `status: active`, clears `obsoleted_at`) |
| `snooze_expiry` | always | `ignored` rows whose suppression `expires_at` passed → back to `active`. | n/a |

Hard rule: policies never apply destructive kinds (merge, delete_*, reparent, move_observation), whatever the settings, and the policy runner has a spec that tries. Each run writes a summary `MaintenanceReport` (`report_type: "review_policy_run"`, added to `REPORT_TYPES`), which Home and Activity show ("Policies: 12 dismissed as dangling, 5 relations auto-applied · Undo run").

#### 2.5.4 Limits at the source (fewer, better proposals)
1. **Backlog ceiling per kind:** a generator checks `active` count for its kind before seeding. At or above `review_backlog_ceiling` (setting, default **300**), it seeds only items whose normalized priority beats the current lowest active one, and the run stats record `skipped_backlog_full`. Home shows "Relationship discovery paused: backlog full".
2. **Per-run caps:** `relationship_proposal` ≤ 200 per compaction run (on top of today's 3 per entity), `entity_merge` ≤ 100, `orphan_parent` ≤ 100. Constants live in `ReviewRowClassifier::RUN_CAPS`.
3. **Symmetric dedupe:** `signature_for("relationship_proposal")` orders the pair when `RelationSemantics.symmetric?(type)` is true (today `SYMMETRIC_TYPES = %w[relates_to]`), so A→B and B→A collapse. A migration rewrites existing active signatures and merges duplicates (the older row wins, the newer goes to `dismissed` with reason "duplicate of #id").
4. **Don't regenerate what was decided:** dismissal suppression stays as is; **snooze** and **expire** also write suppressions (with `expires_at`); `suppressed?` ignores suppressions whose `expires_at` passed. Approved rows don't need suppression (the relation exists / the merge happened, and the generators already check that).
5. **Tunable floor:** `RelationshipDiscoveryStrategy::MIN_QUEUE_SCORE` (default 0, so no change at first). The policy-run stats record apply/dismiss rates per kind and score. If text-mention `depends_on` proposals (score 8) are mostly dismissed after a few weeks, raise the floor to 9. That decision is driven by data, not guessed now.
6. **Prune:** schedule `MaintenanceReportRowCleanupJob` (F6, §6.D-2) and include `expired` rows in it.

### 2.6 Projects & Data (operator only)
- **Projects list:** one row per Project root entity: last scan (mode, status, when, counts), last Graphify import, pending scan-review groups, "Open in Explore".
- **New scan:** a path field with live check (`ScanRootPolicy.resolve`). With identity mapping, host paths paste straight in: "`/home/steve/Projects/foo` ✓ inside scan filter `Projects`, read-only". Under it, the allowed folders (home + subfolder filter) as clickable chips, then project name/aliases, mode, globs, dry run. One form for both today's "Project scan" and "guided scan" with a "Guided (step by step)" toggle.
- **Scan detail** `/projects/scans/:operation_id`: progress, phases, counters (including `skipped_outside_root`, `skipped_denylisted`), fallback reason, errors, and its scan-review groups (links into Review).
- **Imports:** upload (GraphMem JSON export or Graphify `graph.json`), the existing import review/report pages restyled, and an import history list.
- **Exports:** pick roots → async export with progress (reuses `ExportJob` + `ExportProgressChannel`, currently unreachable).

### 2.7 System (operator only)
Health (`/system/health`, also `.json`), Settings (regrouped; every `AppSettings` field reachable, including `enable_contradiction_detection`, `compaction_review_row_retention_days`, the scan subfolder filter and the policy settings), Embeddings, Jobs (Mission Control link), Telemetry, Activity (change sets + audit log), Policies (the §2.5.3 table with toggles and the last runs), Backups (own page; restore needs the filename typed), Access (operator credentials configured?, guest access toggle + status, MCP token configured?, allowed IP ranges, session lifetimes), API docs, Diagnostics (the raw snapshots that used to sit on the dashboard).

---
## 3. Layout, components and design system

### 3.1 Layout
- `layouts/application.html.haml`: sidebar nav + `main` with a page header slot (`content_for :page_header`) and a toast region (`#toasts`, replaces `#flash-messages`; turbo streams append to it).
- `layouts/auth.html.haml` for sign-in. Mission Control keeps its own layout.
- Drop the global `main.container.mx-auto.flex`: it currently forces every page into a flex row.

### 3.2 Components: Haml partials + a small helper API (no new gem)
ViewComponent would add a dependency and a second templating convention for a single-maintainer app. Partials under `app/views/ui/` with `UiHelper` wrappers are enough:

| Component | Partial / helper | Notes |
|---|---|---|
| Page header | `ui/_page_header` (title, subtitle, actions, breadcrumb) | replaces 3 header styles |
| Card / section | `ui/_card` | header, body, footer slots via `capture` |
| Stat chip / health pill | `ui_stat`, `ui_health_pill(status:, label:, href:)` | replaces `dashboard_stat_chip*` |
| Data table | `ui/_table` with column definitions, sticky header, empty state, optional row selection | replaces 5 table styles |
| Filter bar | `ui/_filter_bar` (GET form, chips, "clear all"), state in query params | telemetry, audit, review, search |
| Pagination | one Kaminari theme (`app/views/kaminari/ui/`) | |
| Empty / loading / error states | `ui/_empty`, `ui/_skeleton`, `ui/_error` | Turbo Frame `loading="lazy"` placeholders |
| Toast + undo | `ui/_toast` + `toast_controller.js` | undo button posts to `/changes/:id/undo` |
| Confirm card | `ui/_confirm` (preview list, typed confirmation optional) | replaces `turbo_confirm` for destructive actions; `turbo_confirm` stays for benign ones |
| Entity link / badge | `ui_entity_link(entity)`, `ui_kind_badge(kind)` | always escapes |
| Progress | existing `operation_progress_controller.js` + `ui/_progress` | |
| Command palette | `palette_controller.js` (UI-8) | |

### 3.3 Styling
- Tailwind v4 only. Define design tokens with `@theme` (colours for status, spacing, radius, font sizes) and a handful of `@layer components` classes (`.btn`, `.btn-primary`, `.btn-danger`, `.input`, `.badge`, `.card`) in `app/assets/tailwind/application.css`.
- Migrate page by page; delete `dashboard.css` and most of `graph.css` when their last user is gone (graph.css keeps only canvas/popover rules).
- **Dark mode:** cheap once tokens exist: `@custom-variant dark` on `prefers-color-scheme` plus a manual toggle stored in `localStorage`. Do it in UI-8, not earlier. Cytoscape styles read the same CSS variables.

### 3.4 Turbo usage
- **Frames:** entity panel (`entity_panel`), review detail (`review_detail`), search results (`search_results`, so filters update without a full reload), settings tabs, lazy Home widgets (`loading="lazy"` per widget so a slow embeddings check doesn't block the page).
- **Streams:** review actions (remove/replace row, update counts and the nav badge), toasts, Explore edits (panel refresh + `graph:changed` event so the canvas patches the node/edge instead of reloading the whole graph).
- **Broadcasts:** job progress already uses ActionCable; keep it. Optionally `turbo_stream_from "review_backlog"` so the nav badge updates when the compactor seeds rows.

### 3.5 Accessibility
- Semantic landmarks (`nav`, `main`, `aside`), one `h1` per page, visible focus rings, `aria-current` on the active nav item, `aria-live="polite"` on the toast region.
- Every icon-only button gets `aria-label` (today the top nav mixes icon-only and text links).
- Keyboard: review shortcuts are opt-out-able and never fire inside inputs; Explore offers a list view of the current scope (the canvas isn't accessible on its own) and keyboard node selection.
- Colour is never the only signal (status pills carry text).


---

## 4. Operator flows (top 6)

1. **"What does the graph know about X?"** (operator and guest): type X in the global search (or press `/`). Auto mode returns ranked entities with matching observation snippets. Narrow with project/type/perspective chips, click a result to open the entity panel beside the list, then "Open in Explore" for its neighbourhood.
2. **Fix a wrong or outdated fact:** Search → entity panel → edit the observation inline (or retire it) → toast "Observation updated · Undo" → the change set shows in Home › Recent activity with the operator as actor.
3. **Clean up a duplicate:** in Explore, drag "Synth Widget" onto "SynthWidget" → "Merge into…" → the dialog shows "4 observations move, 2 relations re-point, 1 duplicate dropped, 'Synth Widget' becomes an alias" → Merge → toast "Merged · Undo" (10 min). Later: System › Activity → that change set → Undo, as long as nothing touched since conflicts.
4. **Work the review backlog (10 minutes a week):** Home shows "Needs attention: 4". Open it to see 4 cards. "Alpha Service: 7 relationship proposals (5 high)" → Apply high-confidence (5) → the preview card lists the 5 edges → Apply → toast with Undo. "SynthWidget ↔ Synth Widget (0.92)" → Merge preview → Apply. Dismiss the other two. The inbox-zero state shows what the policies handled overnight.
5. **Scan a project (container install):** Projects › New scan. Paste `/home/steve/Projects/foo` (the same path as on the host, thanks to identity mounting) and get "✓ inside `Projects`, read-only". Dry run, then the real scan. The scan detail page shows live progress, then "3 review groups" → Review & Fix › Scan review. Paste `/home/steve/.ssh` → "Blocked: hidden/secret folder (not overridable)". Paste `/home/steve/Other/x` → "Outside the scan filter (`Projects`). Add `Other` in System › Settings › Project scans". With no mount → "Scans are disabled: no folder is mounted. Add the compose line …" (mcp plan PR-0).
6. **Something is red on Home:** Health pill "Embeddings: 0 % coverage" → System › Embeddings → Test connection → Backfill (job progress inline, link to Jobs) → the pill turns green and vector mode in Search is enabled.

---

## 5. Guardrails

### 5.1 The UI must never
- hard-delete entities or observations, delete duplicate observations in bulk, or run batch writes from Home, Search or Explore. Deletes are Review & Fix actions (with preview) or rake tasks. **Merges are allowed in Explore and Review**, but only one pair at a time, with a preview and undo;
- bulk-apply or auto-apply destructive review kinds (merge, delete_*, reparent, move_observation), manually or by policy;
- render untrusted text as HTML. All JS builds DOM with `textContent` / `createElement` or the shared `lib/dom.js` `escapeHtml`, and Haml escaping is never bypassed with `!=`/`html_safe` on graph content;
- call `/api/v1` write endpoints from browser code (UI writes go through CSRF-protected controllers that set `Current.actor` and a change set);
- widen the scan boundary from a web form (the mount is the hard limit, the subfolder filter can only narrow it, and the denylist can't be edited; mcp plan PR-0);
- restore a backup without typing the backup filename; drop vector indexes or regenerate all embeddings without a confirm card stating the cost;
- show a guest any write affordance, or let one through server-side.

### 5.2 Confirm levels
- **None (toast with undo):** add observation, rename, add relation, retire observation.
- **`turbo_confirm`:** reversible but noticeable actions: remove relation, dismiss, snooze group.
- **Confirm card with preview:** merge (the merge dialog), destructive review applies, reparent with a subtree move, group apply.
- **Typed confirmation:** backup restore, drop indexes, regenerate all embeddings, prune audit log.

### 5.3 Change sets, snapshots and undo (UI-4a)
> **Oct 26-b:** the step list `docs/plans/ui-4a-plan.md` supersedes this section where they differ (see its "Decisions (changeable)").

**Schema** (one migration):
```
change_sets: id bigint PK, uuid varchar(36) UNIQUE, actor varchar(255), kind varchar(64)
             (explore.edit, explore.merge, explore.relation_remove, review.apply, review.group_apply,
              policy.<name>, compaction.auto_merge, undo), summary varchar(255),
             subject_type/subject_id (anchor for the entity panel), snapshot longtext JSON NULL (json_valid),
             undoable_until datetime NULL, undone_at datetime NULL, undone_by varchar(255) NULL,
             undo_of_id bigint NULL, created_at; KEY (created_at), KEY (subject_type, subject_id)
audit_logs: + change_set_id bigint NULL, KEY (change_set_id)
maintenance_report_rows: + change_set_id (see §2.5.1)
```
`Current` gains `change_set`. `Auditable#write_audit` stamps `Current.change_set&.id`. `ChangeSet.record(kind:, actor:, summary:, subject:) { … }` opens the set, yields, and closes it inside the caller's transaction.

**Simple edits** (rename, aliases, observation edit/retire, add/remove relation, add observation, review applies for relationship/stale rows): undo replays the inverse of the set's audit rows in reverse order. Create → destroy (for observations: mark obsolete instead of destroy if anything superseded it). Update → restore the `from` values. Delete → re-insert with the **original id** from the delete snapshot. Each step runs **only if the row still carries the `to` values** (an optimistic check); otherwise the undo is refused as a whole with "Can't undo: X changed since (by Y at Z)". Undo itself is a change set (`kind: "undo"`, `undo_of_id`), so it shows in Activity and can be re-done by the original action.

**Why audit rows alone aren't enough for merges:** `Auditable#write_audit` rescues and only logs failures (by design, so an audit failure doesn't block a write), the entity snapshot drops `embedding`, and `update_column(:memory_observations_count)` bypasses callbacks. So merges get an explicit **snapshot**, written in the same transaction as the merge (if it fails, the merge rolls back):
```json
{ "source": { all memory_entities columns incl. id, project_id, aliases, description, embedded_at,
              "embedding_text": VEC_ToText(embedding) },
  "target": { "id": 2, "aliases_before": "…", "aliases_after": "…" },
  "observations_moved": [ { "id": 11, "trust_score_before": 0.62 }, … ],
  "relations_repointed": [ { "id": 31, "from_before": 1, "to_before": 7, "from_after": 2, "to_after": 7 }, … ],
  "relations_destroyed": [ { full memory_relations row }, … ],      // duplicates + A↔B edges
  "children_reparented": [ { "entity_id": 40, "project_id_before": 5 }, … ],
  "review_rows_closed": [ "row_uuid", … ],
  "preview_digest": "sha256…" }
```
This lives in `NodeOperationsStrategy#merge_into_once` (one place), so **every** merge path writes it: Explore, Review apply, `graph_delete`'s merge op, `POST /api/v1/memory_entities/:id/merge_into/:target_id`, `data_exchange#merge_node` and compaction auto-merges. (Import "merge into existing" is a different operation, `ImportExecutionStrategy#merge_into_existing`, with no source entity to delete. It's covered by the import's own change set, not by this snapshot.) That makes auto-merges undoable for the first time.

**Merge undo** (`ChangeSetUndo::Merge`), taken under `ProjectMembership.with_membership_lock`, then one transaction with the involved entities locked (`ORDER BY id FOR UPDATE`):
1. Refuse if the target is gone, or if an entity named `source.name` now exists in `source.project_scope` (the unique key `index_memory_entities_on_scope_name` would collide).
2. Refuse if any moved observation no longer belongs to the target, any re-pointed relation no longer has its `*_after` endpoints, or any reparented child has since been moved by someone else. Strict, all-or-nothing, with the conflicts listed.
3. Re-insert the source row with its **original id** (explicit-id insert; `embedding` via `VEC_FromText(embedding_text)`, so no re-embedding and no zero-vector placeholder).
4. Move the observations back and restore `trust_score`. No re-embedding: observation vectors don't depend on the entity (`compose_observation_text`, F8).
5. Re-point relations back. Re-create destroyed relations with their original ids, unless the same triple exists now (skip it and report).
6. Remove from the target only the aliases the merge added (`aliases_after − aliases_before`), keeping any added later.
7. `ProjectMembership.sync!` for the source and the reparented children (recomputed from edges rather than trusting stored ids), then recount `memory_observations_count` on both.
8. Restore the review rows closed as dangling by the merge to `active`.

**Why this is safe:** `merge_into_once` only *moves* observations, *re-points* or *deletes* relations, *updates* target aliases and *deletes* the source. Each of those has an exact inverse recorded in the snapshot, ids are preserved (so agents' stored ids work again), and the optimistic checks refuse whenever later work would be overwritten.

**Windows:** the toast offers Undo for **10 minutes**. Activity offers Undo while the change set's `undoable_until` hasn't passed (simple edits 30 days, merges **7 days**, policy runs 30 days) **and** the optimistic check passes. `ChangeSetPruneJob` (nightly) nulls `snapshot` after 30 days. It never deletes the row, which keeps the audit linkage.

### 5.4 Role matrix (pinned by `spec/requests/role_matrix_spec.rb`)

| Surface | Signed out | Guest | Operator |
|---|---|---|---|
| `/operator/login` | form | → `/search` | → `/` |
| Home `/` | → login | → `/search` | ✓ |
| Search, Explore (read) | → login | ✓ | ✓ |
| Explore writes, `/changes/*/undo`, merges | → login / 401 | **403** | ✓ |
| Review & Fix, Projects & Data, System (incl. settings, backups, jobs, api-docs) | → login | **403** | ✓ |
| `/api/v1` GUEST_READ_ACTIONS | 401 | ✓ | ✓ |
| `/api/v1` everything else | 401 | **403** | ✓ (also Bearer token) |
| ActionCable | rejected | rejected | ✓ |
| `/mcp*` | MCP token/IP policy, unchanged | n/a | n/a |

---
## 6. PR series

Conventions are in §0.1 and the order is in §0.3 (Oct 26: chores, UI-1, UI-4a, UI-5, UI-2, UI-3, UI-4b, UI-6, UI-7; the sections below keep their original order). In every PR: request specs for each new route, system specs (`spec/system`, `driven_by :selenium, using: :headless_chrome`) for flows that touch JS, and synthetic fixtures only.

### UI-0 [Claude]: security baseline: ✅ DONE in PR #106 (released in 1.53.0)
- **Delivered** on `claude/ui-0-security-baseline` (PR head `d4de51b` at review: 13 commits, 50 files; merged Oct 22 as `f9febd6` after Steve added `39db049` and `bbda8b9`; CircleCI rubocop/brakeman/rspec green with the system specs running on `cimg/ruby:3.4.1-browsers`). The review bot reviewed it in 5 rounds; the last one ended "Looks good to me — ready for Steve". **CHANGELOG:** `## [Unreleased]` › Security, with six entries (F1 XSS, F2 API auth, F3 login, F4 ActionCable, CSP report-only, Rswag gate). **No version bump**, so the 1.53.0 release commit (rules rewrite) folds it in.
  - **F1:** every `innerHTML` sink that interpolated data is now DOM construction, via the new `app/javascript/lib/dom.js` (`el`, `text`, `br`, `escapeHtml`; pinned in importmap). Covered: tooltip, context menu, observation renderer, drag-drop menu, modal, compaction-review autocomplete. Guards: `spec/javascript_sinks_spec.rb` (static grep) and `spec/system/escaping_spec.rb` (5 headless-Chrome examples with an `<img src=x data-probe=1>` payload). The orphaned `graph/data_manage.js` was deleted, ahead of §6.D-4.
  - **F2:** `ApiAuthentication` lets a request through only with an operator session, or with `Authorization: Bearer` == `GRAPH_MEM_MCP_TOKEN` (timing-safe) **plus** a `McpAccessPolicy` IP pass. Everything else gets 401 + `WWW-Authenticate`, or 403 for a disallowed IP. There's no compatibility flag. CSRF is enforced for cookie sessions and skipped only for a valid bearer; `spec/requests/api/v1/csrf_spec.rb` runs that matrix with forgery protection on.
  - **F3:** `reset_session` on login (and the return-to URL survives it), `session[:role]`/`:user`/`:signed_in_at`/`:last_seen_at`, and the legacy `operator_signed_in` key is still read. `rate_limit` is 10 POSTs per 3 min (429 page). Idle expiry is 24 h and absolute expiry 7 d (`ApplicationController::SESSION_*_TIMEOUT`). Blank credentials are refused. In production, a password still at `changeme` gets **503** on the login page, whatever the username. `docker-compose.yml` passes `OPERATOR_USERNAME`/`OPERATOR_PASSWORD` through.
  - **F4:** ActionCable decrypts the session cookie, accepts only role operator (or the legacy key) and enforces the same expiry. `/api-docs` sits behind `OperatorSessionConstraint`, so others get a 404.
  - **CSP report-only:** the directives as planned, a per-request nonce for `script-src`, and `POST /csp-reports` (rate-limited, logged at warn). `RoleAuthorization` (`allow_guest` hook, nothing opts in yet) and `Current.actor = operator:<user>@<ip>` are in.
  - **Docs:** `docs/mcp_access_control.md` has an "HTTP API (`/api/v1`)" section, and the README env table has `GRAPH_MEM_MCP_TOKEN`, `GRAPH_MEM_MCP_ALLOWED_IPS` and the production 503 note.
- **Leftovers (all low or nit; no security hole) → mcp plan PR-2 §2.20:**
  1. A refused bearer **POST** with no session gets 422 instead of 401/403. (code fixed on `main` in `bbda8b9`; the spec rows are still to add.)
  2. The inline `:javascript` in `data_exchange/import_review.html.haml` has no CSP nonce. It must be fixed before UI-1 enforces CSP.
  3. ✅ `ApiAuthentication`'s duplicate 24 h/7 d timeout constants (done on `main`, `39db049`).
  4. README l.566 has a stray `)`.
  5. The 503 page and its log line still name `OPERATOR_USERNAME`.
  6. The `GRAPH_MEM_MCP_ALLOWED_IPS` default is loopback + private, not just private.
  7. `allow_guest` replaces instead of appending. UI-1 needs this fixed.
  8. The pre-existing `DataExchangeController` CSRF skip.

  There's also a test-hygiene item (§2.21): unstubbed HTTP to `*.test:11434` hosts.
- **What changes for later items:** PR-0 now builds on a `main` that already has UI-0. UI-1 starts from the existing `RoleAuthorization`, `session[:role]` and the report-only CSP. The original UI-0 spec is in `ui-dashboard-plan.2026-10-22-c.md` §6.

### PR-0 and PR-2 (mcp plan): scan mounts and MCP hardening, release 1.54.0
See `mcp-update-plan.md`. On the UI side, PR-0 adds only the Settings › Project scans panel, "check a path" and the scan-form hints. The full path picker comes in UI-6.

### UI-1 [Claude]: app shell, design system, roles (guest), CSP enforced → **1.56.0** ✅ DONE
- **Done:** UI-1a (#123, shell + CSP) and UI-1b (#124, guest role + release), released as 1.56.0 (Oct 26).
- **Step list:** `docs/plans/ui-1-plan.md` (Oct 26). It trims this item to one PR and wins where the two differ (no section routes or 301s yet, branch `claude/ui-1-1.56.0`); its "Decisions (changeable)" list the differences.
- **Branch:** `claude/ui-1-shell-roles`.
- **Files:** `app/views/layouts/{application,auth}.html.haml`, `app/views/ui/*` (§3.2), `app/helpers/ui_helper.rb` (incl. `can_write?`), `app/assets/tailwind/application.css` (tokens + component layer), `app/javascript/controllers/{toast,nav}_controller.js`, `app/views/kaminari/ui/*`, `config/routes.rb` (section routes as thin aliases + 301 redirects), `config/locales/ui.en.yml`, `spec/support/system.rb`. Roles: `role_authorization.rb` (`allow_guest`), `sessions_controller.rb` (guest login), `app/models/app_settings.rb` (`enable_guest_access` field + an uncached reader), new `lib/graph_mem/guest_credentials.rb` (resolves ENV → credentials once at boot; `configured?`, `username`, `fingerprint`; no default password), `config/initializers/guest_access.rb` (boot check: guest password/username ≠ operator's, else error log + guest disabled; info log "guest access: not configured / available"), `api_authentication.rb` (`GUEST_READ_ACTIONS`). CSP switches from report-only to enforced. **Starts from #106:** `RoleAuthorization` and `session[:role]` already exist, and `allow_guest` appends after PR-2 §2.20 item 7. Enforcing CSP needs PR-2 §2.20 item 2 (the import-review nonce) merged and zero report-only violations in the log.
- **Changes:** sidebar nav per §2 with role-aware items; backlog badge (attention groups after UI-5, active rows until then, cached 30 s); toast region; page-header partial; existing pages render inside the shell unchanged; the guest role exactly as in §2.1 and §5.4.
- **Specs:** `spec/requests/role_matrix_spec.rb` (iterates `Rails.application.routes.routes`, builds a request per verb/path with dummy ids, and asserts the §5.4 matrix for signed-out, guest and operator; an allowlist constant is the only way to open a route to guests); `spec/requests/operator/guest_login_spec.rb` (no ENV and no credentials → `guest` + any password, including `guest`, is refused with the generic error and no guest UI is shown; ENV password set → login works with the toggle at its default (on); credentials `guest.password` set and no ENV → works; ENV wins over credentials; toggle off → the next request logs the guest out and login is refused; guest password or username equal to the operator's → refused; changing the configured password → existing guest session is logged out; production with no guest password → guest disabled, operator rule unaffected); `spec/lib/graph_mem/guest_credentials_spec.rb` (resolution order, blank = not configured, no hardcoded default anywhere); `spec/requests/api/v1/guest_access_spec.rb` (each GUEST_READ_ACTION 200, `POST /api/v1/memory_entities`/`summarize`/`scan`/`search/subgraph_by_ids` 403); request specs for the 301s; `spec/system/navigation_spec.rb` (operator sees 5 sections; guest sees Search + Explore only and no edit controls); `spec/helpers/ui_helper_spec.rb`.
- **Acceptance:** every existing page is reachable from the nav; guests can't reach anything outside §5.4 (route-matrix spec green); zero CSP violations with enforcement on.
- **Risks:** CSS collisions with `dashboard.css` (scope new classes `.ui-*` until UI-7 deletes the old file).

### UI-2 [Claude]: Home → **1.59.0** ✅ DONE
- **Done:** UI-2a (#133, editable MCP allowlists + `bin/up` LAN detection, released as 1.58.3, Oct 27) and UI-2b (#134, Home, released as 1.59.0, Oct 28).
- **Step list:** `docs/plans/ui-2-plan.md` (Oct 27, verified at `2cf8dad`). It wins where the two differ: two PRs, **UI-2a** `claude/ui-2a-mcp-access` (runtime-editable, additive MCP allowlists on the settings page + `bin/up` LAN detection; released as **1.58.3**; added by Steve on Oct 27) and **UI-2b** `claude/ui-2-1.59.0` (this Home scope, unchanged, + release).
- **Branch:** `claude/ui-2-home`.
- **Files:** `app/controllers/pages_controller.rb`, new `app/services/home_snapshot.rb` (composes `MaintenanceDashboardSnapshot`, `EmbeddingStatusSnapshot`, `AgentContextsSnapshot`, review digest, recent jobs from `OperationProgress`, recent change sets, `ScanRootPolicy.status`), `app/views/pages/home.html.haml`, `app/views/home/_*.html.haml` (lazy Turbo Frames); remove `pages/dashboard/*` partials as their content moves.
- **Changes:** §2.2. No forms except quick search. Until UI-5/UI-6 land, the removed buttons link to the old pages.
- **Specs:** `spec/requests/pages_spec.rb` (health strip green/amber/red with a stubbed snapshot; digest rows link correctly; no `form` other than search; guest → redirect to `/search`); `spec/services/home_snapshot_spec.rb`; a system spec Home → digest → Review.
- **Acceptance:** Home fits in ~1.5 screens at 1440×900 with synthetic data and renders in < 300 ms with the embedding service unreachable (`OLLAMA_URL=http://127.0.0.1:9`; lazy frames).

### UI-3 [Claude]: Search → **1.60.0**
- **Branch:** `claude/ui-3-search`.
- **Files:** new `app/services/graph_search.rb` (extracted from `app/tools/search_tool.rb`; the tool calls it), `app/controllers/search_controller.rb` (thin, `allow_guest :results, :index`), `app/views/search/{index,_filters,_result,_snippet}.html.haml`, `app/views/entities/_panel.html.haml` + `EntitiesController#panel` (`allow_guest :panel`), `app/javascript/controllers/search_controller.js`.
- **Specs:** `spec/services/graph_search_spec.rb` (parity: same ids/order as `SearchTool#call` for the same args); `spec/tools/search_tool_spec.rb` unchanged and green; request specs per filter and for the vector-unavailable state; a guest panel spec (no "Open in Review", no edit links); a system spec query → filter → panel → Explore.
- **Acceptance:** identical result order to the MCP tool; old `/search?q=&strategy=` links still work.
- **Risks:** this touches the busiest MCP tool. The tool spec suite is the gate, and ranking doesn't change in this PR.

### UI-4a [Claude]: change sets, merge snapshots, undo (backend) → **1.57.0** ✅ DONE
- **Done:** PR #127 (`claude/ui-4a-1.57.0`), merged and tagged as 1.57.0 (Oct 26). What shipped is described in `docs/architecture.md` "Change sets and undo (UI-4a, 1.57.0)".
- **Step list:** `docs/plans/ui-4a-plan.md` (Oct 26). It wins where the two differ (branch `claude/ui-4a-1.57.0`; the merge preview and `EntityMergeService` move to UI-4b); its "Decisions (changeable)" list the differences.
- **Branch:** `claude/ui-4a-change-sets-undo`. **Prerequisite:** §6.D-3 (the F8 fix) merged.
- **Files:** migrations `create_change_sets`, `add_change_set_id_to_audit_logs`; `app/models/change_set.rb`, `app/models/current.rb` (+`change_set`), `app/models/concerns/auditable.rb` (stamp `change_set_id`), `app/strategies/node_operations_strategy.rb` (`merge_into_once` writes the snapshot through the new `app/services/entity_merge_snapshot.rb`; keep the file under 500 lines by moving the merge helpers into `app/strategies/node_operations_strategy/merge.rb` if needed), new `app/services/entity_merge_preview.rb`, `app/services/entity_merge_service.rb`, `app/services/change_set_undo.rb` + `app/services/change_set_undo/{audit_inverse,merge}.rb`, `app/controllers/changes_controller.rb` (`POST /changes/:uuid/undo`, operator only), `app/jobs/change_set_prune_job.rb` + `config/recurring.yml`.
- **Changes:** §5.3 exactly. Compaction auto-merges get a change set with actor `compaction:<run_id>`.
- **Specs:** `spec/services/entity_merge_preview_spec.rb` (the preview matches the actual merge effects on a synthetic graph: counts of moved observations, re-pointed and destroyed relations, reparented children; the preview writes nothing: assert no audit rows or change sets); `spec/services/change_set_undo/merge_spec.rb` (round trip: merge → undo restores the same ids, names, aliases, observation owners, trust scores, relation endpoints, project_ids and the embedding bytes; refuses on a name collision; refuses when an observation moved after the merge; refuses after `undoable_until`; undo of undo = redo); `spec/services/change_set_undo/audit_inverse_spec.rb` (each inverse; refuses when changed since); `spec/requests/changes_spec.rb` (operator 200, guest 403, CSRF required); `spec/strategies/node_operations_strategy_merge_snapshot_spec.rb` (every caller path writes a snapshot; a failing snapshot write rolls the merge back). Plus a concurrency spec (`use_transactional_tests = false`, clean up after): an undo racing a write on the same target blocks on the membership lock and then refuses or succeeds, never a 500 or partial state. That's Steve's rule: block or queue, never race.
- **Acceptance:** any merge made by any path can be undone from the Rails console with `ChangeSetUndo.call(uuid)` within its window; all existing merge specs stay green.

### UI-4b [Claude]: Explore → **1.61.0**
- **Branch:** `claude/ui-4b-explore`.
- **Files:** `app/controllers/explore_controller.rb` (`show`, guest-allowed), `app/controllers/explore/{entities,observations,relations,moves,merges}_controller.rb` (HTML/Turbo, CSRF on, operator only except `entities#panel`), JS: rewrite `controllers/graph_controller.js` into `explore_controller.js` (canvas only; emits `entity:selected`, listens for `graph:changed`; a `readOnly` value from the server disables drag actions and context-menu writes), `graph/drag_drop_manager.js` (Add relation · Move under parent · Merge into…), `graph/context_menu.js` (Edit in panel · Remove relation · Merge into… · Propose deletion; no hard delete, no dedupe), `app/views/explore/merges/_dialog.html.haml`. Delete the `/graph` page and its duplicated search form.
- **Changes:** §2.4.
- **Specs:** request specs per edit endpoint (validation, audit row with actor + change set, Turbo Stream response, project-root protections, duplicate relation → 422, guest → 403 on every one); `spec/requests/explore/merges_spec.rb` (preview renders the counts; create with a stale digest → 409; different types → 422; success creates a change set and returns the toast); system specs: select node → panel; add observation → undo; drag node onto node → relation created; merge via context menu → dialog → merge → undo (drive Cytoscape through the controller's `cy` instance, because canvas drags are flaky headless); guest sees the graph and panel, and right-click shows no write items.
- **Acceptance:** Explore can't delete an entity or bulk-delete anything; every edit, including merges, appears in Activity with the operator actor and can be undone within 10 min from the toast.
- **Risks:** this is the biggest JS change in the series. Keep the Cytoscape config/styles and only restructure the controller.

### UI-5 [Claude]: Review & Fix → **1.58.0** ✅ DONE
- **Done:** UI-5a (#128, no bump) and UI-5b (#129), released as 1.58.0 (Oct 26).
- **Step list:** `docs/plans/ui-5-plan.md` (Oct 26-c, verified at `e826476`). It wins where the two differ: two PRs (UI-5a `claude/ui-5a-review-backend`, no bump, incl. the `contradiction` rows backend; UI-5b `claude/ui-5-1.58.0`, settings panel, page and release), `contradiction` rows seeded by the scheduled stale scan only and applied by keeping one side, `ignore` becomes a 30-day snooze, backfill outside the migration; its "Decisions" list the rest (Steve's marked).
- **Branch:** `claude/ui-5-review-fix`.
- **Files:**
  - migration `add_grouping_to_maintenance_report_rows` (§2.5.1 columns, indexes, batch backfill; suppressions `expires_at`/`source`; signature rewrite for symmetric relates_to);
  - `app/models/maintenance_report_row.rb` (`expired` status, scopes), `app/models/maintenance_report_suppression.rb` (`active` scope honouring `expires_at`), `app/models/maintenance_report.rb` (`review_policy_run`, `contradiction` handling);
  - new `app/services/review_row_classifier.rb` (group_key, anchor, project, confidence, priority, RUN_CAPS), `app/services/review_digest.rb` (attention groups; SQL only), `app/services/review_group_actions.rb` (preview + apply/dismiss/snooze per group, safe-bulk whitelist, cap 100), `app/services/review_policy_runner.rb` + `app/jobs/review_policy_job.rb` (enqueued after compaction/stale/scan runs + nightly in `config/recurring.yml`);
  - `app/services/compaction_review_service.rb` (SQL pagination instead of `paginate_array`; `seed_report` calls the classifier and enforces the ceiling; `suppressed?` honours `expires_at`; the dangling check helper), `app/services/compaction_review_applier.rb` (`preview(row)`), `app/strategies/relationship_discovery_strategy.rb` (`MIN_QUEUE_SCORE`), `app/strategies/dream_state_compactor.rb` (run caps);
  - `app/models/app_settings.rb` (policy toggles per kind, `auto_apply_relationship_min_confidence`, `expire_low_confidence_days`, `review_backlog_ceiling`, `review_attention_threshold`); `app/controllers/operator/settings_controller.rb` + a `_review_policies` settings partial (operator only, audited, range-validated);
  - `app/controllers/review_controller.rb` (`index`, `group`, `show`, `apply`, `dismiss`, `snooze`, `restore`, `update`, `group_preview`, `group_action`), `app/views/review/*` (per-kind detail partials split out of the 204-line `_compaction_review_item`), `app/javascript/controllers/review_keys_controller.js`;
  - remove `data_exchange#compaction_review*` actions, `_compaction_review_confirm.html.haml` and the dashboard approve path.
- **Changes:** §2.5 (all of it).
- **Specs:**
  - `spec/services/review_row_classifier_spec.rb` (the table in §2.5.1 per kind; group keys for both directions collapse).
  - `spec/services/review_digest_spec.rb` (top 10 groups by priority; inbox-zero when nothing ≥ threshold; query count constant as rows grow, via `ActiveSupport::Notifications` counting).
  - `spec/services/review_group_actions_spec.rb` (group apply rejects destructive kinds with nothing changed; cap 100; the preview lists exactly the rows applied; snooze writes an expiring suppression).
  - `spec/services/review_policy_runner_spec.rb` (each policy on and off; destructive kinds are never applied even when settings are tampered; every action has a change set and is undoable/restorable; per-run limits).
  - `spec/services/compaction_review_service_spec.rb` additions (the ceiling skips low-priority seeds; an expired suppression lets a signature back in; symmetric dedupe).
  - `spec/requests/review_spec.rb` (every action per kind; guest 403; counts stream).
  - `spec/requests/operator/review_policy_settings_spec.rb` (fresh install: both auto-apply toggles off; operator turns each on independently; threshold 0.79 / 1.01 → 422, 0.85 → saved and used by the next run; guest and signed-out → 403/redirect; each change writes an AuditLog row).
  - `spec/services/compaction_review_applier_preview_spec.rb` (preview == apply effects for merge, reparent, delete_relation, stale_memory; the preview writes nothing).
  - A system spec: digest → apply a high-confidence group → undo → inbox zero.
  - The r2–r5 concurrency specs in `compaction_review_service_spec.rb` / `stale_memory` absorption stay green and untouched.
- **Acceptance:** with 1,000 synthetic rows (a factory script, not real data), the default view shows ≤ 10 decisions; the page's query count doesn't depend on queue size; policies are off/on exactly per §2.5.3 defaults; nothing destructive can be bulk- or auto-applied.
- **Risks:** the backfill on a large `maintenance_report_rows` table (batch 1,000, no long transaction). Classifier weights are guesses, so they're constants with one spec table, easy to tune.

### UI-6 [Claude]: Projects & Data → **1.62.0** (after PR-0)
- **Branch:** `claude/ui-6-projects-data`.
- **Files:** `app/controllers/projects_controller.rb`, `app/controllers/projects/{scans,imports,exports}_controller.rb`, views under `app/views/projects/`, re-homed `data_exchange#import_*`/`export*` actions (keep the services), `app/javascript/controllers/path_check_controller.js` (live check via `GET /projects/scans/check_path`, which calls `ScanRootPolicy.resolve`), and the merged `ProjectScansController`/`ProjectScanSkillsController` forms.
- **Specs:** request specs (path check: ok / outside filter / denylisted / not mounted; scan create normal + guided; import upload → review → execute → report under the new routes; guest 403 everywhere); a system spec: new scan with dry run → detail page progress (stubbed job).
- **Acceptance:** the Maintenance hub and dashboard scan cards are gone; every scan/import/export is reachable from Projects & Data with history.

### UI-7 [Claude]: System → **1.63.0**
- **Branch:** `claude/ui-7-system`.
- **Files:** `app/controllers/system/{health,settings,backups,access,policies,activity,diagnostics}_controller.rb`; move `operator/{embeddings,telemetry,audit_logs}` under `system/` (routes + views); `app/services/settings_schema.rb` (a single source: group, label, type, validation, help; it renders all fields generically and removes bespoke tab partials where possible); the backups page with typed confirmation; delete `dashboard.css`.
- **Specs:** a request spec per page; every `AppSettings.defined_fields` key appears in exactly one group (the spec iterates the schema); backup restore requires the typed filename (422 otherwise); the health JSON shape; Access shows guest state correctly for each of not configured / available / turned off, and the toggle is operator-only (guest 403).
- **Acceptance:** all settings reachable; no destructive action without its confirm level (§5.2); `dashboard.css` deleted.

### UI-8 [Claude or Devin-simple per item]: polish
Command palette [Claude], saved searches [Claude], dark mode [Claude], keyboard help overlay [Devin-simple once the shortcut list exists], activity feed filters [Devin-simple]. Each is a small PR.

### 6.D Devin-simple chores (no design decisions; `## [Unreleased]` CHANGELOG line, no version bump)
**Oct 26:** D-1, D-2 and D-3 ship together as **one PR, graph_mem 1.55.3** (with a version bump), done by Claude from `docs/plans/chores-d1-d3-plan.md`, which has the re-verified file:line references. The step lists below are the original brief; where they differ, the chores plan wins.
Each item: branch `devin/ui-d<n>-<slug>` off `main`, the listed spec green, the full suite run alone, test DB truncated before and after, and nothing else touched.

- **[Devin-simple] D-1. Review button labels (F5).** In `app/views/data_exchange/_compaction_review_item.html.haml`, lines 196-202: replace each `submit_tag "<Label>", name: "review_action", value: "<value>", …` with `button_tag "<Label>", type: "submit", name: "review_action", value: "<value>", …`, keeping the existing `class:`, `form:` and `data:` options unchanged. (`submit_tag`'s `value:` option overwrites the label, which is why the buttons read `edit/apply/dismiss/…`.) Spec: in `spec/requests/data_exchange_spec.rb`, assert the four labels render and the posted values are unchanged. *Can merge any time; UI-5 later replaces the view.*
- **[Devin-simple] D-2. Schedule the row cleanup job (F6).** (1) In `config/recurring.yml`, add under both `development:` and `production:`: `maintenance_report_row_cleanup: { class: MaintenanceReportRowCleanupJob, queue: low_priority, schedule: at 5:15am every day }`. (2) In `app/controllers/operator/settings_controller.rb` (the `telemetry:` group, line ~147), change `settings: %w[tool_invocation_retention_days]` to `%w[tool_invocation_retention_days compaction_review_row_retention_days]`, and add `compaction_review_row_retention_days: { label:, description: }` next to `tool_invocation_retention_days` in `config/locales/operator_settings.en.yml` (line ~106). Label: "Review rows retention (days)". Description: "Approved, dismissed and ignored review rows older than this are pruned daily. Dismissed suggestions stay suppressed." (3) Spec: extend `spec/jobs/maintenance_report_row_cleanup_job_spec.rb` with "recurring.yml schedules the job in development and production" (load the YAML and assert the class appears). Note for the PR description: `ignored` rows pruned after the window can be re-proposed, because ignoring never wrote a suppression. That's today's intended "snooze" semantics, and UI-5 makes it explicit with expiring suppressions. *Ship any time.*
- **[Devin-simple] D-3. Don't re-embed moved observations during a merge (F8).** In `app/strategies/node_operations_strategy.rb#transfer_observations!`, delete the line `EmbeddingService.embed_observation(observation) if EmbeddingService.vector_enabled?`. Add a comment: "Observation vectors depend only on content/source/tags (EmbeddingService#compose_observation_text), not on the owning entity, so a merge must not re-embed. Calling the embedding service here would hold the membership lock and row locks across HTTP calls." Spec: in the existing merge spec, stub `EmbeddingService.vector_enabled?` → true and assert `EmbeddingService.embed_observation` is **not** called during `merge_into`, and that the observation's `embedding` bytes are unchanged. *Prerequisite of UI-4a.*
- **[Devin-simple] D-4. Remove dead UI code** (after UI-4b and UI-5 have merged; `graph/data_manage.js` is already gone, deleted in #106): the `dm-*` rules in `app/assets/stylesheets/graph.css`, `app/views/data_exchange/_compaction_review_confirm.html.haml`, `app/views/pwa/*` and `test/`. `git add` untracked files before deleting them (repo rule). Spec: the full suite green, plus `rg -n "dm-" app/assets app/views` → nothing.
- **[Devin-simple] D-5. Docs refresh** after each UI PR: update `docs/operator/*.md` screenshots (synthetic data) and the page names in README. Follow the list in the PR's "Docs" section; no wording decisions beyond renames.
- **[Devin-simple] D-6. Drop the transition shims** one release after UI-7: remove the 301 redirects for old paths and the legacy `session[:operator_signed_in]` read. Spec: remove the redirect specs and assert the old paths 404.
- **[Devin-simple] D-7. Query length cap (was M-D1, dropped Oct 26).** The old branch targeted fast-mcp and six tools, three of which (`search_entities`, `search_subgraph`, `get_entity`) no longer exist as separate tools. Redo it on `main`: a `MAX_QUERY_LENGTH = 2_048` constant and a guard that raises `GraphMem::InvalidArgumentsError` ("Query is too long (max 2048 characters).") for the `query` argument of `search_tool.rb`, `get_entities_tool.rb`, `rank_observations_tool.rb` and `summarize_tool.rb`, plus `maxLength: 2048` in each advertised input schema if the vendored schema DSL (`lib/graph_mem/mcp_schema/`) emits it; otherwise the runtime guard only. The `tools/list` snapshot spec will need re-recording; say so in the PR. Spec: a 2,049-char query returns the tool error envelope; a 2,048-char one passes. *Ship any time; low priority (the 4 MiB body cap already bounds it).*
- **[Devin-simple] D-8. Tool description length spec (was M-D2, dropped Oct 26).** `spec/lib/graph_mem/mcp_instructions_spec.rb` already caps the server `instructions` at 2,048 chars, so only the tool half is left: a spec asserting every registered tool's `description.length <= 2048` for every profile. *Ship any time.*

### 6.F Follow-ups (small, specified items found in review)

- **[Claude] F-1. MCP errors never reach the log** (found in the #134 review, Oct 28). `lib/graph_mem/official_mcp.rb:10-12` (`EXCEPTION_REPORTER`) hands the `mcp` gem's internal errors (its -32603 path, failed notifications) to `Rails.error.report(exception, handled: true, context: { mcp: context.to_h })`, but the app registers **no** `Rails.error` subscriber (`rg -n "Rails.error.subscribe" app lib config` → nothing). `ActiveSupport::ErrorReporter#report` only calls subscribers; `Rails.error.logger` is used only when a subscriber itself raises. So these errors are dropped silently. #134 hit the same gap in `PagesController#home_section` and worked around it with an explicit `Rails.logger.error` (`app/controllers/pages_controller.rb:25-27`).
  - **Fix (preferred): one small subscriber, which fixes every caller at once.** New `config/initializers/error_logging.rb` with a `GraphMem::ErrorLogSubscriber` (`report(error, handled:, severity:, context:, source:)`) registered with `Rails.error.subscribe`. It logs one line at **error** level: `"#{error.class}: #{error.message}"` plus `source` and the context. Rules:
    - Log **handled** reports only (`return unless handled`). Unhandled ones (requests, jobs) are already logged by Rails, and logging them here would duplicate them.
    - **No secrets or payloads.** The gem passes `{ request: params }` (and `{ request: request }`) as context, i.e. the raw JSON-RPC params, which can carry tool arguments and observation text. Reduce `context[:mcp]` to `method` and the tool `name` when present, never `arguments`. Pass the rest through `ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)`, and truncate the logged context (e.g. 500 chars).
    - Never raise from the subscriber (rescue, then `Rails.logger.error` a fixed line).
    - Then remove the explicit `Rails.logger.error` in `PagesController#home_section` (keep `Rails.error.report`), so a broken Home widget is logged once, not twice, and update its spec to assert the line through the subscriber.
  - **Alternative:** an explicit `Rails.logger.error` next to each call site (`official_mcp.rb:11`, like `pages_controller.rb:27`). Smaller, but every future `Rails.error.report` call has the same trap.
  - **Specs:** `spec/initializers/error_logging_spec.rb` (or `spec/lib/graph_mem/error_log_subscriber_spec.rb`): a handled `Rails.error.report(StandardError.new("synth failure"), handled: true, context: { mcp: { request: { method: "tools/call", params: { name: "search", arguments: { query: "SynthWidget" } } } } })` writes one error line containing the class, message, `tools/call` and `search`, and **not** `SynthWidget`; a context with `token: "synth-secret"` shows `[FILTERED]`; an unhandled report (`handled: false`) writes nothing; a subscriber failure doesn't raise. Plus one spec through `GraphMem::OfficialMcp::EXCEPTION_REPORTER.call(error, { request: … })`. Existing `pages_spec` broken-widget example stays green.
  - **Size:** a patch: **1.59.1** on its own, or folded into the next PR (UI-3). Steve decides the version.

---

## 7. If I were the admin

- **Command palette (`Ctrl/Cmd-K`):** jump to any entity (search-as-you-type over names/aliases), any page, any action ("Run stale scan", "Open scan review"). Cheap with the existing `entity_search` endpoint.
- **Saved searches and pinned entities:** stored in a small `operator_preferences` table (or `localStorage` if Steve prefers zero schema), shown on Home.
- **Health page that answers "is it OK?" in one glance:** DB, embedding service latency, vector readiness, solid_queue backlog/failed, last backup age, disk free on `storage/` and the backup path, scan roots mounted read-only, MCP access mode, version + migration status. Also `.json` for an uptime monitor.
- **Activity feed as the spine:** change sets (UI-4a) ("operator merged A into B", "agent claude-1 wrote 6 observations"), filter by actor/agent/entity, link every row to the entity panel, undo where possible. It turns the audit log from forensic tool into daily view.
- **Per-agent view:** what each MCP client (X-MCP-Client) wrote in the last day, its error rate (from telemetry), and its context project. Useful when an agent goes rogue.
- **"Why is this here?" on every observation:** source (tool, scan, import), actor, created/valid times, trust score, superseded chain.
- **Entity timeline:** observations over time with obsolete/superseded markers, so stale facts are visible without the stale scanner.
- **Review queue SLA hint:** oldest-item age per queue on Home; amber after 7 days.
- ~~Read-only viewer login~~ → decided: the guest role (§2.1, UI-1).
- **Undo everything that's undoable from one place:** Activity lists change sets with an Undo button while the optimistic check passes (§5.3). That includes compaction **auto-merges**, which today can't be reversed at all.
- **Graph canvas niceties:** focus mode (neighbourhood depth 1/2), hide `part_of` edges toggle, colour by project, "path between A and B" (the `find_shortest_path` service already exists).

---

## 8. Remaining questions for Steve

None. Everything asked so far is answered (§0.2, decisions 1–10). Two items depend on Steve's own commits, not on a decision:
- Add the `guest:` entry (`username`, `password`) to Rails credentials (decision 8). Until then guest login stays disabled, which is the intended safe state.
- ~~If you'd rather have the UI series before the migration finishes~~ moot: the migration is done (Oct 26), and the order is set in §0.3.
