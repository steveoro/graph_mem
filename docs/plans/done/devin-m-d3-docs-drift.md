# Devin handoff — M-D3: docs drift after graph_mem 1.54.0

Plan: `docs/plans/mcp-update-plan.md` §D, item M-D3 (and PR-2 §2.11). PR-2 (#112) is merged and
tagged `v1.54.0`, so this can start now. Docs only: no code, no specs, no version bump.

- **Branch:** `devin/m-d3-docs-drift`, off `main` at or after `89b13a0` (the #112 merge).
- **Files (touch only these):** `README.md`, `docs/development.md`, `docs/troubleshooting.md`,
  `docs/mcp_tools.md`, `CHANGELOG.md`.
- Line numbers below are as of `89b13a0`. They differ from the plan's (written before PR-2);
  use these. **Stop and ask if a quoted line isn't where it says, or doesn't read as quoted.**

## Facts to write (all true as of 1.54.0)

- fast-mcp is pinned to **v1.8.0** (Steve's fork).
- Streamable HTTP and stdio negotiate MCP **2024-11-05 … 2025-11-25**: `initialize` echoes a
  supported version and answers `2025-11-25` to anything else.
- 2026-07-28 clients fall back automatically via the `server/discover` probe;
  `MCP_PROTOCOL_NEGOTIATION=legacy` skips the probe (and the extra stdio process start).
- `/mcp/sse` is deprecated in MCP 2026-07-28 and kept for older clients (decision D-3).

The standard sentence (step 1) is:

> Streamable HTTP and stdio negotiate 2024-11-05 … 2025-11-25; 2026-07-28 clients fall back
> automatically via the `server/discover` probe; `MCP_PROTOCOL_NEGOTIATION=legacy` skips the
> probe (and the extra stdio process start).

## Steps

1. **Version and protocol wording.**
   1. `README.md:36` — "Use `/mcp` for the default 2025-03-26 **Streamable HTTP** profile." → drop
      "2025-03-26 " (keep the rest of the paragraph), and add the standard sentence as a new
      paragraph right after the paragraph ending at `:39`.
   2. `README.md:67` — "pinned to v1.7.1" → "pinned to v1.8.0"; "adds 2025-03-26 Streamable HTTP
      support" → "adds Streamable HTTP support (2024-11-05 … 2025-11-25)".
   3. `README.md:340` — "GraphMem now supports the 2025-03-26 Streamable HTTP transport." →
      "GraphMem supports the Streamable HTTP transport (MCP 2024-11-05 … 2025-11-25)."
   4. `docs/development.md:75` — "three 2025-03-26 Streamable HTTP profiles" → "three Streamable
      HTTP profiles"; add the standard sentence after the profile list (after `:79`).
   5. `docs/development.md:219` — in the curl example, `"protocolVersion":"2025-03-26"` →
      `"protocolVersion":"2025-11-25"`.
   6. `docs/development.md:324` — spec link →
      `[MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)`.
   7. `docs/troubleshooting.md:23` — "Streamable HTTP (2025-03-26, recommended)" → "Streamable HTTP
      (2024-11-05 … 2025-11-25, recommended)".
2. **Mark `/mcp/sse` deprecated.** After each mention below, add
   "(deprecated in MCP 2026-07-28; kept for older clients)", once per mention, fitted to the sentence
   (inside a JSON code block, put it in the prose line just above or below the block instead, never
   inside the JSON):
   - `README.md:39`, `:212`, `:301` (JSON block), `:353`, `:484` (JSON block);
   - `docs/development.md:87`;
   - `docs/troubleshooting.md:24`;
   - `docs/mcp_tools.md:18`, `:102`.
3. ~~`docs/mcp_access_control.md` stdio launch line~~ — **skip: already done** in PR-2 (its "stdio"
   section says to launch `bin/mcp_stdio_runner.rb` by a fixed absolute path with no user-supplied
   arguments). Don't edit that file.
4. **Re-grep** and list every remaining hit in the PR description rather than guessing:
   `rg -n "1\.7\.1|2025-03-26" README.md docs` (ignore `docs/plans/` and `CHANGELOG.md`).
   Expected leftovers to *list, not change*: `docs/mcp_access_control.md:168` (lists 2025-03-26 as
   one of the negotiated versions, on purpose) and `docs/mcp_toolset_consolidation.md:318`
   (history: "Since 1.45.0 (FastMCP v1.7.1 …)").
5. **CHANGELOG** `## [Unreleased]` (line 8, currently empty) › add
   `### Changed`: "Docs: fast-mcp v1.8.0 and the 2024-11-05 … 2025-11-25 negotiation range in the
   README, development and troubleshooting guides; `/mcp/sse` marked deprecated (kept for older
   clients)."

## Commands

Docs only, so the suite isn't required; run the lint that CI runs on Markdown-adjacent files:

```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem && bundle exec rubocop
rg -n "1\.7\.1|2025-03-26" README.md docs --glob '!docs/plans/**'
```

## Done when

- Every step above is applied, or listed in the PR as "didn't match, asked".
- The re-grep output is pasted into the PR description, each hit marked "intentional" or "missed".
- `git diff --stat main` shows only the five files listed above.
- PR opened against `main`; CI green.

**Stop and ask** if a step doesn't match the code, or if a sentence would need rewording beyond
what's written here (wording is Steve's call).
