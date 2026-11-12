# Done plans

Design records and step lists for work that has shipped. They are kept for their decisions and
rationale; the code, the specs and `CHANGELOG.md` are the source of truth for what was built. File:line
references inside them point at the commits they were written from and are not kept up to date.

Active plans and the backlog live in [`docs/plans/`](../).

| File | What it records | Shipped |
|---|---|---|
| [`mcp-update-plan.md`](mcp-update-plan.md) | MCP hardening and the move from fast-mcp to the official `mcp` gem; the `D-nn` decisions other plans and code comments cite | 1.54.0–1.55.2 |
| [`agent-rules-plan.md`](agent-rules-plan.md) | Agent-facing text: rules, skill, prompts, tool descriptions, server instructions (AR-E/AR-F/AR-D4 never scheduled; see the backlog) | 1.53.0 |
| [`claude-mcp-client-check.md`](claude-mcp-client-check.md) | The manual Claude Code client check that `script/mcp_compat/claude_client_check.rb` automates | 1.54.1–1.55.0 |
| [`ui-dashboard-plan.md`](ui-dashboard-plan.md) | The operator UI master plan: sections, roles, guardrails, change sets, release order | 1.53.0–1.73.0 |
| [`ui-1-plan.md`](ui-1-plan.md) | UI-1: app shell, design system, guest role, CSP enforced | 1.56.0 |
| [`ui-4a-plan.md`](ui-4a-plan.md) | UI-4a: change sets, merge snapshots, undo | 1.57.0 |
| [`ui-5-plan.md`](ui-5-plan.md) | UI-5: Review & Fix | 1.58.0 |
| [`ui-2-plan.md`](ui-2-plan.md) | UI-2: editable MCP allowlists, `bin/up` LAN detection, Home | 1.58.3, 1.59.0 |
| [`ui-3-plan.md`](ui-3-plan.md) | UI-3: Search | 1.60.0 |
| [`ui-4b-plan.md`](ui-4b-plan.md) | UI-4b: Explore | 1.61.0 |
| [`ui-6-plan.md`](ui-6-plan.md) | UI-6: Projects & Data | 1.62.0 |
| [`ui-7-plan.md`](ui-7-plan.md) | UI-7: System | 1.63.0 |
| [`mcp-sdk-1.8.2-plan.md`](mcp-sdk-1.8.2-plan.md) | `mcp` 1.8.2, CORS from the allowlist, scan hardening | 1.58.1–1.58.3 |
| [`fact-supersede-plan.md`](fact-supersede-plan.md) | Fact supersede | 1.64.0 |
| [`d6-cleanup-plan.md`](d6-cleanup-plan.md) | D-6 transition-shim removal and the MCP audit actor | 1.65.0 |
| [`f3-scan-chunking-plan.md`](f3-scan-chunking-plan.md) | Project scan input split to fit the context window | 1.66.0 |
| [`agent-cli-backend-plan.md`](agent-cli-backend-plan.md) | The opt-in agent-CLI LLM backend: router, anonymizer, cloud gate, host bridge | 1.67.0–1.71.0 |
| [`mcp-sdk-1.9.0-plan.md`](mcp-sdk-1.9.0-plan.md) | `mcp` 1.9.0, tool titles, the query cap | 1.72.0 |
| [`f3b-scan-profiling-plan.md`](f3b-scan-profiling-plan.md) | Scan profiling and tuning | 1.73.0 |
| [`f2a-scheduled-run-design.md`](f2a-scheduled-run-design.md) | Run every scheduled job now | 1.81.0 |
| [`f2b-same-fact-design.md`](f2b-same-fact-design.md) | The same-fact ladder | 1.82.0 |
| [`f2c-llm-keywords-design.md`](f2c-llm-keywords-design.md) | LLM words for facts that name no entity | 1.83.0 |
| [`cleanup-live-jobs-plan.md`](cleanup-live-jobs-plan.md) | Live Background jobs page, step progress bar, F2c minors | 1.84.0 |

Removed as noise (still in git history): the chores D-1–D-3 step list (1.55.3) and the F2a, F2b and F2c
task-by-task implementation plans (their designs above keep the decisions).
