---
description: General coding rules (project-agnostic)
globs:
alwaysApply: true
---

# Core Coding Rules

These rules are project-agnostic. They are bundled with the GraphMem agent
rules for convenience, but apply whether or not the session uses GraphMem.

- **Schema first**: DB schema is the primary source of truth for data structure.
- **Know your context**: Verify project folder and development environment, runtime target, and containers before running commands.
  Example: most workspaces include more than one project root, each with its own dev stack and languages. Focus on the target project, look for relevant files in the project root that might include target versions of the dev stack in use. (E.g: `.versions.conf`, `.ruby-version`, `docker-compose.yml`, `Gemfile`, `package.json`, `.rvmrc`, ...)
- **Keep it simple**: Prefer straightforward solutions and small, testable units.
- **Test like production**: Real instances over doubles; randomize factories; no fake data in dev/prod.
- **Don't sprawl**: Touch only code relevant to the task; avoid architecture shifts unless asked.
- **Refactor early**: Split files >500 lines or functions >60 lines.
- **Evolve, don't fork**: Fix within current patterns before introducing new tech; remove old impls if replaced.
- **Document**: Record critical changes; remove one-off helpers once used.
- **Document public APIs**: When adding or editing classes, describe basic
  usage and the expected parameter/return types on public methods. Prefer
  concise YARD-style comments for Ruby.
