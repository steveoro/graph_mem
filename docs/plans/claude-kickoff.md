# Kickoff prompt for Claude Code (paste as the first message, from the graph_mem clone)

You are implementing three approved plans for Steve in his local clones:
- graph_mem: this repo (`steveoro/graph_mem`). fast-mcp: `../fast-mcp` (`steveoro/fast-mcp`). If either path is wrong, ask me; don't search the disk.
- **The plans live in `docs/plans/` on `main` (master)**: `mcp-update-plan.md`, `ui-dashboard-plan.md` and `agent-rules-plan.md`. The Oct 22-c versions are committed there. Older copies of the first two arrived with PR #106; if a plan has no "Oct 22-c update" line near the top, or `agent-rules-plan.md` is missing, stop and ask me. Don't reconstruct a plan.
- Handoff step lists for Devin go to `docs/plans/handoff/devin-<id>-<slug>.md`.

## 1. Where we are (Oct 22-c)
- **Step 0 (CI fixes):** graph_mem's CircleCI is fixed by **PR #106**, which is green: ruby orb 4.0, the `-browsers` image so the system specs run, and the `structure.sql` DEFAULTs. Nothing else is left for you in graph_mem. Devin's `devin/m-d1-query-cap` and `devin/m-d2-description-length` are still red; they're Devin's, so leave them alone. Your fast-mcp branch `claude/pr-1-hardening-1.8.0` (`9f2c72a`) is unchanged, and **no CI has ever run on it**. You'll get it green locally at step 2.
- **UI-0 (security baseline) is DONE** in PR #106 (`claude/ui-0-security-baseline`), merged Oct 22 (`f9febd6`, plus my follow-ups `39db049` and `bbda8b9`, which already fix the refused-bearer CSRF clause and the duplicate timeout constants). It added `## [Unreleased]` › Security and **didn't bump the version**. Its leftover low items are now PR-2 tasks (mcp §2.20–2.21). Don't touch UI-0 code outside PR-2.

## 2. Read first (no code yet)
1. The three plans: the briefs (mcp §A, UI §0.1, agent-rules §A), the decisions (mcp §B incl. D-20…D-25, UI §0.2, agent-rules §B), and the shared release train (mcp §C = UI §0.3 = agent-rules §C).
2. `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*` and `docs/architecture.md` here; `CLAUDE.md` and `AGENTS.md` in fast-mcp.
3. Reply with: the order as you understand it, the five commits of step 1 with their files and specs, and any place where a plan doesn't match the code (with file:line). Then wait for my "go".

## 3. Next: step 1, the rules and skills rewrite → graph_mem 1.53.0
- Branch `claude/ar-rules-rewrite` off `main` **after #106 has merged** (not off any CI-fix branch; don't touch those). Follow `agent-rules-plan.md`, with these separate commits in this order:
  1. **AR-D1:** stale tool-name hints, incl. `dream_state.md` l.244/l.321 and `relation_semantics.rb:53`.
  2. **AR-D2:** expose `source`, `confidence`, `valid_from`/`valid_until`, `tags` and `perspective` in the write schemas; relation `weight`/`confidence`/`properties`; an item schema for `graph_edit` observations.
  3. **AR-D3:** skill discovery (`.agents/` and `.claude/` skill links, Cursor shim retired, `project-scan` moved to `skills/`) and one rule file for every agent: a 10-line graph_mem section in root `AGENTS.md`, with the root `CLAUDE.md` merged into it and reduced to `@AGENTS.md`, with the per-tool rule files in `.cursor/rules/` and `.devin/rules/` removed (Oct 23-c); see agent-rules §D.
  4. **AR-T:** the skill description, tool-description openers, the recall/persist/orient prompts, the skill's workflow sections and its `references/tools.md` and `references/maintenance.md` (no `docs/rules/graph_mem_reference.md`, Oct 23-c), and `GraphMem::McpInstructions` (texts and specs only). Start from the plan's exact text; list every deviation, with its reason, in the report.
  5. **Release 1.53.0:** bump `lib/graph_mem/version.rb` and rename `## [Unreleased]` → `## [1.53.0] - <date>`. Keep #106's UI-0 Security entries verbatim under it, plus any merged M-D lines. 1.53.0 releases UI-0 too.
- AR-D1–D3 follow the exact step lists in agent-rules §D: copy them, don't rephrase.
- **Skip the server `instructions` wiring.** It belongs to PR-2 (§2.17, after fast-mcp 1.8.0).
- **Never start the AR-E eval.** You may build the harness later, as its own step, but I run every eval myself.
- When done: stop and report (§7). **No push and no PR until I say so.**

## 4. Then (don't reorder; ask if you think you should)
2. **PR-1 → fast-mcp 1.8.0**, on the existing `claude/pr-1-hardening-1.8.0`, as new commits:
   - first get it green locally (suite + rubocop; its GitHub Actions only run on a PR);
   - then mcp §1.13–1.14. D-17 is decided: omit `id` when it can't be read, like the SDK.
   - Never recreate or force-push it. I tag `v1.8.0`. After it, fast-mcp gets 1.8.x fixes only (D-24).
3. **PR-0 → PR-2 = graph_mem 1.54.0**, stacked:
   - PR-0 (`claude/pr-0-scan-home-mount`) writes `[Unreleased]`.
   - PR-2 (`claude/pr-2-mcp-hardening-1.54`) contains: the fast-mcp 1.8.0 bump, the two high bugs (§2.3a array body, §2.13 stdout), `McpInstructions` wiring (§2.17), the #106 leftovers (§2.20) and spec hygiene (§2.21). It does the bump to 1.54.0.
4. AR-E harness (agent-rules §8) any time after 1.53.0 merges, while other PRs wait for review. AR-F fixes (1.53.x) only if I report the eval shows new worse than old.
5. PR-3 → 1.54.1; then the MG track (mcp §MG): MG-0 → MG-6 = 1.55.0 … 1.58.0. MG-0's design doc and migration guide need my approval before MG-1.
6. UI-1 … UI-7 → 1.59.0 … 1.66.0.

## 5. One PR at a time
- One branch per item, using the name the plan gives. Specs first where it's sensible, then code, then docs and the CHANGELOG exactly as the plan's "Versions" row says.
- Only [Claude] steps are yours. For each [Devin-simple] item in the current stage, write a handoff file at `docs/plans/handoff/devin-<id>-<slug>.md`. It covers: branch, exact files, numbered steps, the spec, the commands, the done criteria, and "stop and ask if a step doesn't match the code". Don't implement those items unless I say so.
- Stay inside the item's file list. If you must go outside it, say why first.

## 6. Running specs safely (every time)
```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem   # fast-mcp: ruby-3.4.1@fast_mcp
export RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9                # unroutable: no real Ollama, ever
```
- Nothing may listen on 11434, and no spec may reach a real embedding or LLM service; stub at the service boundary. Some specs still call `*.test:11434` hosts unstubbed. They hang if DNS resolves everything; PR-2 §2.21 fixes that.
- Test DB only. **Truncate it before and after** the suite (snippet in UI plan §0.1) and leave it with 0 rows. Never use the dev or production DB.
- Run the full suite on its own (no parallel suites on the test DB), plus `bundle exec rubocop` and `bin/brakeman`.
- **No `zz_*` scratch specs** in the run, and none left behind. Remove temp trees. Kill only processes you started.
- Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Dir.mktmpdir`). Never read, scan, copy or mention private client code, not even read-only.
- After any migration, run `git diff db/structure.sql`: no `vector(768)` column, VECTOR KEY, embedding trigger or zero-vector DEFAULT may disappear. Don't bypass `StructureDumpGuard`.
- For fast-mcp PRs, also run graph_mem's MCP specs against your branch with an uncommitted `bundle config local.fast-mcp ../fast-mcp`, then unset it.

## 7. Git rules and PR boundaries
- Commit locally as you go. **Don't push, open a PR, merge, tag, push tags or run `rake release` without my explicit OK** in this chat. No force-push once a PR has review comments.
- When I say "open it": push and run `gh pr create` from my `gh` login. Title = plan item + version. Body = summary, specs with results, manual checks, the mcp plan's advisory checklist, and any "pending" items. Then fix the review bot's (graphy-review[bot]) should-fix findings with new commits on the same branch.
- At the end of each item, stop and report:
  1. the files changed, and any deviation from the plan with its reason;
  2. the suite count, rubocop, brakeman, and "test DB rows after: 0";
  3. the Devin handoff files written;
  4. what I should check by hand;
  5. the next item.

  Then wait. Also stop mid-item if a plan step contradicts the code, a decision is missing, or a spec can't be made safe.
