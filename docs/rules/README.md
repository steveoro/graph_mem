# Agent rules & skills

The files in this directory — and `skills/graph-mem-mcp-toolset/` at the repo
root — are meant to be **copied out of this repo** into whichever agent or IDE
talks to your running GraphMem MCP server. They are the *consumer* side of the
project: rules and playbooks for an agent that has GraphMem configured as an
MCP toolset.

For guidance on *developing* GraphMem itself, see `AGENTS.md`,
`docs/development.md`, and the repo-scoped rules under `.cursor/rules/` and
`.devin/rules/` — those are never copied out.

## Files

| File | What it is |
|---|---|
| `graph_mem_mcp_rules.md` | Always-on rules for agents using the GraphMem MCP toolset: the 4-phase session workflow, tool usage, dedup discipline, context scoping. |
| `general_coding_rules.md` | Generic coding conventions, independent of GraphMem. Adopt or skip. |
| `../../skills/graph-mem-mcp-toolset/SKILL.md` | The full operational playbook in vendor-neutral SKILL.md format. |

## Where to install them

| Agent / IDE | Rules target | Skill target |
|---|---|---|
| Cursor | `.cursor/rules/graph_mem.mdc` (project) or Settings → Rules (global) | `.cursor/skills/graph-mem-mcp-toolset/` |
| Windsurf | append to `~/.codeium/windsurf/memories/global_rules.md` (global) or `.windsurf/rules/` (project) | `.windsurf/skills/` if your version supports skills; otherwise the rules file alone carries the workflow |
| Claude Code | append to `CLAUDE.md` (project) or `~/.claude/CLAUDE.md` (global) | `.claude/skills/graph-mem-mcp-toolset/` |
| Devin | `.devin/rules/` in the target repo, or personal plugin rules | `.devin/skills/graph-mem-mcp-toolset/` (`.cursor/skills/` is also discovered) |
| AGENTS.md-compatible (Codex, Copilot, ...) | append to `AGENTS.md` | copy `skills/graph-mem-mcp-toolset/` into the repo |

## Notes

- The YAML frontmatter (`description`, `alwaysApply`) is Cursor's rule format;
  other hosts ignore it harmlessly — strip it if your host is strict about
  file shape.
- When copying the skill into your own project, use the canonical
  `skills/graph-mem-mcp-toolset/` directory — the copy under `.cursor/skills/`
  is a thin adapter that points back at the canonical file.
- Keep `X-MCP-Client` set in your MCP config so each agent gets its own
  persisted context bucket (see the Multi-Agent Context Scoping section of
  `graph_mem_mcp_rules.md`).
