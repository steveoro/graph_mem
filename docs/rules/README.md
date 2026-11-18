# Agent rules & skills

The files in this directory, the skills under `skills/` at the repo root and the
hook scripts under `script/agent_hooks/` are meant to be **copied out of this repo**,
once per machine at user level or into any project whose coding agent talks to a
running GraphMem MCP server. They are the *consumer* side of the project.

For guidance on *developing* GraphMem itself, see the root `AGENTS.md` (the one
rule file for every agent in this repo) and `docs/development.md`.

## Files

| File | What it is |
|---|---|
| `graph_mem_mcp_rules.md` | The `AGENTS.md` snippet (10 lines): when to use the graph_mem skill. |
| `graph_mem_user_rule.md` | The user-level rule (9 lines), for `~/.claude/rules/` or Cursor's User Rules: graph_mem in every repository. |
| `general_coding_rules.md` | Optional, project-agnostic coding rules; also plain Markdown for `AGENTS.md`. |
| `../../script/agent_hooks/` | The SessionStart reminder hooks: `graph_mem_session_start.sh` (Claude Code) and `graph_mem_session_start_cursor.sh` (Cursor). |
| `../../skills/graph-mem-mcp-toolset/` | The skill, with its `references/` (tool and maintenance reference, loaded only when needed). |
| `../../skills/project-scan/` | The on-request project scan skill. |

## Install once per machine (user level, recommended)

Run `bin/agent-install` from the repo root and follow its output (`--claude` or `--cursor`
for one host). It prints the commands and writes nothing itself:

- Claude Code: the skills into `~/.claude/skills/`, `graph_mem_user_rule.md` as
  `~/.claude/rules/graph-mem.md`, the hook into `~/.claude/hooks/` plus its `SessionStart`
  entry for `~/.claude/settings.json`.
- Cursor: the skill (Cursor also reads `~/.claude/skills/`), the rule pasted in Settings >
  Customize > Rules > User Rules, the hook into `~/.cursor/hooks/` plus its `sessionStart`
  entry for `~/.cursor/hooks.json`.

The hook prints a short static reminder only when the server answers on
`$GRAPH_MEM_URL/up` (default `http://localhost:3030`), and is silent otherwise. It's on by
default; leave its steps out to skip it. User-level files reach every repository, including
sessions started in the parent folder of your repos (see `docs/quick_setup.md` §5).

## Install in another project (fallback, the same for every agent)

1. Copy the whole `skills/graph-mem-mcp-toolset/` folder (including `references/`),
   and `skills/project-scan/` if you want the on-request scan skill, into the
   project's `.agents/skills/`. For Claude Code, also put them in `.claude/skills/`
   (a symlink from one location to the other works in Claude Code; this repo links both).
2. Paste `graph_mem_mcp_rules.md` into the project's root `AGENTS.md` (create it if
   it's missing).
3. Claude Code only: if the project has a `CLAUDE.md`, make `@AGENTS.md` its first
   line, and move anything in it that applies to all agents into `AGENTS.md`. Claude
   Code reads `AGENTS.md` by itself only when there's no `CLAUDE.md`.

## Who reads what

For reference; nothing to configure per agent.

| Agent / IDE | Rules | Skills |
|---|---|---|
| Cursor | `AGENTS.md` | `.agents/skills/` |
| Codex | `AGENTS.md` | `.agents/skills/` |
| GitHub Copilot / VS Code | `AGENTS.md` (VS Code setting `chat.useAgentsMdFile`, on by default) | `.agents/skills/` |
| Devin CLI and Devin Desktop (formerly Windsurf) | `AGENTS.md` | `.agents/skills/` |
| Claude Code | `CLAUDE.md` with `@AGENTS.md`, or `AGENTS.md` when there's no `CLAUDE.md` | `.claude/skills/` |

## Notes

- Per-tool rule folders (`.cursor/rules/*.mdc`, `.devin/rules/`, `.windsurf/rules/`,
  `.github/copilot-instructions.md`) still work but aren't needed. Don't put the
  graph_mem text in both places: clients that combine sources load it twice.
- Windsurf is now Devin Desktop; older `.windsurf/` setups are still read as a fallback.
- The skill is plain Markdown: no scripts and no URL fetches. Review any skill before
  installing it, including this one.
- Keep `X-MCP-Client` set in your MCP config so each agent gets its own context
  bucket (see the skill's `references/tools.md`).
- `project-scan` runs only when the user asks for it: it uses Devin's `triggers` and
  Cursor/Claude Code's `disable-model-invocation`; `skills-ref validate` reports them as
  unexpected fields, which is expected.
