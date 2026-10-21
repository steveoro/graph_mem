# Kickoff prompt for Claude Code (paste as the first message, from the graph_mem clone)

You are implementing two approved plans for Steve (me) in his local clones:
- graph_mem: this repo (`steveoro/graph_mem`). fast-mcp: `../fast-mcp` (`steveoro/fast-mcp`). If either path is wrong, ask me; don't search the disk.
- The plans are in this repo: `docs/plans/mcp-update-plan.md` and `docs/plans/ui-dashboard-plan.md`. If they aren't there, stop and ask me; don't reconstruct them.

## 1. Read first (no code yet)
1. Both plans in full: the implementer briefs (mcp §A, UI §0.1), the decisions (mcp §B, UI §0.2) and the shared release train (mcp §C = UI §0.3).
2. `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, `docs/architecture.md` here; `CLAUDE.md` and `AGENTS.md` in fast-mcp.
3. Then reply with: the release order as you understand it, the first PR you'll do, its files and its specs, and any place where a plan doesn't match the code (with file:line). Wait for my "go".

## 2. Release order (don't reorder; ask if you think you should)
1. PR-1 → fast-mcp 1.8.0 (I tag `v1.8.0`).
2. UI-0 → PR-0 → PR-2: three stacked graph_mem PRs = 1.53.0. PR-0 never merges before UI-0. PR-2 does the bump.
3. PR-3 → graph_mem 1.53.1 (step 5 is my manual Claude Code check; mark it "pending Steve's run" in the PR).
4. PR-4a → fast-mcp 1.9.0, then PR-4b → graph_mem 1.54.0.
5. UI-1 … UI-7 → graph_mem 1.55.0 … 1.62.0, in the train's order.

## 3. One PR at a time
- One branch per item off current `main` (or off the previous stacked branch for the 1.53.0 stack): `claude/pr-1-hardening-1` (fast-mcp), `claude/ui-0-security-baseline`, `claude/pr-0-scan-home-mount`, `claude/pr-2-mcp-hardening-1`, … (use the exact name each plan item gives).
- Write the specs first where it's sensible (security checks, ScanRootPolicy, role matrix, undo, policies); then the code; then docs and CHANGELOG exactly as the plan's "Versions" row says.
- Only [Claude] steps are yours. For each [Devin-simple] item that belongs to the current PR's stage, write it as a separate handoff file `docs/plans/handoff/devin-<id>-<slug>.md`: branch name, exact files, numbered steps, the spec to add, the commands to run, the done criteria, and "stop and ask if a step doesn't match the code". Don't implement those items yourself unless I say so.
- Stay inside the item's file list. If you need to go outside it, say why first.

## 4. Running specs safely (every time)
```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem   # fast-mcp: ruby-3.4.1@fast_mcp
export RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9                # unroutable: no real Ollama, ever
```
- Never talk to a real embedding/LLM service; nothing may listen on 11434 during specs. Stub at the service boundary.
- Test DB only. Truncate it before and after the suite (snippet in UI plan §0.1) and leave it with 0 rows. Never point specs or scripts at the development or production DB.
- Run the full suite on its own (no parallel suites on the same test DB), plus `bundle exec rubocop` and `bin/brakeman` (graph_mem).
- Synthetic fixtures only (`SynthWidget`, `Alpha Service`, `Dir.mktmpdir` trees). Never read, scan, copy or mention `admin_hub` or `coach_in_a_box` (private BTS code), not even read-only.
- Kill only processes you started. Remove scratch specs (`zz_*`) and temp trees before you finish.
- After any migration: `git diff db/structure.sql`; no `vector(768)` column, VECTOR KEY or embedding trigger may disappear. If `StructureDumpGuard` complains, fix the DB; don't bypass it.
- fast-mcp PRs: also run graph_mem's MCP specs against your branch with an uncommitted `bundle config local.fast-mcp ../fast-mcp`, and unset it afterwards.

## 5. Git rules
- Commit locally as you go. **Don't push, open a PR, merge, tag, push tags or run `rake release` without my explicit OK** in this chat.
- No force-push once a PR has review comments.
- When I say "open it": push the branch and run `gh pr create` from my own `gh` login (so the PR is mine and graphy-review[bot] reviews it). Title = plan item + version; body = summary, specs run with results, manual checks, the plan's advisory checklist (mcp plan), and "pending" items.
- Then fix graphy-review's should-fix findings on the same branch (new commits) and tell me when it's clean. I merge and tag.

## 6. Stop and ask at every PR boundary
At the end of each item, stop and report:
1. What changed (files), and anything you did differently from the plan, with the reason.
2. Spec results: the full-suite count, rubocop, brakeman, and "test DB rows after: 0".
3. The handoff files written for Devin, if any.
4. What I should check by hand.
5. The next item you'd start.
Then wait. Also stop mid-item if a plan step contradicts the code, a decision is missing, or a spec can't be made safe.
