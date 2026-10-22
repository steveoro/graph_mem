# graph_mem agent-facing text plan: rules, skill, prompts, tool descriptions, server instructions, eval

**Version 2, 2026-10-22 b (Europe/Rome)**, after Steve's 10:44 answers. Version 1 is `agent-rules-plan.2026-10-22-b.md`. What changed: the rewrite ships **as soon as possible** as graph_mem **1.53.0**, on one Claude branch; the eval no longer gates it and becomes post-release validation; embeddings are on for the real comparison; the memory homes are approved; there's no contact with Letta. Written for Steve, for **Claude** to implement locally, with simple step lists for Devin.
**Oct 22-c update** (17:15; `agent-rules-plan.2026-10-22-c.md` is the version before it):
- **UI-0 is done** in graph_mem PR #106, which wrote `## [Unreleased]` › Security without a version bump. So the 1.53.0 release commit (commit 5) also releases UI-0. No version number moved.
- The rewrite is **next up**: step 0 no longer blocks it (§C row 0), and it branches off `main` after #106 merges.
- The fast-mcp question is closed (mcp D-24).

Third track next to `mcp-update-plan.md` and `ui-dashboard-plan.md` (same folder; one shared release train, §C).
Input: an internal research brief (FrontierMemory 1.0 by Letta, audited against graph_mem `57d9524`). I re-checked every graph_mem claim against a read-only graph_mem checkout (`57d9524`, v1.52.1) and the fast-mcp clone (`main` @ `b2a8eb8`; graph_mem's `Gemfile.lock` pins `b10243c`, an ancestor). Results are in §0. Nothing was pushed, posted or opened on GitHub. No private client code was read or used.

**Why this track exists.** FrontierMemory scores memory by downstream task success. Its lessons (all **[AUTHORS' VIEW]**, not ablated) are:
- Imperative, situation-keyed "use when" text gets loaded; topic summaries don't.
- Over-specific memories don't transfer.
- Newer rules must supersede older ones.
- Implicit applicability is the hardest case: 0/120 runs passed on Awilix Implicit.

graph_mem's agent-facing text is good at routing ("Do not use X; use Y") but fires on *mentions of the tool*, not on *task situations*. This plan rewrites that text and measures the effect with a local eval, so the claims become measured for graph_mem.

---

## A. Implementer brief (read first)

| | |
|---|---|
| **Repos** | `steveoro/graph_mem` (main @ `57d9524` when written; Rails 8.1, Ruby 3.4.1, RVM `ruby-3.4.1@graph_mem`, MariaDB 11.8+). One fast-mcp item (§1.13 of the mcp plan) lives in `steveoro/fast-mcp`. Read `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*` and the other two plans' briefs (mcp §A, UI §0.1). The same rules apply. |
| **Who does what** | **[Claude]** does the whole rewrite on **one branch**: AR-D1, AR-D2, AR-D3 and AR-T, as separate commits in that order. The exact AR-D step lists in §D still apply; Claude copies their text and doesn't rephrase it. Claude also builds the eval harness (AR-E) and any follow-up fixes (AR-F). **[Devin-simple]** only does AR-D4, the docs follow-ups after the release. Stop and ask if a step doesn't match the code. |
| **Branches** | `claude/ar-rules-rewrite` off current graph_mem `main`. It's independent of the CircleCI-fix branches (`claude/pr-1-hardening-1.8.0` is in fast-mcp; `devin/m-d1-query-cap` and `devin/m-d2-description-length` are in graph_mem). Branch it off `main` **after PR #106 (UI-0) has merged**. It's the next Claude item now: graph_mem's CircleCI is fixed by #106, and Claude's fast-mcp branch waits for PR-1 (§C row 0). Later work: `claude/ar-e-eval` (harness), `claude/ar-f<n>-<slug>` (follow-ups), `devin/ar-d4-docs`. No force-push after review starts. Agents never merge, tag or push tags; Steve merges and tags. graphy-review[bot] reviews every PR. |
| **Versions** | The rewrite branch is the **graph_mem 1.53.0** release PR. Its last commit bumps `lib/graph_mem/version.rb` from `1.52.1` to `1.53.0` and renames `## [Unreleased]` to `## [1.53.0] - <merge date>`, folding in whatever `[Unreleased]` lines `main` already has: **always #106's UI-0 `### Security` section** (keep its six entries verbatim under `## [1.53.0]` › Security), plus M-D1/M-D2 if they merged first (mcp plan D-23). AR-E and AR-D4 add `[Unreleased]` lines and never bump. Follow-up fixes are 1.53.x patches. |
| **Running specs safely** | Same as the other plans: `source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem`, `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9`, test DB truncated before and after (UI plan §0.1), full suite run alone, nothing listening on 11434, no scratch files left behind. |
| **The eval is not the suite** | The LLM-driven eval (§8) lives in `eval/agent_memory/`, outside `spec/` and outside Zeitwerk. It never runs in CI or in `bundle exec rspec`, and it uses its own databases (`graph_mem_eval_*`), never the dev, test or prod DBs. Two Ollama modes:<br>• **Real comparison** (`agent_eval run`): `--embeddings` is the **default**. It uses Steve's local Ollama (`OLLAMA_URL`, default `http://127.0.0.1:11434`) against the eval DBs only.<br>• **Smoke and CI-adjacent runs** (`agent_eval smoke`, `--no-embeddings`, and everything in `spec/eval/`): `OLLAMA_URL=http://127.0.0.1:9`, which is unroutable.<br>Only the eval's deterministic parts (verifiers, corpus builder, metrics) get rspec coverage, in `spec/eval/`, with no LLM and no network. The rspec suite itself keeps `OLLAMA_URL=http://127.0.0.1:9` as always. |
| **Fixtures and tasks** | Synthetic only, or open-source repos Steve names. **Never use private client code, not even read-only, and never mention it in PRs, tasks, corpora or results.** |
| **Text rules** | Every agent-facing string is **situation-first and imperative** ("Call before…", "Use when…"). Mechanics come after the trigger sentence. The routing sentences stay ("Do not use X; use Y"). Advertised text names only canonical tools (never `search_entities`, `create_entity` or other hidden aliases). Limits: tool descriptions and `instructions` ≤ 2,048 chars (mcp decision D-7); skill `description` ≤ 1,024 chars (Agent Skills frontmatter limit); always-on rules file ≤ 45 lines. |
| **Done criteria** | Required specs green; full suite green when run alone; rubocop; brakeman; 0 rows in the test DB; CHANGELOG. The rewrite branch does **not** wait for the eval (§8.6). AR-E is done when its smoke run works and the README records the measured time and cost per run. |

## B. Decisions (Oct 22, 2026; Steve's Oct 22-b answers applied)

1. **One skill, situational description.** Context-Bench Skills reports a cost for picking a skill from a library, so we keep one skill and make its description situational (§1).
2. **Memory homes (approved by Steve, Oct 22-b).** graph_mem has no `Conventions` entity type, and adding one would need a vocabulary change. So we use existing types:
   - project conventions → an entity named **`<Project name> Conventions`**, type `BestPractice`, `part_of` the Project;
   - user preferences → one **global** entity **`User Preferences`**, type `Preference`, no `part_of`;
   - environment facts → the `Component` / `Configuration` / `File` entity they describe.

   Prompts, rules and the skill all name these homes the same way. AR-T first checks how `graph_write create_entity` scopes an entity with no `part_of` while a context is active, and documents how to create the global entity (§4, step 0).
3. **Instructions: the text ships now, delivery waits for fast-mcp 1.8.0.** `Server.new(instructions:)` (a String, or a callable that takes the request and returns a String or nil) lands in **fast-mcp 1.8.0** (mcp plan PR-1 §1.13). The rewrite (1.53.0) adds `GraphMem::McpInstructions.for(profile)` with the final per-profile texts and specs on their length and tool names. Nothing calls it yet, because fast-mcp 1.7.1 can't send it. mcp plan PR-2 §2.17 wires it in **1.54.0**, and that's when agents first see `instructions`. The migration carries it over to the gem's `instructions:` (mcp plan MG-4).
4. **One Claude branch, ASAP (Steve, Oct 22-b).** graph_mem has been misused for months, so AR-D1, AR-D2, AR-D3 and AR-T go out together as **graph_mem 1.53.0**. They're separate commits on `claude/ar-rules-rewrite` off `main`, independent of the CircleCI-fix branches. Only the `instructions` wiring is left out (decision 3). *(Oct 22-c: `main` now includes UI-0 from PR #106, so 1.53.0 also releases the security baseline; the text work is unchanged.)*
5. **The eval validates; it doesn't gate.** AR-E and the eval run come **after** the 1.53.0 release. The `old` arm runs from the pre-rewrite `main` commit in a git worktree, and the `new` arm runs from the 1.53.0 release commit. If new is worse than old, the answer is a follow-up fix PR (AR-F, a 1.53.x patch), not a revert or a block (§8.6).
6. **Deferred** (listed in §9, not in this series):
   - the brief's lesson-distillation pass (§5.4), as review-queued rule proposals;
   - the `conflicts` hint on default reads (§5.3);
   - per-client instrumentation beyond what the eval already extracts from Claude Code's `stream-json` output and the existing `tool_invocations` telemetry (§5.6).
7. **Embeddings on for the real comparison (Steve, Oct 22-b).** It uses the local Ollama against the `graph_mem_eval_*` DBs only. The unroutable URL stays the default for smoke and CI-adjacent runs (§A). If Max-plan rate limits bite, the first pass may be the 6-task / 72-run subset (§8.4).
8. **Self-measured only (Steve, Oct 22-b).** No contact with Letta, and no FrontierMemory submission or HF access request. The question is closed.

## C. Release-train placement (identical to mcp plan §C and UI plan §0.3; `D-nn` numbers refer to the mcp plan's decisions)

| # | Item | Repo / version | Who | Depends on |
|---|---|---|---|---|
| 0 | CircleCI fixes. **Status Oct 22, 17:15 (Europe/Rome):** graph_mem's CircleCI is fixed by PR #106 (ruby orb 4.0, `cimg/ruby:3.4.1-browsers` for rspec so the system specs run, `structure.sql` zero-vector DEFAULTs; all green at `d4de51b`). Still open: `devin/m-d1-query-cap` (`35c6423`) and `devin/m-d2-description-length` (`8ff8a9c`): no commits since Oct 21 evening, CircleCI rspec red (rubocop/brakeman green), no PR; Devin merges `main` after #106 and re-runs CI. fast-mcp `claude/pr-1-hardening-1.8.0` (`9f2c72a`): unchanged since Oct 21 18:24, no PR, **no CI has ever run on it** (fast-mcp's GitHub Actions run only on `main` pushes and PRs); Claude runs its suite locally when it resumes PR-1 (row 2, D-22) | n/a | [Devin-simple]; [Claude] at row 2 | #106 merged (Devin branches) |
| 1 | **AR** rules & skills rewrite: commits AR-D1 (stale hints), AR-D2 (schema fields), AR-D3 (Cursor `.mdc`), AR-T (agent text) on `claude/ar-rules-rewrite`; bumps to 1.53.0, and its release commit also releases UI-0 (it folds #106's `[Unreleased]` Security section into `[1.53.0]`) | graph_mem **1.53.0** | [Claude] | off `main` after #106 merged; **next up** (step 0 no longer blocks it) |
| 1a | **AR-E** eval harness, then the post-release eval (old arm = pre-rewrite `main` in a worktree, new arm = the 1.53.0 release commit) | graph_mem `[Unreleased]` (dev tooling) | [Claude] builds, Steve runs | 1.53.0 tagged |
| 1b | **AR-F<n>** follow-up text fixes, only if the eval shows new worse than old (validate and iterate) | graph_mem 1.53.x (patch) | [Claude] | eval result |
| 1c | **AR-D4** docs follow-ups | `[Unreleased]` | [Devin-simple] | 1.53.0 |
| 2 | **PR-1** fast-mcp hardening + negotiation + `instructions:` (§1.13) + SDK 1.8.1 conformance (§1.14), continued on `claude/pr-1-hardening-1.8.0` (`9f2c72a`, §0c) | fast-mcp **1.8.0** (Steve tags `v1.8.0`), the short-term bug-fix release | [Claude] | n/a (runs in parallel with row 1) |
| 3 | ✅ **UI-0** security baseline: **DONE in PR #106** (`claude/ui-0-security-baseline`, merged as `f9febd6`; `/api/v1` auth, login hardening, JS escaping, cable/api-docs auth, CSP report-only; 5 review rounds, CI green, merged Oct 22). Its leftover lows are PR-2 §2.20 | graph_mem `[Unreleased]` (#106 doesn't bump) → released in **1.53.0** | [Claude] | done |
| 4 | **PR-0** home mount, ScanRootPolicy, subfolder filter, denylist | graph_mem `[Unreleased]` → 1.54.0 | [Claude] | UI-0 merged (#106 ✅) |
| 5 | **PR-2** MCP hardening + fast-mcp 1.8.0 bump + the two high bugs + `instructions` wiring (§2.17) + the #106 leftovers and test hygiene (mcp §2.20–2.21); **bumps to 1.54.0** | graph_mem **1.54.0** | [Claude] | PR-1 tagged, PR-0 merged, 1.53.0 merged |
| 6 | **PR-3** interop specs/scripts (+ docs); engine-agnostic, the migration's safety net | graph_mem **1.54.1** | [Claude] + [Devin-simple] | 1.54.0 |
| D | **M-D1** query cap, **M-D2** description-length spec (D-23), **M-D3** docs line-refs (after PR-2) | `[Unreleased]` | [Devin-simple] | as listed |
| 7 | **MG-0** migration design (reads `ruby_mcp` `a0ff088`); a written doc, no release | n/a | [Claude] | PR-3 merged |
| 8 | **MG-1** adapter layer, `mcp` gem, engine switch (default fast-mcp), 3 pilot tools | graph_mem **1.55.0** | [Claude] | MG-0 approved by Steve |
| 9 | **MG-2a** tools batch A: the 12 `/mcp` tools + parity-spec template | graph_mem 1.55.1 | [Claude] | MG-1 |
| 10 | **MG-2b** tools batch B: the other 28 tool classes | graph_mem 1.55.2 | [Devin-simple] | MG-2a |
| 11 | **MG-3** resources and prompts | graph_mem 1.55.3 | [Claude] | MG-2a |
| 12 | **MG-4** transports and auth on the gem; the official engine becomes the default | graph_mem **1.56.0** | [Claude] | MG-2b, MG-3 |
| 13 | **MG-5** 2026-07-28 dual era through the gem | graph_mem **1.57.0** | [Claude] | MG-4 |
| 14 | **MG-6** drop fast-mcp + **MG-D1** docs | graph_mem **1.58.0** | [Claude] + [Devin-simple] | MG-5 |
| 15+ | UI series UI-1 … UI-7 | graph_mem 1.59.0 … 1.66.0 | [Claude] | 1.58.0 |

**Why 1.53.0.** It's the next graph_mem release, and it can ship now: nothing in it needs fast-mcp 1.8.0 except the `instructions` wiring, which waits for 1.54.0. Steve's earlier rule rules out a v1.52.2 (mcp S-7). AR-D2 adds fields to two tool schemas, so this is a minor. The hardening bundle keeps its content and becomes 1.54.0. Everything after it moves up: PR-3 is 1.54.1, the migration is 1.55.0–1.58.0, and the UI series is 1.59.0–1.66.0.

**Overlap with Devin's branches.** `devin/m-d2-description-length` adds a 2,048-char description spec, and the AR-T texts are written to fit it (§0: `search` grows from 980 chars). Whichever of the two merges second rebases and re-runs that spec. `devin/m-d1-query-cap` touches the `query` arguments of the search tools, but not their descriptions. If both branches touch `search_tool.rb`, the rewrite rebases.

---

## 0. Verification of the brief (graph_mem `57d9524`, fast-mcp `b10243c` / `b2a8eb8`)

| Brief claim | Result | Evidence |
|---|---|---|
| Skill trigger is mention-based | **Confirmed** | `skills/graph-mem-mcp-toolset/SKILL.md:3` and `.cursor/skills/…/SKILL.md:3` carry the identical description, quoted correctly in the brief |
| No MCP `instructions` | **Confirmed** | `config/initializers/fast_mcp.rb:27-31` passes only `name:`, `version:`, `logger:`. No `instructions` anywhere in `app/`, `lib/`, `config/` |
| fast-mcp can't send them | **Confirmed** for both `b10243c` (pinned) and `b2a8eb8` (main) | `Server#initialize(name:, version:, logger:, capabilities: {})` (`lib/mcp/server.rb:44`); `handle_initialize` (:356-378) returns `protocolVersion`, `capabilities`, `serverInfo` only; `rg instructions lib` → no hits |
| Prompts orient / recall / persist | **Confirmed**, quoted accurately | `app/prompts/{orient,recall,persist}_prompt.rb`. `persist` isn't on readonly; `spec/prompts/workflow_prompts_spec.rb` pins only a few keywords, so the rewrite can keep them |
| Hidden graph_write fields at `graph_write_service.rb:233-238` | **Confirmed** (the `create!` block is 230-239; fields 232-238: `content`, `confidence`, `source`, `perspective`, `valid_from`, `valid_until`, `tags`) | Schema `graph_write_tool.rb:36-49` lists only `type, name, entity_type, entity_id, text_content, from/to_entity_id, relation_type` with `additionalProperties: true`. Model validation: `confidence` 0..1, `perspective ∈ {world, experience}`, `valid_until ≥ valid_from` (`memory_observation.rb:44,47,123`) |
| — (missing from the brief) | **Also hidden: relation `weight`, `confidence`, `properties`** | `graph_write_service.rb:273-279` |
| — (missing from the brief) | **`graph_edit` has no item schema at all** | `graph_edit_tool.rb:25` `required(:operations).array(:hash)`. The update fields (`text_content, confidence, source, valid_from, valid_until, tags, perspective`, `supersede`, `reason`) only show up in an error message (`graph_edit_service.rb:109-117`). That's the very tool the brief wants agents to use for supersession |
| 146-line always-on rules file, byte-identical in 3 places | **Confirmed** | `wc -l` = 146; md5 identical for `docs/rules/`, `.cursor/rules/`, `.devin/rules/`. "About 60% ops detail": l.44-89 + 91-103 + 105-121 = 76 of 146 lines, **about 52%**. Same conclusion |
| Cursor shim names `search_entities` / `create_entity` and missing "execution templates" | **Confirmed** | `.cursor/skills/…/SKILL.md:21-22` ("canonical skill's execution templates"; the canonical skill has no templates section: `rg template` → none) and `:26` |
| graph_delete hints → nonexistent `graph_edit move_to_parent` / `graph_write update_entity` | **Confirmed** at `graph_delete_service.rb:40` and `:138` | `GraphEditService::TYPES = update_entity update_observation`; `GraphWriteService::TYPES = create_*`. `move_to_parent` exists only in `NodeOperationsStrategy` (UI/compaction), not over MCP |
| — (missing from the brief) | **A third stale hint:** `relation_semantics.rb:53` "use move_to_parent instead" | Raised from `MemoryRelation` validation (`memory_relation.rb:56`), so MCP `graph_write create_relation part_of` returns it when the entity already has a parent. There's no MCP `move_to_parent`. The real MCP route is `graph_delete delete_relation`, then `graph_write create_relation` |
| `docs/dream_state.md` tells agents to call maintenance-only `dream_state_status` | **Confirmed** at l.321 ("At session start, call…"), and **also l.244** ("Agents should call `dream_state_status`…") | `dream_state_status_tool.rb` → `profiles: %i[maintenance]`. The always-on rules l.97 says the same without naming the profile |
| `docs/rules/README.md:25` names no `.mdc` file | **Wrong as stated.** It does name `.cursor/rules/graph_mem.mdc` | **But the real bug is worse:** the repo's own copies are `.cursor/rules/graph_mem_mcp_rules.md` and `general_coding_rules.md` (`.md`), and Cursor's docs (cursor.com/docs/rules, checked 2026-10-22) say "Project rules must use the `.mdc` extension. A plain `.md` file in `.cursor/rules` is ignored." So Cursor currently loads **neither** always-on rule in this repo; only `rvm-ruby-commands.mdc` is loaded. Per the docs, not tested in Cursor |
| `CLAUDE.md:32` profile counts 12 / 9 / 22 | **Confirmed** | flags counted per tool class: 9 readonly + 3 writes = 12; +10 maintenance = 22 |
| "41 classes" in `app/tools` | Nit: 41 **files** = 40 tool classes + `ApplicationTool` | `docs/mcp_tools.md` says 40 |
| Description length headroom | Checked | `search` description is 980 chars, `graph_write` 518, so the openers fit under 2,048 |
| **Own-plan bug found** | mcp plan M-D2 asserts "the server `instructions` string from `config/initializers/fast_mcp.rb` ≤ 2,048", but no such string exists | fixed in the mcp plan (M-D2 now checks it only when non-nil) |

---

## Items in priority order (the brief's §7)

### 1. Skill description: situational "use when" (AR-T) [Claude]
**Files:** `skills/graph-mem-mcp-toolset/SKILL.md`, `.cursor/skills/graph-mem-mcp-toolset/SKILL.md` (the shim keeps the identical description; a spec enforces it).

**New frontmatter description** (≈ 600 chars):
```yaml
description: >-
  Use at the start of any coding task in a project where the graph_mem MCP
  server is connected, and again before you decide a convention (version bump,
  changelog or docs style, test style, naming, file or config location, release
  steps) or edit a file or component for the first time in the session. Use
  before your final reply when the user corrected you or stated a preference,
  or when you found where something lives or verified a fix. Also use when the
  user mentions graph_mem, memory, "remember this", "like last time" or "as usual".
```
**Body changes:**
- The first section becomes "When to use this skill" (the trigger list from item 5).
- Add a **Call templates** section, which also makes the shim's reference true. It holds one JSON example each for `search` (by file path), `get_entities`, `graph_write create_observation` (with `source` and `valid_until`), `graph_edit update_observation` with `supersede: true`, and creating the two home entities (decision 2).
- The dream-state and maintenance paragraphs move to the reference doc (item 5).

### 2. Trigger-first openers for `search` and `graph_write` (AR-T) [Claude]
**Files:** `app/tools/search_tool.rb`, `app/tools/graph_write_tool.rb`, `app/tools/graph_edit_tool.rb`, `app/lib/tool_success_response.rb`.
- **`search`**: prepend this text; the rest stays unchanged (980 → about 1,310 chars):
  > "Recall what earlier sessions learned before you act. Call before choosing a convention (version bump, changelog, docs or test style, config location, release step) and before first editing a file or component named in the task; query by the task's project, file paths and component names, not only by topic. "
- **`graph_write`**: prepend (518 → about 1,050 chars):
  > "Persist a durable lesson. Call when the user corrects you or states a preference, when you learn where something lives, or when a fix or procedure is verified. Write each observation as one general, imperative rule with scope and reason (\"In <project>, when <situation>, do <action> because <reason>\"), not a log of what happened; set `source`, and `valid_until` for time-bound facts. To correct a stored rule, use `graph_edit` update_observation with `supersede: true` instead of appending. "
- **`graph_edit`**: prepend:
  > "Rewrite what the graph already knows. When a stored rule or fact is outdated, call update_observation with `supersede: true` (history is kept) rather than adding a new dated observation. "
- **`next_move` nudges** (`ToolSuccessResponse::DEFAULT_HINTS`):
  - `search`: "Apply any matching rules before editing; if a rule needs a value you don't have, look it up first. Call `get_entities` with selected ids for full detail."
  - `get_entities`: "Apply matching rules before editing. Call `traverse_graph` when neighbouring entities or edges are needed."
  - new `get_context` hint, active context only: "Load the project's Conventions entity with `get_entities`, then `search` by this task's file paths and decisions."
  - `graph_write`: "Call `get_entities` to verify. If this corrects an older rule, supersede the old observation with `graph_edit`."

### 3. Expose the hidden write fields (commit AR-D2, in 1.53.0) [Claude, following the §D step list]
Step list in §D. Summary:
- `graph_write` `operation_properties` gain `source`, `confidence`, `valid_from`, `valid_until`, `tags`, `perspective`, plus relation `weight` and `properties`.
- `graph_edit` gets an item schema for the first time (`type`, `entity_id`, `observation_id`, `name`, `entity_type`, `aliases`, `description`, the observation update fields, `supersede`, `reason`), with `additionalProperties: true` kept so nothing breaks.
- No service change: the services already accept every field.

### 4. Prompts: recall, persist, orient (AR-T) [Claude]
**Files:** `app/prompts/{orient,recall,persist}_prompt.rb`, `spec/prompts/workflow_prompts_spec.rb`. Prompt descriptions become situational too:
- orient: "Run at the start of a task: sets the project context and loads its conventions and the user's preferences."
- recall: "Run before choosing a convention or first editing a file or component: recalls rules by topic, file paths and decision type."
- persist: "Run before your final reply when you were corrected, learned a preference or location, or verified a fix."

**Step 0 (verify first):**
- Check how a `create_entity` with no `part_of` is scoped while a context project is active (`GraphWriteService` around l.185, `project_id:`).
- If it lands in the context project, the persist text and the skill templates must say "create `User Preferences` with `set_context` cleared, or pass the documented global-scope option". Use whichever the code supports. Don't add a new argument in AR-T; if none exists, stop and ask.

**orient**
```
Start GraphMem session orientation:
1. Call get_context.
2. If no context is active, call search for the Project this task belongs to, then call set_context with its entity id.
3. Load the project's "<Project> Conventions" entity and the global "User Preferences" entity with get_entities (search for them by name if you don't have their ids; skip any that don't exist yet).
4. Keep their active rules as a checklist for this session; a newer active observation overrides an older one.
5. Before choosing a convention or first editing a file or component, run recall or search by those file paths and component names.
Context is per X-MCP-Client, and the context project boosts search results rather than filtering them.
```
**recall** (`topic` stays required)
```
Recall GraphMem knowledge for: #{topic.inspect}
1. Call search with the topic, then search again with this task's file paths, component names and decision types (for example "version bump", "changelog", "docs examples", "tests", "config").
2. Load the best ids with get_entities. If you haven't yet this session, also load the project's Conventions entity and the global User Preferences entity.
3. Turn each relevant rule into a checklist item for this task. If a rule depends on a value you don't have yet (a tier, a flag, a config key, a version), find that value in the repository or project metadata before acting.
4. When rules conflict, follow the newest active observation and mention the conflict in your reply.
5. Use traverse_graph or find_shortest_path only when structure matters, and summarize only for a source-backed overview.
Prefer active observations; maintenance tools exist only on the maintenance profile.
```
**persist** (default + maintenance profiles only, as today)
```
Persist durable GraphMem knowledge before your final reply:
1. Keep only what a future session would need: user corrections and preferences, project conventions, where things live (paths, config keys, commands), verified fixes, and procedures that failed before they worked. Skip one-off task details.
2. Write each as one general, imperative rule with its scope and reason: "In <project>, when <situation>, do <action> because <reason>." Drop incidental specifics (byte sizes, exact ids, timestamps) unless they are the rule.
3. Search the owning entity first. If a rule on the same point exists, rewrite it with graph_edit update_observation and supersede: true; don't append another dated correction. Otherwise use graph_write create_observation with source ("<client>/<model>: <task>") and, for time-bound facts, valid_until.
4. Put user preferences on the global "User Preferences" entity (type Preference), project conventions on "<Project> Conventions" (type BestPractice, part_of the Project), and environment facts on the component or configuration entity they describe. Create a missing home entity with graph_write create_entity first.
5. Follow possible_duplicate and next_move responses; never force a duplicate.
```

### 5. Always-on rules: about 40 lines, the rest behind a signpost (AR-T) [Claude]
**Files:**
- `docs/rules/graph_mem_mcp_rules.md` (replaced by the text below);
- new `docs/rules/graph_mem_reference.md`, which gets every section removed from the always-on file: Workflow Prompts details, MCP tool errors in full, multi-agent scoping details, **Project Scan Validation (l.44-89)**, **Dream-State Compaction Awareness (l.91-103)**, **Standard Compatibility and aliases (l.105-121)**, query/type guidance, observation lifecycle details, conflict handling, and `summarize` internals. Move them verbatim apart from fixing stale names, with a short "for maintenance-profile sessions" header on the scan and dream sections;
- the copies `.cursor/rules/graph_mem_mcp_rules.mdc` and `.devin/rules/graph_mem_mcp_rules.md` (renamed in AR-D3), plus copies of the reference doc next to each.

**New always-on file** (40 lines including frontmatter):
```markdown
---
description: graph_mem MCP memory: when to recall and when to write
globs:
alwaysApply: true
---

# graph_mem: recall before you decide, persist what you learned

graph_mem is a shared knowledge graph of what earlier sessions learned:
conventions, preferences, where things live, verified fixes. Use it alongside
reading the repository, not instead of it.

## Recall: `search`, then `get_entities`
- At task start: run the `orient` prompt (or `get_context` → `set_context`), then
  load "<Project> Conventions" and the global "User Preferences" entity.
- Before choosing a convention: version bump, changelog, docs or test style,
  naming, config location, release steps.
- Before first editing a file or component this session: search by its path and name.
- After a test, CI or verifier failure: search the error text.
- When the user says "like last time", "as usual" or "the way we do it".
- Turn each relevant rule into a checklist item. If a rule depends on a value you
  don't have (a tier, a flag, a config key), find that value before acting.
- When rules conflict, follow the newest active observation and say so.

## Persist: before your final reply
- Write when the user corrected you or stated a preference, when you learned where
  something lives, when a fix was verified, or when a procedure failed before it worked.
- One rule per observation, general and imperative, with scope and reason:
  "In <project>, when <situation>, do <action> because <reason>." No incidental literals.
- Same point already stored → `graph_edit` update_observation with `supersede: true`.
  New → `graph_write` create_observation with `source`, plus `valid_until` if time-bound.
- Homes: "User Preferences" (Preference, global); "<Project> Conventions"
  (BestPractice, part_of the Project); environment facts on the entity they describe.
- Follow `possible_duplicate` and `next_move`; never force a duplicate.

## Context and safety
- Context is per `X-MCP-Client`; it boosts, not filters, search. `set_context(entity_id: null)` clears it.
- Prefer `entity_id` over names for edits and deletes: a bare name can hit another project.
- On errors read `category`, `retriable`, `next_move`; retry only when `retriable` is true.
- Scans, dream-state, review queues, aliases and parameter details (maintenance
  profile `/mcp/maintenance`): see `graph_mem_reference.md` next to this file.
```

### 6. MCP server `instructions` (fast-mcp PR-1 §1.13; texts in AR-T, 1.53.0; wiring in mcp PR-2 §2.17, 1.54.0) [Claude]
**fast-mcp (1.8.0, PR-1 §1.13):**
- `Server.new(…, instructions: nil)` accepts a String, or an object responding to `call(request)` that returns a String or nil.
- `handle_initialize` adds `instructions:` only when the value is non-blank.
- Specs: a String → present; the callable sees the request; nil or blank → key absent; the gem doesn't cap the length (that's the consumer's choice).

**graph_mem 1.53.0 (AR-T commit):**
- New `lib/graph_mem/mcp_instructions.rb` with `McpInstructions.for(profile)`, which returns the texts below.
- It isn't called yet. No initializer change in 1.53.0.

**graph_mem 1.54.0 (mcp PR-2 §2.17):**
- `config/initializers/fast_mcp.rb` passes `instructions: ->(req) { GraphMem::McpInstructions.for(req ? GraphMem::McpProfile.from_request(req) : GraphMem::McpProfile.from_env) }`.
- Spec: `initialize` on each profile carries that profile's text.

**Text (AR-T)** for default + maintenance (≈ 900 chars). Readonly drops the "Before your final reply" sentence:
```
graph_mem is a shared knowledge graph of what earlier agent sessions learned about this user's projects: conventions, preferences, where things live, and verified fixes.
At the start of a task, run the `orient` prompt or call `get_context`, then load the project's Conventions entity.
Before choosing a convention (versioning, changelog, docs or test style, config, release steps) or first editing a file or component, call `search` with the file paths and component names; if a rule needs a value you don't have, look it up before acting.
Before your final reply, if the user corrected you, stated a preference, or you verified a fix or a location, persist it as one general rule (`persist` prompt, `graph_write`, or `graph_edit` with supersede to rewrite an old rule).
Prefer entity ids over names for edits and deletes. Maintenance tools are on /mcp/maintenance.
```
**Host support varies** **[UNVERIFIED per host]**, so the eval measures it (§8.4, ablation A2).

### 7. Stale-guidance fixes (commits AR-D1 + AR-D3, in 1.53.0) [Claude, following the §D step lists]
Step lists in §D:
- the shim's alias names and "execution templates";
- the three `move_to_parent` / `update_entity` hints;
- both `dream_state_status` session-start lines;
- the Cursor `.md` rule files that Cursor ignores.

### 8. Local FrontierMemory-style eval (AR-E harness; post-release validation of 1.53.0) [Claude builds, Steve runs]
See §8 below.

---

## 8. Eval harness (AR-E) [Claude]

### 8.1 Layout (`eval/agent_memory/`, dev tooling, excluded from Zeitwerk and the gem build)
```
eval/agent_memory/
  README.md                      how to run, safety, and the MEASURED time + cost per run (filled in after the smoke run)
  bin/agent_eval                 ruby CLI: prepare | smoke | dream | run | report
  lib/                           corpus builder, arm configs, stream-json parser, metrics
  tasks/<id>/
    meta.yml                     memory_type (task|user|environment), implicit, supersession,
                                 needed_rules, incidental_literals, distractor
    task.md                      the prompt the task agent receives
    repo/                        synthetic fixture repo (copied fresh per attempt)
    verify.rb                    exit 0 = PASS; deterministic, no network
    gold.md                      hand-written gold memory (the rules a perfect memory holds)
    corpus/                      past-session transcripts (Markdown), each ending with
                                 "# Verifier result" + PASS|FAIL
  results/<date>-<arm>.json      raw per-attempt results (git-ignored except the summary .md)
spec/eval/                       rspec for verifiers, corpus builder, metrics (no LLM, no network)
```

### 8.2 Arms (conditions)
| Arm | Memory available to the task agent | Dream step |
|---|---|---|
| **none** | no MCP server (`--strict-mcp-config` with an empty config), no memory files | none |
| **gold** | no MCP server; `gold.md` copied into the workspace as `MEMORY.md`, with a workspace `CLAUDE.md` line "Read MEMORY.md before starting" | none (hand-written) |
| **old** | graph_mem at the **pre-rewrite `main` commit** (`OLD_REF`, default `NEW_REF^1`, the first parent of the 1.53.0 release commit on `main`) checked out in a `git worktree`, on port 3031, DB `graph_mem_eval_old`; that commit's skill and rules installed in the workspace | the memory agent reads the shuffled corpus and writes with the **old** persist prompt + old rules |
| **new** | graph_mem at the **1.53.0 release commit** (`NEW_REF`: the tag `v1.53.0` if Steve creates one; graph_mem's remote has no git tags today, so by default Steve passes the SHA) in a second worktree, on port 3032, DB `graph_mem_eval_new`; the new skill and rules installed | the same corpus, with the **new** persist prompt + new rules |
| *opt.* gold-in-graph-old / -new | graph_mem with `gold.md` rules seeded as observations in their homes (decision 2) | none; isolates **retrieval** (triggers) from **writing** quality |

Each arm runs its own graph_mem from a separate `git worktree` (`eval/agent_memory/tmp/worktrees/<arm>`, removed afterwards) with `DATABASE_URL` pointing at its eval DB. The harness:
- creates and drops those DBs, and refuses names that don't start with `graph_mem_eval_`;
- prints the resolved SHAs;
- refuses an `OLD_REF` that already contains `docs/rules/graph_mem_reference.md`, so the old arm can't silently be the rewrite.

The old arm also lacks AR-D1–D3 (they're part of 1.53.0), so old vs new measures the whole 1.53.0 bundle. *(Oct 22-c)* UI-0 (PR #106) merged before the rewrite, so **both** arms have it and it doesn't skew the comparison. UI-0 guards `/api/v1`, the HTML UI and ActionCable; `/mcp*` and stdio are unchanged. If the harness ever calls `/api/v1` (e.g. to seed), it needs the bearer token from an allowed IP. Ablation A1 isolates the skill description.

**Embeddings:** `run` and `dream` default to `--embeddings`: both servers use the local Ollama (`OLLAMA_URL`, the same embedding model for both arms, recorded in the results). Before the task runs start, the harness waits until neither eval DB has an observation still missing its embedding (it times out after 10 minutes and records the gap). Claude finds the existing embedding column or job to check, and stops and asks if there's no reliable way to tell. `smoke` and `--no-embeddings` use the unroutable `127.0.0.1:9`, so `search` runs its non-vector path.

### 8.3 Tasks (12, synthetic, each needs a memory that only appears in earlier sessions)
| id | Memory type | What the memory says (gold) | Verifier checks |
|---|---|---|---|
| t01-release-tier-implicit | task, **implicit** | "Internal release tiers 6–8 mean a minor bump." The tier sits in `.changes/next.yaml` | `VERSION` bumped minor, not patch |
| t02-release-tier-explicit | task | same rule; the task names the tier | minor bump |
| t03-changelog-style | user | "Changelog: one line per change, newest first, no trailing period" | top `CHANGELOG.md` entry format |
| t04-config-location | environment | "Rate limits live in `config/limits/.env.local`, not `config/settings.yml`" | value changed in the right file only |
| t05-test-style-superseded | user, **supersession** | old: "use `should` syntax"; newer: "use `expect` syntax" (both in the corpus, newer later) | new spec uses `expect`, no `should` |
| t06-docs-examples | user | "Docs examples use `curl -sS` and show the response" | README snippet format |
| t07-omit-list | task | "The indexer must skip paths in `omit.txt`" | output excludes the omitted files |
| t08-check-both-sources | task, generalisation | "Some fixtures define the method only in `legacy/`, so check both `lib/` and `legacy/`" (corpus shows one incidental case with a byte size) | fix applied in both places |
| t09-release-steps | task | "Run `bin/gen-manifest` before tagging; the manifest must be committed" | manifest regenerated and staged |
| t10-naming-superseded | user, **supersession** | old: "snake_case job names"; newer: "`<Domain>::<Verb>Job`" | new class name matches |
| t11-flag-implicit | environment, **implicit** | "When `FEATURE_TIER=beta` in `.env.example`, new endpoints go behind `BetaGate`" | the endpoint is wrapped |
| t12-distractor | none applies | corpus holds unrelated rules | passes without applying any rule (catches over-application) |

- The corpus has about 60 transcripts: the relevant sessions for each task (PASS and FAIL), plus distractors.
- File names are opaque and shuffled, like FrontierMemory's corpus.
- Transcripts are written once by Claude in AR-E, reviewed by Steve, then frozen. They're never regenerated per run, so the arms see identical evidence.
- Optional extra tasks on open-source repos Steve names (e.g. his public goggles repos) come later, not in v1.

### 8.4 Runs
- **Task agent:** Claude Code headless: `claude -p "$(cat task.md)" --mcp-config <arm>.json --strict-mcp-config --output-format stream-json`, run in a fresh copy of `repo/`.
  - The model is fixed and recorded.
  - Permissions use Claude Code's documented headless setup, limited to edits inside the workspace. Claude verifies the permission and model flags with `claude --help` at implementation time; don't guess them.
- **Attempts:** at least **3 per task per arm**: 12 × 4 × 3 = 144 task runs, plus 2 dream runs. These run on Steve's machine with his Claude Code plan.
- **First pass if Max-plan rate limits bite:** `--tasks core6`, i.e. t01 (implicit), t03 (user style), t04 (environment), t05 (supersession), t08 (generalisation) and t12 (distractor): 6 × 4 × 3 = **72 runs**, plus 2 dreams. The remaining 6 tasks run in a second pass against the same dream DBs. The harness can resume a pass (it skips attempts already in `results/`).
- **Smoke run** (`agent_eval smoke`): arm `none` plus arm `old`, task t12, 1 attempt each, without embeddings. It checks the plumbing and **measures** wall time and token cost per task run and per dream run. Claude writes those figures into the README, with the extrapolation to 72 and 144 runs, before the first real pass.
- **Ablations, run after the main comparison and only if Steve wants them:**
  - A1: old vs new skill description only;
  - A2: `instructions` on vs off. It runs naturally after 1.54.0: the `new` arm on the 1.54.0 release commit (which sends them) vs the 1.53.0 one (which doesn't), same tasks and dream DB;
  - A3: generic vs imperative phrasing of the gold-in-graph observations.

### 8.5 Metrics (from `stream-json`, the eval DBs and the verifiers)
| Metric | How |
|---|---|
| full-pass rate | the verifier, per attempt; report the per-task mean of 3 and the overall rate with a Wilson 95% interval (n is small; say so) |
| recall-before-first-edit | the first graph_mem `search`/`get_entities` call comes before the first file-edit tool call |
| skill-load rate | a Skill-load event in the stream, if the host emits one; otherwise "n/a" |
| relevant-rule-hit | a tool result contains the task's `needed_rules` marker text |
| adherence | the verifier result on attempts where the rule was hit (separates "found" from "followed") |
| overfit rate | share of observations written in the dream step that contain any `incidental_literals` |
| duplicate/stale rate | active observations on the same point per home entity after the dream; superseded count |
| tokens and cost | from `stream-json` usage, **including the dream step** |

### 8.6 Order and the validate-and-iterate rule (Steve, Oct 22-b: no gate)
1. **1.53.0 ships first** (`claude/ar-rules-rewrite`); it doesn't wait for the eval.
2. **Build AR-E** on `claude/ar-e-eval` off `main` after 1.53.0. It's dev tooling with an `[Unreleased]` line and rides along in the next release.
3. **Smoke run** (§8.4), and the README gets the measured time and cost.
4. **Real comparison:** `none`, `gold`, `old` (`OLD_REF`) and `new` (`NEW_REF`), with embeddings, core6 first if needed, then all 12. Commit `results/<date>-comparison.md`.
5. **Validate and iterate:**
   - **New holds up** if all three of these hold: new full-pass ≥ old; new recall-before-first-edit ≥ old; and no task where old passes 3/3 and new passes ≤ 1/3. Record it in the README; nothing more to do.
   - **New is worse** on any of the three: Claude opens a **follow-up fix PR**, `claude/ar-f<n>-<slug>`, a 1.53.x patch (or the next patch if 1.54.0 is already out). It's targeted at the failing tasks and changes text only (descriptions, prompts, rules, skill, instructions). It re-runs `new` on that branch for the affected tasks, plus t12, and attaches the before/after table. No revert and no block: Steve merges it like any other patch.
   - Repeat at most twice per finding. If a third round is still worse, the PR says so and lists what was tried; Steve decides.
6. **After 1.54.0** (instructions delivered): run A2 (§8.4) once. Re-run the comparison after any later AR-F that changes the always-on text.

### 8.7 AR-E files, acceptance and specs
- **Files:** everything under `eval/agent_memory/`; `spec/eval/{verifiers,corpus_builder,metrics}_spec.rb`; `config/application.rb` (exclude `eval/` from autoload and eager load); `.gitignore` (raw results); `docs/agent_eval.md` (short; links the README).
- **Specs:**
  - each `verify.rb` fails on the untouched fixture and passes on a checked-in reference solution (`tasks/<id>/solution.patch`);
  - the corpus builder is deterministic for a seed;
  - the stream-json parser works on recorded sample streams (synthetic, checked in);
  - the DB-name guard refuses names that don't start with `graph_mem_eval_`.
- **Acceptance:** `agent_eval prepare` + `agent_eval smoke` works end to end on Steve's machine. The README records the **measured** time and cost per task run and per dream run from that smoke run, plus the 72- and 144-run extrapolations. `run` defaults to `--embeddings` and refuses to start if Ollama isn't reachable (it suggests `--no-embeddings`). Nothing in `spec/` calls an LLM or the network.
- **Specs (additions):** `OLD_REF` guard (refuses a ref with `graph_mem_reference.md`); the `core6` task set resolves to the six ids above; resume skips finished attempts.

---

## D. Step lists: AR-D1–D3 (Claude commits on `claude/ar-rules-rewrite`) and AR-D4 (Devin-simple)

**Rules for AR-D1–D3** (Claude, one commit each, in order, on the rewrite branch):
- commit messages `AR-D1: stale agent hints`, `AR-D2: expose write fields in schemas`, `AR-D3: Cursor .mdc rules + sync spec`;
- touch only the listed files;
- run the listed spec after each commit;
- CHANGELOG lines go under `## [Unreleased]` (the release commit renames it);
- copy the replacement text exactly;
- stop and ask if a line doesn't match.

**Rules for AR-D4** (Devin):
- branch `devin/ar-d4-docs` off `main` after 1.53.0;
- touch only the listed files;
- run the full suite **alone** with `RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9` and the test DB truncated before and after;
- CHANGELOG `## [Unreleased]`;
- stop and ask if a line doesn't match.

**AR-D1 [Claude, commit 1]. Stale guidance (1.53.0)**

1. `.cursor/skills/graph-mem-mcp-toolset/SKILL.md`:
   - l.21-22: replace "the `<tool>` names and `arguments` payloads are exactly the ones used in the canonical skill's execution templates." with "the `<tool>` names and `arguments` come from the canonical skill's Quick Start and the schemas `GetMcpTools` returns."
   - l.26: replace "always `search_entities` before `create_entity`" with "always `search` before `graph_write`".
2. `app/services/graph_delete_service.rb`:
   - l.40 next_move → "A same-named entity already exists in the destination scope; rename one with `graph_edit` update_entity, then retry."
   - l.138 next_move → "Re-parent or delete this project's members first (for each member: `graph_delete` delete_relation on its part_of edge, then `graph_write` create_relation part_of to the new parent), then retry."
3. `app/services/relation_semantics.rb:53`: message → "Entity already has a #{type} parent; remove that relation first (MCP: graph_delete delete_relation), then create the new one".
   - Then run `rg -n "move_to_parent instead" spec` and update the matching expectations only.
4. `docs/dream_state.md`:
   - l.321 → "1. On the maintenance profile (`/mcp/maintenance`), call `dream_state_status` to see whether compaction is `running` or `paused`. Default-profile agents don't need to: mutating tools pause compaction automatically."
   - l.244: prefix the sentence with "On the maintenance profile, ".
   - `docs/rules/graph_mem_mcp_rules.md:97` (and its two copies, identically): prefix with "On `/mcp/maintenance`, ".
5. New spec `spec/services/next_move_vocabulary_spec.rb`:
   - collect every string literal following `next_move:` in `app/services/graph_*_service.rb` and `app/services/relation_semantics.rb`;
   - for each backticked or bare `graph_(write|edit|delete) <op>` mention, assert `<op>` is in that service's `TYPES`;
   - assert `move_to_parent` doesn't appear.
6. CHANGELOG › Fixed: "Agent-facing hints no longer point at nonexistent operations (`graph_edit move_to_parent`, `graph_write update_entity`) or at the maintenance-only `dream_state_status` for default-profile sessions; the Cursor skill shim names canonical tools."

**AR-D2 [Claude, commit 2]. Expose write fields in schemas (1.53.0)**

1. `app/tools/graph_write_tool.rb`, in `operation_properties`, after `relation_type`, add:
   ```ruby
   source: { type: "string", description: "Who/what this came from, e.g. \"claude-code/opus: release task\"." },
   confidence: { type: "number", minimum: 0, maximum: 1 },
   valid_from: { type: "string", format: "date-time" },
   valid_until: { type: "string", format: "date-time", description: "Set for time-bound facts; must be ≥ valid_from." },
   tags: { type: "array", items: { type: "string" } },
   perspective: { type: "string", enum: MemoryObservation::PERSPECTIVES },
   weight: { type: "number", description: "create_relation only." },
   properties: { type: "object", description: "create_relation only." }
   ```
   - The `observations` compatibility array has **no** item schema today (only `entities` and `relations` get one, l.57-73). Add `schema[:properties][:observations][:items] = { type: "object", additionalProperties: true, properties: { entity_id: operation_properties[:entity_id], text_content: operation_properties[:text_content] }.merge(operation_properties.slice(:source, :confidence, :valid_from, :valid_until, :tags, :perspective)) }`.
2. `app/tools/graph_edit_tool.rb`: add `def self.input_schema_to_json` mirroring graph_write's pattern:
   - `schema = super.deep_dup`;
   - `schema[:properties][:operations][:items] = { type: "object", required: ["type"], additionalProperties: true, properties: { … } }`;
   - properties: `type` (examples `GraphEditService::TYPES`), `entity_id`, `observation_id` (both `oneOf` integer/string), `name`, `entity_type`, `aliases` (array of string), `description`, `text_content`, `confidence`, `source`, `valid_from`, `valid_until`, `tags`, `perspective` (same definitions as step 1), `supersede` (boolean, "true keeps the old text as history"), `reason` (string).
   - Check the field list against `graph_edit_service.rb:74` and `:111` before writing; if they differ, stop and ask.
3. Specs:
   - `spec/tools/graph_write_tool_spec.rb`: the schema includes each new key with the type above; a `create_observation` with `source`, `confidence: 0.8`, `valid_until`, `tags: ["x"]`, `perspective: "experience"` persists all five (read back from `MemoryObservation`); `confidence: 1.5` → validation error.
   - `spec/tools/graph_edit_tool_spec.rb`: the schema has `items.properties.supersede`; `update_observation` with `supersede: true` and `valid_until` round-trips.
   - Re-run `spec/tools/tool_description_length_spec.rb` if M-D2 has merged (otherwise check every description is ≤ 2,048 chars by hand and say so in the PR).
4. CHANGELOG › Added: "`graph_write` and `graph_edit` schemas now advertise the provenance/staleness fields the services already accepted (`source`, `confidence`, `valid_from`, `valid_until`, `tags`, `perspective`; relation `weight`/`properties`)."

**AR-D3 [Claude, commit 3]. Cursor `.mdc` rules + copy-sync spec (1.53.0)**

1. `git mv .cursor/rules/graph_mem_mcp_rules.md .cursor/rules/graph_mem_mcp_rules.mdc` and `git mv .cursor/rules/general_coding_rules.md .cursor/rules/general_coding_rules.mdc`. Content unchanged. `general_coding_rules` needs frontmatter: if it has none, add `---\ndescription: General coding rules\nglobs:\nalwaysApply: true\n---` and tell Steve in the PR.
2. `docs/rules/README.md:25`: keep `.cursor/rules/graph_mem.mdc` and add "(the extension must be `.mdc`; Cursor ignores `.md` files in `.cursor/rules`)".
3. New `spec/docs/agent_text_sync_spec.rb`:
   - `docs/rules/graph_mem_mcp_rules.md`, `.cursor/rules/graph_mem_mcp_rules.mdc` and `.devin/rules/graph_mem_mcp_rules.md` are byte-identical;
   - the description line of `skills/…/SKILL.md` equals the one in `.cursor/skills/…/SKILL.md`;
   - no file under `.cursor/rules/` ends in `.md`.
4. CHANGELOG › Fixed: "Cursor now loads the repo's always-on rules (`.mdc`)."

**[Devin-simple] AR-D4. Docs follow-ups (after 1.53.0)**

1. README "Rules & Skills" (l.73-88): add `docs/rules/graph_mem_reference.md` ("maintenance and parameter reference, linked from the always-on rules") and one line on the memory homes (decision 2).
2. `docs/rules/README.md`: install table gains "copy `graph_mem_reference.md` next to the rules file".
3. `AGENTS.md` / `CLAUDE.md` "Using GraphMem as an MCP toolset": point to the new files; no other edits.
4. `rg -n "search_entities|create_entity|move_to_parent|execution templates" README.md docs skills .cursor .devin`: list remaining hits in the PR; don't edit alias docs in `docs/mcp_tools.md` (aliases are documented there on purpose).

---

## AR-T [Claude]: agent text rewrite (commit 4) and the release commit → graph_mem 1.53.0
- **Branch:** `claude/ar-rules-rewrite`, commit 4 (`AR-T: situational agent text`), after AR-D1–D3. Then commit 5, `Release 1.53.0`: version, CHANGELOG rename (it folds in #106's `[Unreleased]` › Security entries for UI-0 unchanged), and the CHANGELOG › Changed summary. **Base:** current `main` after PR #106 (1.52.1 + UI-0 under `[Unreleased]`, plus whatever else has merged), not the CircleCI-fix branches.
- **Files:**
  - items 1, 2, 4, 5, 6 above;
  - `lib/graph_mem/mcp_instructions.rb` (per-profile texts; not wired, decision 3);
  - `app/lib/tool_success_response.rb`;
  - `docs/rules/graph_mem_reference.md` (new) + copies;
  - `skills/…/SKILL.md` + shim;
  - CHANGELOG `## [Unreleased]` › Changed (renamed to `## [1.53.0]` in commit 5);
  - `lib/graph_mem/version.rb`.
- **Specs:**
  - `spec/prompts/workflow_prompts_spec.rb`: keep the existing keywords and add orient ⊃ "Conventions", "User Preferences"; recall ⊃ "file paths", "find that value"; persist ⊃ "supersede: true", "valid_until", "source".
  - New `spec/tools/agent_text_spec.rb`:
    - `search` starts with "Recall what earlier sessions learned";
    - `graph_write` starts with "Persist a durable lesson";
    - `graph_edit` starts with "Rewrite what the graph already knows";
    - every advertised description, prompt text, `next_move` hint, `instructions` text, the always-on rules file and the skill name only tools advertised on the profile they're shown on: parse `` `name` `` tokens that match a registered tool name and check them against `McpProfile.select_tools`; maintenance tools may appear only in the reference doc or next to "/mcp/maintenance";
    - no hidden alias name appears in any of them.
  - `spec/lib/graph_mem/mcp_instructions_spec.rb`: default and maintenance texts ≤ 2,048 chars and contain "orient", "search", "persist"; readonly has no "persist"; every tool named is on that profile. (The `initialize` delivery specs come with the wiring in mcp PR-2 §2.17.)
  - `agent_text_sync_spec.rb` additions: rules file ≤ 45 lines; skill description ≤ 1,024 chars and starts with "Use at the start of any coding task"; the reference doc exists and is linked.
- **Acceptance:** specs green; full suite green when run alone; text exactly as in this plan, or the PR lists each deviation with a reason. The PR description lists the five commits and says "eval: post-release, agent-rules §8.6". No eval results are needed to merge.
- **Risks:**
  - Hosts ignore `instructions` or skills, which the eval shows and A2 measures.
  - More recall calls cost tokens, which the eval's cost metric shows.
  - Over-application on the distractor task (t12) is the check against rules that fire too eagerly.

## 9. Later (not scheduled)
- **Lesson-distillation pass** (brief §5.4): a maintenance-profile job or prompt that reads recent observations per project and proposes generalised rules. It flags overfit literals and dated-correction stacks and queues them as `maintenance_review` rows (UI plan §2.5 review queue; never silent writes). Schedule it only if the post-release eval shows high overfit or duplicate rates.
- **`conflicts` hint on default reads** (brief §5.3): `get_entities` returns `conflicts: [...]` when `detect_contradictions` has an open row on the entity.
- **FrontierMemory itself (Option A): not pursued.** Steve decided on Oct 22-b: self-measured only, no contact with Letta, no HF access request.

## E. Open questions for Steve

None left in this plan. Steve's Oct 22-b answers closed all five:
1. **Timing** → ASAP, one branch, graph_mem 1.53.0 (decision 4, §C).
2. **Memory homes** → approved (decision 2).
3. **Embeddings** → on for the real comparison; unroutable for smoke/CI-adjacent runs (decision 7, §8.2).
4. **FrontierMemory proper / Letta** → no; self-measured only (decision 8).
5. **Budget** → a 6-task / 72-run first pass is allowed; the README records measured time and cost per run (§8.4, §8.7).

There are no open items left in the whole train. The future of fast-mcp was decided on Oct 22-c (mcp plan D-24: it freezes at 1.8.x with bug fixes only, and is archived after both consumer apps have migrated).
