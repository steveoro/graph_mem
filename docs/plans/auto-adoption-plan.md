# graph_mem auto-adoption plan: make agents reach for graph_mem on their own

**Status:** active plan. Drafted 18 Nov 2026 on `main` at 1.89.0. PR A shipped in 1.90.0 (#179); PR B pending.
**Scope:** Claude Code first, Cursor second. Linux workstations, no Claude Desktop.
**Decisions (Steve, 18 Nov 2026):**
- **D1.** Rewording the existing server `instructions` is **not** an MCP surface change: pre-approved.
- **D2.** The installer starts **read-only**: `bin/agent-install` prints the snippets and short install
  guidance and writes nothing. No write, backup or uninstall modes for now.
- **D3.** The graph_mem guidance is **on by default**: the new instructions, the user rule, the skill
  trigger and the SessionStart reminder hook snippet all ship enabled (the printed hook snippet is part
  of the default output, not an opt-in flag).
- **D4.** Skills over MCP is **in scope behind a settings toggle, off by default**. Turning it on is an
  approved surface change behind the toggle; with it off the wire stays byte-identical.
- **D5.** Claude is started from the parent projects folder (`<projects-dir>`), where the graph_mem MCP
  server and its skills are already visible. The fix is salience, not configuration.

---

## 0. TL;DR

The setup works: started in `<projects-dir>`, Claude Code sees the graph_mem server and its skills. The
gap is **salience**: when the task is in another repo (for example goggles_admin2), nothing Claude reads
at session start makes graph_mem feel relevant to that task, and the place that says "always" (the tool
descriptions) isn't in view until Claude has already decided to look.

- **PR A (1.90.0), text + read-only installer, no surface change:** imperative server `instructions`
  (D1), a trigger-first skill description, a user-level rule, a SessionStart reminder hook snippet, and
  `bin/agent-install` printing them with install guidance (D2, D3). Tool counts stay 12 / 9 / 22.
- **A/B in goggles_admin2** (section 5) right after PR A lands, to see which text actually moves Claude.
- **PR B (1.91.0), Skills over MCP behind `mcp_skills_enabled` (default off):** feasible with the gem we
  already run (`mcp` 1.10.0); both current skills load through `MCP::Skill.from_directory` unchanged.
  Separate PR so A stays text-only and B's wire diff is reviewed on its own (section 6).

---

## 1. Why graph_mem goes unused outside its repo (findings)

### F1. Both hosts defer MCP tool definitions: the trigger wording in tool descriptions is invisible at decision time
- Claude Code: tool search is on by default; "Only tool names and server instructions load at session
  start". Claude has to call `ToolSearch` before it sees a description.
  [Claude Code MCP docs, "Scale with MCP tool search"](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search)
- Cursor: "dynamic context discovery" keeps only tool names in static context and syncs descriptions to a
  per-server folder read on demand ([Cursor blog](https://cursor.com/blog/dynamic-context-discovery);
  confirmed by Cursor staff on the [forum](https://forum.cursor.com/t/what-do-your-attached-mcp-servers-actually-cost-you-in-tokens-per-request-i-measured-it/166405);
  independent measurement at [mcprating.io](https://mcprating.io/blog/clients-load-tool-names-now), third party).
- Consequence: graph_mem's tool names (`search`, `get_context`, `get_entities`, `graph_write`, …) are
  generic and compete with built-in search tools. The "use at the start of …" openers in the `search` /
  `graph_write` descriptions are read only *after* Claude chose to look. **Triggers must live in text that
  is always loaded:** server instructions (Claude Code), the skill listing (both hosts), rules/memory files
  (both), or a hook.

### F2. The always-loaded text we have is weak or not actionable
- **Server instructions.** Set today (`lib/graph_mem/mcp_instructions.rb`, about 900 chars, under Claude
  Code's 4,096 cap). Claude Code docs: they "help Claude understand when to search for your tools, similar
  to how skills work" ([docs](https://code.claude.com/docs/en/mcp#tool-search-for-mcp-server-authors)). But:
  - the first step is "run the `orient` prompt or call `get_context`". Claude Code documents MCP prompts
    only as user-typed commands (`/graph_mem:orient`, [docs](https://code.claude.com/docs/en/mcp#use-mcp-prompts-as-commands));
    nothing says the model can invoke one. *(Unverified; assume it can't.)*
  - it opens with a definition, not a rule, and "At the start of a task" is easy to judge as not applying
    to a quick fix in another repo.
  - Cursor's MCP docs never mention `instructions` ([docs](https://cursor.com/docs/mcp)); a third-party
    server doc states Cursor does not inject them ([mnemory](https://github.com/fpytloun/mnemory/blob/main/docs/clients/cursor.md)).
    **Unverified**; the A/B checks it.
- **Skill description.** In the listing for both hosts (Claude Code caps it at 1,536 chars; ours is about
  900), but it is conditional ("in a project where the graph_mem MCP server is connected") and ends with
  "Not for … an app's own data store", which in a DB-heavy Rails app can read as "skip". *(Hypothesis; arm C3.)*
  Skills are picked by description match only; Claude Code's own guidance: "Claude skipped a rule that must
  hold every time: move the rule into a hook" ([skills docs](https://code.claude.com/docs/en/skills)).
- **The repo's own text wins attention, and it says nothing about graph_mem.** goggles_admin2's
  `CLAUDE.md` (58 lines of commands and architecture) never mentions graph_mem and doesn't import
  `@AGENTS.md`, so Claude Code ignores goggles_admin2's `AGENTS.md`
  ([memory docs, AGENTS.md table](https://code.claude.com/docs/en/memory#agents-md)); that `AGENTS.md`
  has no graph_mem section either.

### F3. Starting from `<projects-dir>`: what loads when (D5)
From the [memory](https://code.claude.com/docs/en/memory) and [skills](https://code.claude.com/docs/en/skills) docs,
for a session started in `<projects-dir>` (Steve's way) and, for comparison, inside the repo:

| Text | Started in `<projects-dir>` | Started in `<projects-dir>/goggles_admin2` |
|---|---|---|
| `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` | at launch | at launch |
| `<projects-dir>/CLAUDE.md` | at launch | at launch (ancestor folders load) |
| `<projects-dir>/goggles_admin2/CLAUDE.md` | **on demand**, once Claude reads or edits a file there | at launch |
| `<projects-dir>/graph_mem/AGENTS.md` (graph_mem's own rule) | on demand, only if Claude touches graph_mem files | never |
| `~/.claude/skills/*` | listed | listed |
| `<projects-dir>/.claude/skills/*` | listed | not listed (project skills load from the start dir up to the repo root) |
| `<projects-dir>/graph_mem/.claude/skills/*` | on demand, once Claude works on graph_mem files | never |
| graph_mem server instructions + tool names | at launch | at launch |

What this means for the `<projects-dir>` workflow:
- graph_mem's own `AGENTS.md` rule never reaches a goggles_admin2 task, and the skill is visible only if it
  sits in `<projects-dir>/.claude/skills/` or `~/.claude/skills/` (Steve reports it is).
- goggles_admin2's `CLAUDE.md` arrives **mid-session**, the first time Claude opens a file there: it is the
  newest, most specific project text in context and has no graph_mem line, so it steers the rest of the task.
- So the always-on trigger has to sit at user level (`~/.claude/rules/`, location-independent) or in
  `<projects-dir>/CLAUDE.md`, plus the server instructions and a hook. `~/.claude/rules/` is preferred: it
  also works when a session starts inside a repo.
- Cursor reads `~/.claude/skills/` and `~/.agents/skills/` too ([Cursor skills](https://cursor.com/docs/skills)).
  Cursor User Rules live only in the settings UI (Customize → Rules, [docs](https://cursor.com/docs/rules));
  a user-level `~/.cursor/hooks.json` `sessionStart` hook can add `additional_context`
  ([Cursor hooks](https://cursor.com/docs/hooks)). [agents.md](https://agents.md) defines repo files only.

---

## 2. Options ranked (impact vs effort)

| # | Lever | Host | Impact | Effort | Surface change? | Status |
|---|---|---|---|---|---|---|
| 1 | SessionStart command hook printing a short reminder when `/up` answers (the plan said `/api/v1/status`, which needs auth) | Claude Code, Cursor | High: every session, every repo | S | No | PR A (snippet, on by default, D3) |
| 2 | User-level rule `~/.claude/rules/graph-mem.md` | Claude Code (paste into Cursor User Rules) | High | XS | No | PR A |
| 3 | Imperative server `instructions` naming tools | Claude Code (Cursor unverified) | Medium-high, zero install | XS | No (D1) | PR A, pre-approved |
| 4 | Trigger-first skill description | Both | Medium | XS | No | PR A |
| 5 | User-side `alwaysLoad: true` on the graph_mem server entry | Claude Code | Medium; costs context every turn | XS | No | Documented as optional in PR A |
| 6 | Per-tool `_meta: {"anthropic/alwaysLoad": true}` on `search` + `get_context` | Claude Code | Medium | S (`ToolWrapper` already emits `meta(...)`) | **Yes** (tools/list output) | Open, after the A/B |
| 7 | `UserPromptSubmit` `mcp_tool` hook calling `search` with each prompt | Claude Code | High recall, noisy, adds latency | M | No | Not now |
| 8 | Claude Code / Cursor plugin packaging | Both | Medium: bundles 1, 2, 4 | M | No | Backlog |
| 9 | Skills over MCP (SEP-2640) behind `mcp_skills_enabled` | Hosts with the extension (not Claude Code or Cursor yet) | Future | M | Yes, approved behind the toggle (D4) | PR B |
| 10 | A new prompt like `/graph_mem:recall` | Both | Low: user-typed; `orient` / `recall` / `persist` exist | — | Yes | Not needed |

Notes:
- Claude Code skips `mcp_tool` hooks on SessionStart at launch (servers aren't connected yet); only
  `type: "command"` works there ([hooks docs](https://code.claude.com/docs/en/hooks#mcp-tool-hook-fields)).
  So the reminder is a shell script, not a direct `get_context` call.
- Hook output is capped at 10,000 chars and added as a system reminder before the first prompt
  ([hooks docs](https://code.claude.com/docs/en/hooks#add-context-for-claude)). Ours stays static and short;
  no graph data goes into it.
- Cursor `sessionStart` is fire-and-forget; `additional_context` goes into "the conversation's initial
  system context" ([docs](https://cursor.com/docs/hooks)). Whether it lands before the first turn: **unverified**.

---

## 3. Wording proposals (before → after)

### 3.1 Server `instructions` (`lib/graph_mem/mcp_instructions.rb`, default profile)

**Before** (current, ~900 chars):
```
graph_mem is a shared knowledge graph of what earlier agent sessions learned about this user's projects: conventions, preferences, where things live, and verified fixes.
At the start of a task, run the `orient` prompt or call `get_context`, then load the project's Conventions entity.
Before choosing a convention (versioning, changelog, docs or test style, config, release steps) or first editing a file or component, call `search` with the file paths and component names; if a rule needs a value you don't have, look it up before acting.
Before your final reply, if the user corrected you, stated a preference, or you verified a fix or a location, persist it as one general rule (`persist` prompt, `graph_write`, or `graph_edit` with supersede to rewrite an old rule).
Prefer entity ids over names for edits and deletes. Maintenance tools are on /mcp/maintenance.
```

**After** (~1,130 chars, under the spec's 2,048 cap; imperative, repo-agnostic, tool names first, no model-uncallable step):
```
Use graph_mem in EVERY coding task in ANY repository, not only in graph_mem itself: it holds this user's conventions, preferences, file locations and verified fixes for all their projects, learned in earlier sessions.
1. First tool calls of a session, before reading or editing code: `get_context`; if no project is active, `search` for the repository name and `set_context` to its Project entity; then `get_entities` for "<Project> Conventions" and "User Preferences". Skip any that don't exist yet.
2. Before choosing a convention (version bump, changelog, docs or test style, naming, config location, release steps) or first editing a file or component: `search` with the file paths and component names. Prefer a stored rule over your own default.
3. Before your final reply, if the user corrected you, stated a preference, or you verified a fix or a location: save it as one general rule with `graph_write` (or `graph_edit` with supersede to replace an old rule).
The user can also type the `orient`, `recall` and `persist` prompts. Prefer entity ids over names for edits and deletes. Maintenance tools are on /mcp/maintenance.
```
- Readonly drops step 3 (as today). Keeps the words `orient`, `search`, `persist` so
  `spec/lib/graph_mem/mcp_instructions_spec.rb` (≤ 2,048 chars, named tools advertised) still holds;
  if the spec's `include("persist")` meant the prompt, it still matches.
- Sentence 1 is the trigger Claude Code's tool search matches on; it also answers "does this apply
  here?" before the model has to guess.

### 3.2 User-level rule (`docs/rules/graph_mem_user_rule.md`, to be saved as `~/.claude/rules/graph-mem.md`)

**Before:** nothing at user level; the repo snippet (`docs/rules/graph_mem_mcp_rules.md`) says
"This project uses the graph_mem MCP server … Use the `graph-mem-mcp-toolset` skill: at the start of
a task …", which is written for one repo and is conditional.

**After** (≤ 12 lines, also pasteable into Cursor's User Rules):
```markdown
## graph_mem memory (MCP), every repository
The graph_mem MCP server is connected in all my projects and holds my conventions, preferences,
file locations and verified fixes. Treat it as the first source of project knowledge, before the
codebase and before your own defaults.
- Start of every task, before reading code: load the `graph-mem-mcp-toolset` skill (or call
  graph_mem `get_context`, then `search` for this repository's Project and its Conventions).
- Before deciding a convention or first editing a file: graph_mem `search` with the paths and names.
- Before the final reply: save corrections, preferences, locations and verified fixes with `graph_write`.
- If graph_mem doesn't answer, say so once and carry on.
```
Rationale: names the server and the tool verbs (matches tool search), says "every repository",
puts graph_mem before the codebase (beats the per-repo CLAUDE.md for attention), and has a graceful
fallback so it isn't harmful when the server is down.

### 3.3 Skill description (`skills/graph-mem-mcp-toolset/SKILL.md`)

**Before (start/end):** "Recalls and records project conventions … Use at the start of any coding task
in a project where the graph_mem MCP server is connected, … Not for designing graph databases or
knowledge-graph schemas in general, or for an app's own data store."

**After:**
```yaml
description: >-
  Use at the start of EVERY coding task in any repository, before reading or
  editing code: loads this user's project conventions, preferences, file
  locations and verified fixes from the graph_mem MCP memory server, and saves
  new ones before the final reply. Use again before deciding a convention
  (version bump, changelog or docs style, test style, naming, file or config
  location, release steps) or first editing a file or component. Also use when
  the user says "remember this", "like last time", "as usual" or mentions
  graph_mem or memory. Skip only when the task is about designing a graph
  database schema itself.
```
Key use case first (Claude Code cuts at 1,536 chars and says "put the key use case first"); the
negative clause is narrowed so a DB-heavy app isn't excluded. Check against
`spec/docs/agent_text_sync_spec.rb` (Agent Skills validator rules) in the PR.

### 3.4 SessionStart hook text (`script/agent_hooks/graph_mem_session_start.sh`, printed by `bin/agent-install`, saved by the user under `~/.claude/hooks/`)

```sh
#!/usr/bin/env sh
# Prints a graph_mem reminder only when the local server answers; silent otherwise.
URL="${GRAPH_MEM_URL:-http://localhost:3030}"
curl -fsS --noproxy '*' -m 2 "$URL/up" >/dev/null 2>&1 || exit 0   # as shipped; the draft probed /api/v1/status
cat <<'TXT'
graph_mem (MCP server "graph_mem") is connected and holds this user's conventions, preferences, file locations and verified fixes for this repository. Before reading or editing code, call graph_mem get_context, then search for this repository's Project and its Conventions (use ToolSearch to load the tools). Before the final reply, save corrections and verified fixes with graph_write.
TXT
```
- **As shipped (1.90.0):** the check is `curl -fsS --noproxy '*' -m 2 "$URL/up"`, Rails' anonymous health check
  (`--noproxy`: curl would send even `localhost` through a configured proxy).
  `/api/v1/status` needs an operator session or the bearer token (`ApiAuthentication` has no loopback
  exemption, by design), so it would have kept the hook silent; Steve chose `/up` over adding a token.
- Claude Code `~/.claude/settings.json`:
  `{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"~/.claude/hooks/graph_mem_session_start.sh","timeout":5}]}]}}`
  (plain stdout on SessionStart is added as context; [docs](https://code.claude.com/docs/en/hooks#exit-code-0)).
- Cursor `~/.cursor/hooks.json`: `{"version":1,"hooks":{"sessionStart":[{"command":"./hooks/graph_mem_session_start_cursor.sh"}]}}`,
  where the Cursor variant prints `{"additional_context": "<same text>"}`.
- Re-fires after `/clear` and compaction, which also restores the reminder that compaction drops.
- "use ToolSearch" is Claude Code-specific; the Cursor variant says "read the graph_mem MCP tool
  descriptions" instead. *(Exact Cursor phrasing to be tuned in the A/B.)*

---

## 4. PR A (1.90.0): "Auto-adoption A", text + read-only installer

No gem, migration, tool, parameter or output change. Tool counts 12 / 9 / 22; tools/list snapshots unchanged.

1. `lib/graph_mem/mcp_instructions.rb`: the texts from 3.1 (default, readonly without step 3, maintenance);
   update `spec/lib/graph_mem/mcp_instructions_spec.rb` (≤ 2,048 chars; only advertised tools named). D1.
2. `skills/graph-mem-mcp-toolset/SKILL.md`: the description from 3.3; bump `metadata.graph-mem-version`
   (checked by `spec/docs/agent_text_sync_spec.rb`, which also mirrors the skills-ref rules).
3. `docs/rules/graph_mem_user_rule.md` (3.2), within the same 12-line budget as the repo snippet.
4. `script/agent_hooks/graph_mem_session_start.sh` (Claude Code, plain stdout) and
   `script/agent_hooks/graph_mem_session_start_cursor.sh` (prints `{"additional_context": …}`), from 3.4.
5. `bin/agent-install` (Ruby stdlib only), **read-only** (D2): prints, per host, the snippets and a few
   lines on where each goes. It writes nothing and reads nothing from `~/`.
   - `bin/agent-install` (no args) prints the Claude Code block then the Cursor block; `--claude` /
     `--cursor` print one; `--url URL` fills the status URL in the hook (default `http://localhost:3030`).
   - Claude Code block: `mkdir -p ~/.claude/rules ~/.claude/skills ~/.claude/hooks`; the `cp -r` line for the
     skill(s) from the repo's `skills/`; the rule file; the hook script; the `SessionStart` JSON to merge
     into `~/.claude/settings.json` by hand; how to check (`/memory`, `/skills`, `/context`).
   - Cursor block: the skill (already covered by `~/.claude/skills/`, or `~/.cursor/skills/`), the User
     Rules text to paste in Customize → Rules, the hook script and the `~/.cursor/hooks.json` entry.
   - The hook snippet is part of the default output (D3); the guidance says it can be left out.
   - Never prints or touches MCP server config (that stays `claude mcp add … --scope user` /
     `~/.cursor/mcp.json`, `docs/quick_setup.md` §4).
6. `docs/quick_setup.md`: §5–§6 become "Install once per machine (`bin/agent-install`)", with the per-project
   copy kept as the fallback for teammates; add the F3 table (started in `<projects-dir>` vs in the repo);
   document optional `alwaysLoad: true`.
7. `script/adoption_eval/summarize.rb` (read-only log summarizer, stdlib only; spec'd in
   [`auto-adoption-tests.md`](auto-adoption-tests.md) §5), with synthetic JSONL fixtures.
8. Specs: `bin/agent-install` output for each flag (contains the rule, the hook JSON, the skill paths; no
   absolute paths outside `~/` and the repo); it creates no files (run under a temp HOME and assert it stays
   empty); both hook scripts print nothing when the URL is unreachable and the expected text when a stub answers.
9. CHANGELOG 1.90.0, version bump.

Size: a few hundred lines. Review checks: instructions length, agent-text sync spec, no wire change.

---

## 5. A/B in goggles_admin2

Superseded by the full test design in [`auto-adoption-tests.md`](auto-adoption-tests.md) (section 8): the same idea
(arms that add one lever each, sessions started from `<projects-dir>`, "graph_mem before the first edit" as the
primary metric), with fixed tasks on two repos, N runs per arm and written decision rules.

---

## 6. PR B (1.91.0): Skills over MCP behind `mcp_skills_enabled` (default off)

**Standard and support (Nov 2026).**
- [SEP-2640 Skills Extension](https://modelcontextprotocol.io/seps/2640-skills-extension) is **Final**
  (merged 13 Sep 2026; spec in [ext-skills](https://github.com/modelcontextprotocol/ext-skills), WG
  [charter](https://modelcontextprotocol.io/community/working-groups/skills-over-mcp)). Servers declare
  `resources` + `extensions["io.modelcontextprotocol/skills"]`, answer `skills/list` and `skills/get`, and
  serve files through `resources/read` at `skill://<name>/…` with SHA-256 digests
  ([overview](https://modelcontextprotocol.io/extensions/skills/overview)).
- Ruby `mcp` gem: since 1.9.0 (ruby-sdk #635; we run 1.10.0): `MCP::Server.new(…, skills: MCP::Skill.from_directory(root))`,
  `MCP::Skill.capability`, `MCP::Skill.read_file(skills, uri)`; `directoryRead` is refused by this gem release
  ([ruby-sdk CHANGELOG](https://github.com/modelcontextprotocol/ruby-sdk/blob/main/CHANGELOG.md)).
- Hosts: the [client matrix](https://modelcontextprotocol.io/extensions/client-matrix) shows no Skills support
  for Claude Code or Cursor yet; fast-agent, MCPJam, mcpc, MCP Inspector (partial) and ChatGPT plugins (partial)
  have it ([implementations](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md)).
  Hence the toggle: ship it off, flip it on when a host we use supports it (D4).

**Feasibility check (done against `main` and gem 1.10.0, in a scratch script, not in the repo):**
`MCP::Skill.from_directory("skills")` loads both skills as they are (`skill://graph-mem-mcp-toolset/SKILL.md`
with its 3 `references/` files, `skill://project-scan/SKILL.md`); the extra frontmatter fields
(`disable-model-invocation`, `triggers`, `license`, `metadata`) pass. A server built with
`extensions: MCP::Apps.capability.merge(MCP::Skill.capability)` declares both extensions, answers
`skills/list`, lists the `SKILL.md` entries in `resources/list`, and serves `resources/read` for a `skill://`
URI through a custom `resources_read_handler` that calls `MCP::Skill.read_file` first.

**Design (mirrors `mcp_apps_enabled`, 1.87.0):**
- `AppSettings` field `mcp_skills_enabled`, `default: false` (`app/models/app_settings.rb`); listed in
  `SettingsSchema` with the feature flags; locale label under Settings › Feature flags › "Skills over MCP";
  `docs/app_settings_reference.md` row.
- `lib/graph_mem/mcp_skills.rb`: `McpSkills.enabled?` and `McpSkills.catalog` (memoized
  `MCP::Skill.from_directory(Rails.root.join("skills"))`; the folder is already in the Docker image via `COPY . .`).
- `ServerFactory.capabilities(apps_enabled:, skills_enabled: false)`: start from `CAPABILITIES`; add
  `extensions:` only when at least one is on, merging `MCP::Apps.capability` and `MCP::Skill.capability`.
  Keyword default `false` keeps existing callers (`script/mcp_compat/claude_client_check.rb`) unchanged.
- `ServerFactory.for(profile, apps_enabled:, skills_enabled: GraphMem::McpSkills.enabled?)`: pass
  `skills: skills_enabled ? McpSkills.catalog : nil`. **`nil`, not `[]`:** `[]` would still register the
  skills methods and serve an empty catalog.
- `resources_read_handler`: when skills are on, `MCP::Skill.read_file(skills, uri)` first, then
  `ResourceCatalog.read(providers, uri)`. Our handler replaces the gem's default reader, so without this
  the skill files would not be served (also noted in the 1.9.0 plan's "Later").
- Profiles: `project-scan` on default and maintenance only (it calls `graph_write`, absent on readonly); the
  toolset skill on all three, or a readonly variant on readonly, decided by test Q2 in `auto-adoption-tests.md`.
- Access: `AccessGate` is Rack middleware on every `/mcp` path, so `skills/*` gets the same IP allowlist
  and bearer token as tools; nothing to add. Lockdown unchanged.

**Toggling: restart or listChanged?** Same as MCP Apps, **no listChanged**: graph_mem advertises
`listChanged: false` and capabilities are fixed in `initialize`, so a notification couldn't add an
extension to a live session anyway. Saving the setting calls `GraphMem::OfficialMcp.refresh_access!(transports: true)`
from `SettingsGroupUpdate` (a new `apply_mcp_skills_change`, like `apply_mcp_apps_change`): the HTTP
servers are rebuilt and open MCP sessions close, so hosts reconnect and see the new capabilities. A stdio
runner needs a restart. No Rails server restart for HTTP.

**Wire guarantees.**
- Off (default): `initialize` capabilities, tools/list, prompts/list, resources/list and every snapshot
  (`spec/mcp/tools_list_snapshot_spec.rb`, `spec/fixtures/mcp/handshakes/*.json`, the `eq CAPABILITIES`
  specs) stay **byte-identical** to 1.90.0. A spec asserts this explicitly, as the 1.87.0 one does for Apps.
- On: an approved surface change (D4): the `io.modelcontextprotocol/skills` extension in capabilities,
  `skills/list` / `skills/get`, and `skill://` entries in resources/list and resources/read. Tool counts unchanged.

**Specs:** off = identical wire (each profile); on = capabilities carry both extensions when Apps is also
on; `skills/list` returns the two skills with digests; `resources/read` serves `SKILL.md` and a
`references/` file, and a `graph-mem://` resource still reads; an unknown `skill://` URI gives `-32602`;
toggling via settings rebuilds the HTTP servers (as the Apps spec does). End-to-end: MCP Inspector ≥ 2.6
CLI skill verification as a manual check, recorded in `docs/protocol_compat.md`.

**Why a separate PR:** PR A is text plus a read-only script with no wire change; PR B changes the
server factory, settings and (when on) the wire, and adds snapshot-guard specs. Splitting keeps each diff
small and reviewable on its own, lets the A/B run on PR A without B's noise, and B can wait if a host
announces support details that change the design. Estimated B size: under 600 lines.

---

## 7. Open questions

Each one now has a test with a metric and a decision rule in [`auto-adoption-tests.md`](auto-adoption-tests.md)
(Steve, 18 Nov 2026: "design some tests that could make the decision bar swing"):
1. Per-tool `anthropic/alwaysLoad` `_meta` on `search` + `get_context` (a tools/list output change), or only the
   user-side `alwaysLoad` toggle? → test **Q1**.
2. PR B profiles: which skills each profile serves? → test **Q2** (`project-scan` stays off readonly by a static rule).
3. Installer write mode: add one later, or stay print-only? → test **Q3**.
4. Cursor: lead with the hook or with the User Rules paste? → test **Q4**.
5. Which levers (instructions, user rule, skill trigger, hook) earn their place in the default install output? → test **Q-L**.

---

## 8. Decision tests

The test design lives in [`auto-adoption-tests.md`](auto-adoption-tests.md): fixed tasks on two open-source repos
(goggles_admin2 and fast-mcp, as scratch clones), Claude Code headless runs from `<projects-dir>` with stream-json logs,
arms flipped by user-level files and flags, N = 5 runs per arm per task, and a 20-point bar. Baseline, user rule,
skill trigger, hook and alwaysLoad arms run on 1.89.0 now; the instructions arms need 1.90.0. `script/adoption_eval`
(read-only, PR A) summarizes the saved logs into counts.

---

## Sources
- Claude Code MCP (tool search, server instructions limits, alwaysLoad, prompts as commands): https://code.claude.com/docs/en/mcp
- Claude Code memory (CLAUDE.md/AGENTS.md loading, user rules): https://code.claude.com/docs/en/memory
- Claude Code skills (locations, nested/parent discovery, listing budget, "move it into a hook"): https://code.claude.com/docs/en/skills
- Claude Code hooks (SessionStart, additionalContext, mcp_tool limits): https://code.claude.com/docs/en/hooks
- Claude Code permissions (`mcp__graph_mem__*` allow rules): https://code.claude.com/docs/en/permissions
- Claude Code plugins: https://code.claude.com/docs/en/plugins
- Cursor rules / skills / hooks / MCP / plugins: https://cursor.com/docs/rules · https://cursor.com/docs/skills · https://cursor.com/docs/hooks · https://cursor.com/docs/mcp · https://cursor.com/docs/plugins
- Cursor dynamic context discovery: https://cursor.com/blog/dynamic-context-discovery
- Third-party: Cursor doesn't inject server instructions (unverified): https://github.com/fpytloun/mnemory/blob/main/docs/clients/cursor.md
- Third-party: client token measurements: https://mcprating.io/blog/clients-load-tool-names-now
- SEP-2640 / Skills extension / client matrix / implementations: https://modelcontextprotocol.io/seps/2640-skills-extension · https://modelcontextprotocol.io/extensions/skills/overview · https://modelcontextprotocol.io/extensions/client-matrix · https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md
- Ruby SDK changelog (Skills in 1.9.0): https://github.com/modelcontextprotocol/ruby-sdk/blob/main/CHANGELOG.md
- Earlier plans reused: `docs/plans/done/agent-rules-plan.md` (instructions text, prompts, skill), `docs/plans/done/mcp-apps-plan.md` (the feature-flag precedent), `docs/plans/done/mcp-sdk-1.9.0-plan.md` ("Later: Skills over MCP" catches).
- Code read for the toggle: `lib/graph_mem/official_mcp/server_factory.rb`, `lib/graph_mem/mcp_apps.rb`, `app/controllers/concerns/settings_group_update.rb`, `app/models/app_settings.rb`; `mcp` gem 1.10.0 `lib/mcp/server.rb` and `lib/mcp/skill/*`.
