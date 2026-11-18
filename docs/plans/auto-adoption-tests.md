# graph_mem auto-adoption: decision tests

**Status:** active, companion to [`auto-adoption-plan.md`](auto-adoption-plan.md) (section 8 there points here).
**Why:** each open question in the plan needs data before a choice. Every test below has fixed tasks, arms that
are easy to flip, one primary metric and a decision rule written down *before* the runs.

**Privacy:** open-source repos and synthetic prompts only. Logs stay on the workstation, outside every repo;
only the summary counts get shared (in an issue, a PR or chat). No transcripts, no graph contents.

---

## 1. Setup (once, about 10 minutes)

All paths are relative to `<projects-dir>`, the parent folder Claude is normally started from.

1. **Scratch clones**, so runs never touch a working checkout:
   ```bash
   cd <projects-dir>
   git clone https://github.com/steveoro/goggles_admin2.git goggles_admin2-eval   # Rails app
   git clone https://github.com/steveoro/fast-mcp.git fast-mcp-eval               # Ruby gem, not Rails
   mkdir -p ~/adoption-eval/logs                                                   # outside every repo
   ```
   Between runs: `git -C <clone> reset -q --hard && git -C <clone> clean -fdq`.
2. **Eval MCP config** `~/adoption-eval/mcp.json`. Same server, its own `X-MCP-Client`, so the eval never moves
   the project context of your normal sessions:
   ```json
   { "mcpServers": { "graph_mem": { "type": "http", "url": "http://localhost:3030/mcp",
       "headers": { "X-MCP-Client": "adoption-eval" } } } }
   ```
   `mcp-alwaysload.json`: the same with `"alwaysLoad": true` in the `graph_mem` entry.
   `mcp-readonly.json`: the same with the URL ending in `/mcp/readonly`.
3. **Record the baseline state** (once, as counts or yes/no): which of `~/.claude/CLAUDE.md`, `~/.claude/rules/*`,
   `<projects-dir>/CLAUDE.md`, `~/.claude/skills/graph-mem-mcp-toolset`, `<projects-dir>/.claude/skills/graph-mem-mcp-toolset`
   exist, and whether any of them mentions graph_mem. Arms add or swap one thing on top of this.
4. **Fix the model** for every run (`--model <alias>`, the one you normally use) and note the Claude Code version
   (`claude --version`). Change neither mid-test.

### Tasks (fixed prompts; never mention graph_mem, memory or conventions)

| Id | Repo | Prompt |
|---|---|---|
| T1 | goggles_admin2-eval | "In goggles_admin2-eval (a clone of goggles_admin2), add a CHANGELOG entry and bump the version for a small fix to the Data-Fix grid toolbar." |
| T2 | goggles_admin2-eval | "In goggles_admin2-eval (a clone of goggles_admin2), add a spec for the error handling in app/strategies/api_proxy.rb." |
| T3 | fast-mcp-eval | "In fast-mcp-eval (a clone of fast-mcp), prepare a patch release: bump the version and add the CHANGELOG entry for a fix in initialize handling." |
| T4 | goggles_admin2-eval | "In goggles_admin2-eval (a clone of goggles_admin2), I prefer commit subjects under 50 characters; keep that in mind. Then fix any typo you find in README.md." (Q2 only) |

Each task has a convention that graph_mem may already hold (versioning, changelog, spec style), so recall pays off.

### Claude Code run command (headless)

Flags checked against the current [CLI reference](https://code.claude.com/docs/en/cli-reference) and
[headless docs](https://code.claude.com/docs/en/headless): `-p`, `--output-format stream-json` (needs `--verbose`),
`--mcp-config` + `--strict-mcp-config`, `--settings`, `--allowedTools`, `--permission-mode`, `--max-turns`,
`--no-session-persistence`, `--model`. `--allowedTools` takes one quoted rule per argument.

```bash
# ARM, TASK, N, PROMPT, CLONE, MCP (mcp.json by default), SETTINGS (hooks file, see the arms) set by you
cd <projects-dir>
for i in $(seq 1 "$N"); do
  git -C "$CLONE" reset -q --hard && git -C "$CLONE" clean -fdq
  claude -p "$PROMPT" --model "$MODEL" --output-format stream-json --verbose \
    --mcp-config ~/adoption-eval/"${MCP:-mcp.json}" --strict-mcp-config \
    --settings ~/adoption-eval/"${SETTINGS:-settings-nohook.json}" \
    --permission-mode acceptEdits \
    --allowedTools "mcp__graph_mem__get_context" "mcp__graph_mem__set_context" "mcp__graph_mem__search" \
                   "mcp__graph_mem__get_entities" "mcp__graph_mem__traverse_graph" \
    --max-turns 25 --no-session-persistence \
    > ~/adoption-eval/logs/"$ARM-$TASK-$i".jsonl 2>/dev/null
done
```
- Edits land in the scratch clone only (`acceptEdits`), and get reset before the next run.
- graph_mem **write** tools aren't allowed. A `-p` run can't ask, so a `graph_write` / `graph_edit` attempt is
  denied and recorded in the stream (`permission_denied`, and `permission_denials` in the result). We count the
  attempt, and the graph stays untouched. Bash isn't allowed either, the same way in every arm.
- `settings-nohook.json` is `{"hooks": {}}`; `settings-hook.json` adds the SessionStart hook (arm H). Every arm passes
  one of the two, so arms differ only in the hook. *(Whether `--settings` "hooks" replaces or merges your user
  hooks isn't documented; the logs show which hooks ran, and the script reports whether the graph_mem one fired.)*

### Metrics (per session, from the stream-json log)

| Metric | Definition |
|---|---|
| **adopted** (primary) | a graph_mem tool call (`mcp__graph_mem__*`, allowed or denied) before the first `Edit` / `Write` / `MultiEdit` / `NotebookEdit`; if there's no edit, any graph_mem call |
| `first_gm_turn` | 1-based index of the assistant message holding the first graph_mem call (blank if none) |
| `ctx_before_edit` | `get_context` called before the first edit |
| `gm_calls` | graph_mem tool calls in the session |
| `skill_used` | a `Skill` call naming `graph-mem-mcp-toolset` |
| `toolsearch_gm` | a `ToolSearch` call whose query mentions graph_mem or one of its tool names |
| `persist_attempts` | denied `graph_write` / `graph_edit` / `graph_delete` calls |
| `hook_fired` | a SessionStart hook event for the graph_mem hook script |
| `turns`, `tokens`, `cost` | from the final `result` event: `num_turns`, `usage` (input, output and cache tokens), `total_cost_usd`; n/a when missing |

Per arm, report: sessions, adoption rate, ctx-before-edit rate, median `first_gm_turn`, mean `gm_calls`,
skill-use rate, persist attempts, hook-fired count, median tokens and median cost.

**Before `script/adoption_eval` exists (it lands in 1.90.0):** keep the logs; the script re-reads them later. A quick
check meanwhile, per log:
```bash
jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' run.jsonl | grep -n -m1 mcp__graph_mem__
```

### Variance and the bar

Runs vary a lot: the same prompt can adopt in one run and skip in the next. So:
- **N = 5 runs per arm per task.** Pooled over T1–T3 that's 15 sessions per arm.
- A difference counts as **real** when the pooled adoption rates differ by **≥ 20 points** *and* point the same way on
  **at least 2 of the 3 tasks**.
- **Screening** on T1 alone (N = 5): only a gap of **≥ 40 points** counts; anything less goes to the full T1–T3 round.
- Below the bar it's a **tie**, and the tie-break is always the simpler or cheaper option (fewer files to install, no
  surface change, fewer tokens).
- This is a rough bar, not a significance test: with 15 per arm, a 20-point gap is about one standard error. When a
  decision is costly (a surface change), go to N = 10 per task (30 pooled), where 20 points is about 1.5 standard errors.

---

## 2. Arms

Each arm is the baseline plus **one** toggle, so it can be flipped in seconds. "Code" says what server is needed.

| Arm | Toggle | How to flip | Code |
|---|---|---|---|
| **B0** baseline | nothing | | 1.89.0 (now) |
| **R** user rule | `~/.claude/rules/graph-mem.md` with the plan's §3.2 text | copy the file in / remove it | 1.89.0 (now) |
| **S** skill trigger | the plan's §3.3 description in the user-visible skill copy | keep `SKILL.md.orig`, swap the file | 1.89.0 (now) |
| **H** hook | SessionStart hook, the plan's §3.4 script in `~/.claude/hooks/` | `SETTINGS=settings-hook.json` | 1.89.0 (now) |
| **A** alwaysLoad | server entry `"alwaysLoad": true` | `MCP=mcp-alwaysload.json` | 1.89.0 (now) |
| **RSH** text levers, no instructions | R + S + H | the three above together | 1.89.0 (now) |
| **I** new instructions | the server runs the 1.90.0 instructions | run the 1.90.0 server | **1.90.0** |
| **ALL** | I + R + S + H | | **1.90.0** |
| **ALL−x** | ALL minus one of I, R, S, H (four arms) | | **1.90.0** |
| **ALL+A** | ALL + alwaysLoad | | **1.90.0** |

After the server moves to 1.90.0, **B0 is re-run once** (it then carries the new instructions, so it equals arm I);
1.89.0 B0 results stay the "old instructions" baseline.

---

## 3. The decision tests

### Q-L. Which wording levers actually move adoption (instructions, user rule, skill trigger, hook)?
- **Arms:** B0, R, S, H, RSH now; I, ALL and the four ALL−x after 1.90.0.
- **Metric:** adoption rate (primary); ctx-before-edit rate and median `first_gm_turn` as tie-breakers.
- **Rule:** a lever stays **on by default** (D3) when it adds **≥ 20 points over B0 alone**, *or* dropping it from ALL
  (ALL−x) costs **≥ 15 points**. A lever that clears neither bar is kept only if it's free at runtime (instructions,
  skill text) and dropped from the default install output if it costs a file or a hook (R, H). If ALL is **≥ 85%**,
  stop adding levers.

### Q1. `anthropic/alwaysLoad` on `search` + `get_context` (a tools/list surface change)
- **Arms:** B0 vs A now; the best text arm vs ALL+A after 1.90.0. Server-wide `alwaysLoad` (all 12 tools upfront) is the
  upper bound of what per-tool `_meta` on two tools could do, at a higher token cost.
- **Metric:** adoption rate; median tokens per session.
- **Rule:** propose the per-tool `_meta` only if **all three** hold, at N = 10 per task: (a) A − B0 ≥ 20 points; (b) ALL+A − ALL
  ≥ 15 points; (c) median tokens of ALL+A ≤ 115% of ALL. Otherwise keep `alwaysLoad` as a documented user-side option
  (or drop it from the docs if (a) fails too).

### Q2. Which skills each profile serves (PR B)
- **Static part (no runs):** `project-scan` calls `graph_write` and `set_context`, and `scan_project` exists only on the
  maintenance profile; so `project-scan` goes on **default and maintenance**, not readonly. A spec checks that every tool
  a served skill names is advertised on that profile.
- **Run part (now, 1.89.0):** the readonly profile has no write tools. Does the full toolset skill waste turns there?
  - **RO-full:** `MCP=mcp-readonly.json`, the skill as is. **RO-lite:** the same, with a readonly variant of the
    user-visible skill (its "Persist" section and the write-tool lines removed).
  - Task T4, N = 5 each (screening), then N = 10 if close.
  - **Metric:** sessions with a failed write attempt (a `ToolSearch` for a write tool, or a denied write call); median turns.
- **Rule:** serve a **readonly variant** of the toolset skill on readonly if RO-full shows failed write attempts in
  **≥ 40%** of sessions *or* a median of **≥ 2 more turns** than RO-lite. Otherwise serve the **same skill on all three**.

### Q3. Installer write mode (after 1.90.0)
- **Test:** two timed dry installs from `bin/agent-install`'s printed output into a throwaway home, one per host:
  `export HOME=$(mktemp -d)`, seed it with a `~/.claude/settings.json` that already has one unrelated hook, follow
  the printed steps, then validate: every file in its place, `settings.json` and `~/.cursor/hooks.json` still parse
  (`ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' <file>`), the unrelated hook survived, and a fresh `claude -p`
  session shows the hook firing.
- **Also, at the next release after 1.90.0:** does the installed skill's `graph-mem-version` still match the repo without
  you noticing? (One yes/no.)
- **Metric:** minutes per host, mistakes (a misplaced file, invalid JSON, a lost hook), the drift yes/no.
- **Rule:** add a write mode (`--apply`, merge with backup) in a later PR if **either** install takes **> 10 minutes**, *or*
  there's **≥ 1 mistake** across the two, *or* drift happened unnoticed. Otherwise stay print-only (D2). If drift is the only
  problem, a read-only `--check` (compare the installed copies with the repo, write nothing) is the smaller fix.

### Q4. Hook-first guidance in Cursor
- **Arms** (Cursor, `mcp.json` pointed at `/mcp/readonly` with `X-MCP-Client: adoption-eval-cursor` for the runs, so
  nothing can write; revert after):
  **K0** nothing; **K1** the plan's §3.2 rule pasted in Customize → Rules; **K2** the hook only (`~/.cursor/hooks.json`);
  **K3** 1.90.0 instructions only (after 1.90.0).
- **How:** the IDE Agent chat, a new chat per run, workspace `<projects-dir>`, tasks T1 and T3, N = 5 per task.
  Manual checklist per run (tick boxes, no transcript kept):
  1. first tool call was graph_mem? (Y/N)
  2. any graph_mem call before the first edit? (Y/N), the **primary**
  3. how many graph_mem calls?
  4. hook fired? Make the hook script also `touch` a marker file under `~/adoption-eval/`, so this is visible without
     Cursor logs.
  5. reset the clone.
- **Optional automation:** the Cursor CLI (`agent -p --output-format stream-json --approve-mcps --trust --workspace <projects-dir>`,
  [headless docs](https://cursor.com/docs/cli/headless), [output format](https://cursor.com/docs/cli/reference/output-format)).
  The CLI reads `mcp.json`, `AGENTS.md` and `CLAUDE.md`; whether it applies User Rules and `~/.cursor/hooks.json` is
  **unverified**, and the shape of an MCP call in its stream isn't documented (the script matches `graph_mem` in
  `tool_call` events). So the IDE checklist is the reference, and CLI numbers count only if a K0/K2 pair matches the IDE.
- **Rule:** lead the Cursor guidance with the **hook** if K2 − K1 ≥ **30 points**; with the **User Rule** if K1 − K2 ≥ 30; else
  list both, rule first (a paste, no file). If K3 − K0 < 20 points, document that Cursor ignores server instructions
  (which confirms the third-party report in the plan's F2).

---

## 4. What Steve can run now, on 1.89.0

In this order, so each step is useful even if the next is skipped:
1. **Screening, Claude Code, T1, N = 5:** B0, R, S, H, A (25 runs). Gives the first read on Q-L and Q1(a).
2. **Q2 run part:** RO-full vs RO-lite on T4, N = 5 each (10 runs).
3. **Full round** for whatever cleared screening, plus RSH: T1–T3, N = 5 (15 runs per arm).
4. **Cursor K0, K1, K2** on T1 and T3, N = 5 each (30 chats, manual checklist).

After 1.90.0: I, ALL, ALL−x, ALL+A, K3, the Q3 install test, and `script/adoption_eval` over every saved log.

### Report format (counts only)

```
arm  task  n  adopted  ctx_before_edit  median_first_gm_turn  mean_gm_calls  skill_used  persist_attempts  hook_fired  median_tokens  median_cost
```
Plus the Claude Code version, the model alias, and the baseline-state yes/no list from setup step 3.

---

## 5. `script/adoption_eval` (ships in 1.90.0, read-only)

- `ruby script/adoption_eval/summarize.rb ~/adoption-eval/logs/*.jsonl [--csv]`, stdlib only (`json`, `optparse`).
- Reads JSONL files named `<arm>-<task>-<run>.jsonl`; writes nothing, makes no network call, needs no Rails.
- Understands Claude Code stream-json (`assistant` / `tool_use`, `system` hook events, `permission_denied`, `result`)
  and, best effort, the Cursor CLI stream (`tool_call` started events; graph_mem matched by name).
- Prints the per-arm and per-arm-per-task table above; never prints prompts, tool inputs or results (counts and tool
  names only).
- Specs use synthetic JSONL fixtures (hand-written events, `synth-*` values), no real transcripts.
