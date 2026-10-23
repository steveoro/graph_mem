# Agent rules & skills

The files in this directory, and the skills under `skills/` at the repo root,
are meant to be **copied out of this repo** into any project whose coding agent
talks to a running GraphMem MCP server. They are the *consumer* side of the
project.

For guidance on *developing* GraphMem itself, see the root `AGENTS.md` (the one
rule file for every agent in this repo) and `docs/development.md`.

## Files

| File | What it is |
|---|---|
| `graph_mem_mcp_rules.md` | The `AGENTS.md` snippet (10 lines): when to use the graph_mem skill. |
| `general_coding_rules.md` | Optional, project-agnostic coding rules; also plain Markdown for `AGENTS.md`. |
| `../../skills/graph-mem-mcp-toolset/` | The skill, with its `references/` (tool and maintenance reference, loaded only when needed). |
| `../../skills/project-scan/` | The on-request project scan skill. |

## Install in another project (the same for every agent)

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
