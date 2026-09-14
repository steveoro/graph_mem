# AGENTS.md

GraphMem is a Ruby on Rails 8.1 application implementing an MCP server for
graph-based agent memory. Two different kinds of work happen around this
repository — pick the right entry point.

## Using GraphMem as an MCP toolset

If your session has a running GraphMem instance configured as an MCP server —
including sessions working on this repo itself — follow the consumer docs:

- `docs/rules/graph_mem_mcp_rules.md` — the always-on 4-phase session workflow
  (Orient → Recall → Work → Persist), dedup discipline, and context scoping.
- `skills/graph-mem-mcp-toolset/SKILL.md` — the full operational playbook
  (vendor-neutral SKILL.md; the `.cursor/skills/` copy is a thin adapter).
- `docs/mcp_tools.md` — tool-by-tool reference and the error-envelope spec.

## Developing GraphMem (editing this codebase)

- Contributor setup guide: `docs/development.md`.
- Repo-scoped rules live in `.cursor/rules/` and `.devin/rules/` — read them
  before running commands (they cover the RVM gemset requirement and git
  safety conventions).
- Ruby is pinned via RVM: prefix `bundle`/`rails`/`rspec`/`rubocop` with
  `source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem`.
- Lint: `bundle exec rubocop`. Tests: `bundle exec rspec` (needs MariaDB 11.8+).
- Architecture: `docs/architecture.md`. Troubleshooting:
  `docs/troubleshooting.md`. Operator UI docs: `docs/operator/`.
