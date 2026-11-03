# Agent-CLI LLM backend → graph_mem 1.67.0–1.71.0: a second, opt-in way to reach a model

**Written 2026-11-03 (Europe/Rome)** for Claude, from `main` at `3336473` (#147 merged, **1.66.0**). Every file:line
in "What the code looks like today" was checked against that commit. If a line has moved, find the code by the quoted
text. If the code no longer matches the description, **stop and ask Steve** instead of improvising. Only code was
read while writing this plan. **No spec was run.**

Context: today every LLM call in graph_mem goes through `SummaryGenerationClient` to a local Ollama (or an
OpenAI-compatible server). This train adds an **opt-in** second backend: an agent CLI (Claude Code, Devin, …) run on
the operator's workstation behind a small host-side HTTP bridge, with the data anonymized and a per-project
`cloud_allowed` gate. It is five PRs. **This plan details PR1 only** (a provider abstraction with no behaviour
change); PR2–PR5 get one-paragraph scopes and will each get their own step list before they start.

## Hard rules (the whole train)
- **No new MCP tool**, no new or changed tool argument or description; the default `/mcp` stays at **12** (readonly 9,
  maintenance 22, 22 classes); `spec/fixtures/mcp/snapshots/*.json` stay byte-identical in every PR.
- **Ollama stays the default.** With no new configuration, every request, prompt and result is **byte-identical** to
  today's, in every PR.
- **`cloud_allowed` defaults to false** (PR2). No project's data goes to a cloud model until the operator allows it
  for that project.
- **Never staleness by age**: no PR reads or compares timestamps to decide what is stale, missing or obsolete.
- The Rails app **never spawns a process** and never runs a CLI: it talks HTTP to the bridge on `127.0.0.1` (PR4).
- Synthetic data only in specs and docs (`SynthWidget`, `Alpha Service`, `Gadget Project`); never a real graph, a
  real project folder, a real model call, or a real host, user or home path. Generic paths only (`<project root>`,
  `/path/to/…`, `~/.config/graph_mem/…`).

## The train

| PR | Branch (suggested) | Scope | Depends on | Version |
|---|---|---|---|---|
| **PR1** | `claude/llm-provider-abstraction` | Provider abstraction, **no behaviour change**: `Llm::Provider`, `Llm::OllamaProvider`, `Llm::Router`, `Llm::Registry`, prompt parts, one usage log line per call, spec-side `FakeProvider` and `SubprocessGuard` | `main` (1.66.0) ✅ | **1.67.0** |
| **PR2** | `claude/llm-anonymizer` | Anonymizer (typed HMAC tokens) + `cloud_allowed` per project (default false) + the gate that refuses a cloud provider for a project that doesn't allow it | PR1 | **1.68.0** |
| **PR3** | `claude/llm-bridge` | Host bridge + profile framework + `devin` and `claude` profiles + the per-profile lockdown gate, all under `script/llm_bridge/` (not loaded by Rails) | `main` only; can run **in parallel** with PR1–PR2 | **1.69.0** |
| **PR4** | `claude/agent-cli-provider` | `Llm::AgentCliProvider` (HTTP to the bridge) + `Llm::ResponseNormalizer` + per-task fallback chains + settings + a probe | PR2, PR3 | **1.70.0** |
| **PR5** | `claude/llm-switch-over` | Per-task switch-over, the inline gate, an `llm_cloud` queue, budgets and an `llm_usage` table, adopter docs | PR4 + a **PASS** lockdown gate per profile on Steve's workstation | **1.71.0** |

PR3 touches no Rails code, so it can be reviewed and merged before, between or after PR1 and PR2; its version
number follows merge order (if it merges first it takes 1.67.0 and the others shift by one).

### What Steve does on his workstation (not in CI)
- **After PR3 merges:** install the bridge (it runs as the workstation user by default; a dedicated low-privilege
  user is optional hardening); for **each profile on each workstation** run the lockdown test
  (`script/llm_bridge/lockdown_test.sh --profile <name>`) and keep its PASS/FAIL report as `gates/<profile>.json`;
  capture one **sanitized** JSON envelope per profile as a spec fixture (PR4 needs it); set the CLI vendor's
  data-sharing opt-out where one exists; answer the synthetic-HOME question per CLI (PR3 Decision).
- **After PR4 merges:** set `LLM_BRIDGE_URL` and `LLM_BRIDGE_TOKEN` in the app's environment and run the probe
  (System → Summarization, or the rake task PR4 adds). Nothing switches over yet.
- **After PR5 merges:** turn on a chain per task and a budget, allow cloud for the projects that may use it, and
  **re-run the lockdown gate after every CLI update** (a stale or failed gate disables that profile).

## What the code looks like today (verified at `3336473`)

### The client
`app/services/summary_generation_client.rb` (182 lines) is a singleton (`instance` :24-26, `delegate :generate,
:check_connection` :28, `reset_instance!` :34, called by `settings_group_update.rb:43` when the summaries settings
change).
- `generate(prompt, style:, options: {})` (:67-87). Options: `num_ctx`, `num_predict`, `format`, `truncate`,
  `timeout`, `max_output_length` (default `MAX_OUTPUT_LENGTH` = 8_192 characters, :10).
- It returns a **Hash**: `{ ok:, text:, error:, latency_ms:, prompt_tokens:, done_reason: }`, plus `http_status:` on an
  HTTP failure (`GenerationError` :14-21). The "prompt is blank" failure has no `latency_ms`.
- Two transports: `request_ollama` (:114-131) and `request_openai_compatible` (:134-149, sends `num_predict` as
  `max_tokens`, reads `finish_reason`; ignores `format`, `num_ctx` and `truncate`), both through `perform_request`
  (:151-169).
- `check_connection` (:90) has no caller in `app/`; `home_snapshot/health.rb:31` probes Ollama with its own
  `Net::HTTP`.

`app/services/summarization_config.rb`: `DEFAULTS` (:5-13), `ALLOWED_PROVIDERS` (:15: `ollama`,
`openai_compatible`), `NUM_CTX_RANGE` (:17), `llm_usable?` (:88-94).

### The call sites (5 paths, 3 `generate` calls)
| Id | Path | `generate` call | Options |
|---|---|---|---|
| G1 | `summarize` MCP tool → `SummarizerService.call` (`summarize_tool.rb:51`) | `summarizer_service.rb:428` `SummaryGenerationClient.generate(prompt, style: @style)` | **none** (so the defaults, incl. the 8,192-char cut) |
| G2 | REST `POST /api/v1/summaries` → `SummarizerService.call` (`summaries_controller.rb:13`) | same as G1 | same |
| G3 | Project scan (job `project_scan_job.rb`, queue `default`) → `ProjectScanner::LlmExtraction` → `ChunkedExtraction#extract` | `chunked_extraction.rb:87`, **one call per part**: up to `project_scan_max_chunks` (16) parts, each split once on failure, so up to ~32 calls per scan | `request_options` (:96-98): `num_ctx`, `num_predict`, `format: "json"`, `truncate: false`, `timeout` (`max(summary_timeout, 120)`, `llm_extraction.rb:30`), `max_output_length: nil` |
| G4 | `FactSupersedeJob` (`fact_supersede_job.rb:19`, queue `low_priority`, one per fact) → `Proposals.call(fact)` → `Judge.call` | `judge.rb:70-71` `@client.generate(prompt(batch), style: "concise", options: …)` | `num_ctx`, `num_predict: 1536`, `format: "json"`; **no** `max_output_length`, so the 8,192-char cut applies |
| G5 | `detect_contradictions` MCP tool, `mode: "outdated_by_fact"` (`detect_contradictions_tool.rb:115`) → `Proposals.call(…, max_batches: FACT_MODE_JUDGE_BATCHES)` (= 2) → `Judge.call` | same as G4, **inline** in the MCP request | same as G4 |

Supporting code:
- `summarizer_service.rb`: `attempt_llm_synthesis` (:421-441) checks `SummarizationConfig.llm_usable?` (:422), sets
  `generated_by` from `resolved_config[:model]` (:433) and `fallback_reason` from `result[:error]` (:440, visible to
  agents); `build_prompt` (:472-503) puts the evidence at :498.
- `project_scanner/llm_extraction.rb` (166 lines): `llm_usable?` at :131; a resume makes no LLM call.
- `project_scanner/extraction_prompt.rb` (97 lines): `INSTRUCTIONS` (:15-46), `text` (:56-64), `parse_json` (:76-84),
  `names_line` (:86-94).
- `project_scanner/chunked_extraction.rb` (137 lines): `failure` (:100-109) reads `http_status` 400/413,
  `done_reason == "length"` and `prompt_tokens` to decide a split. Part sizes come from `summary_num_ctx`.
- `fact_supersede/judge.rb` (171 lines): `self.call(fact, candidates, client: SummaryGenerationClient, max_batches:
  nil)` (:48), `llm_usable?` (:60), prompt (:131-154). `fact_supersede/proposals.rb`: `self.call(fact, terms:, limit:,
  seed:, max_batches:)` (:42), `Judge.call` (:65), `llm_usable?` (:88).
- `token_budget.rb:9` `CHARS_PER_TOKEN = 4`. `config/queue.yml` runs `queues "*"` with 3 threads.

### Specs that pin today's behaviour
- About 25 class-level stubs `allow(SummaryGenerationClient).to receive(:generate)` in `summarizer_service_spec` (11),
  `project_scanner_spec` (6), `project_scan_job_spec` (3; :121 reads `options[:options]` from a `|prompt, **options|`
  block), `chunked_extraction_spec`, `summaries_spec`, `detect_contradictions_tool_spec`. None uses `.with(…)`.
- `judge_spec` stubs `Net::HTTP`, calls `reset_instance!`, and asserts the request body (`format` json, `num_ctx` 8192,
  `num_predict`).
- `spec/support/outbound_http_guard.rb` allows loopback except port 11434.
- Subprocesses in specs: `spec/bin/up_spec.rb:58,145,150` (Open3), `spec/docs/agent_text_sync_spec.rb:34`
  (backticks). There is no `Open3`, `system`, `spawn` or backtick in `app/` or `lib/`.

### Where the earlier design notes and `main` disagree (read before coding)
1. **The scan is chunked now (F-3).** G3 is not "one call per scan": it is up to 16 parts plus split retries, with
   its own options and the prompt in `ExtractionPrompt`. PR4/PR5 budgets and the bridge's one-at-a-time lock must
   count ~32 calls per scan.
2. **The result has more keys.** `prompt_tokens`, `done_reason` and `http_status` are read by `ChunkedExtraction`. A
   `Data.define` result object would drop them and break every `result[:ok]` caller and stub. **PR1 keeps a Hash**,
   a superset of today's (it adds `provider` only).
3. **The singleton.** Wrapping `SummaryGenerationClient.instance` in the provider would bypass the ~25 class-level
   stubs and `reset_instance!`. `Llm::OllamaProvider` calls `SummaryGenerationClient.generate` (class level) on every
   call.
4. **`openai_compatible`** now honours `num_predict` and `timeout`, still ignores `format`, `num_ctx`, `truncate`.
   PR1 names the provider `ollama` for both transports; nothing about them changes.
5. **The 8,192-character cut** still applies to G1/G2 and to the judge (G4/G5). An agent CLI's JSON envelope can be
   larger: PR4's normalizer must unwrap the envelope before any cut.
6. **A global subprocess guard** would break `up_spec` and `agent_text_sync_spec`; it is scoped to callers in `app/`
   and `lib/`. Because the app only talks HTTP to the bridge, the guard is a forward guard: it makes sure that stays
   true.
7. **Chunk sizes follow `summary_num_ctx`**, an Ollama window. How a cloud model's window sizes the parts, and
   whether a failed part may fall back to another provider mid-scan, are PR4/PR5 decisions.
8. **400/413 split semantics** (`chunked_extraction.rb:100-109`) need a bridge equivalent (PR4: the bridge maps
   "prompt too long" to 413).
9. **Line numbers**: the settings reset is `settings_group_update.rb:43`, not :53; every other line has moved since
   the notes were written.
10. **"Three call sites"** is three `generate` calls but five paths; G5 reaches the judge through `Proposals`, and
    there is no `inline` flag today (PR1 adds an internal one).
11. **There is no `projects` table**: a project is a `memory_entities` row of type "Project", so `cloud_allowed`
    is a `memory_entities` column (PR2), not a projects column.

---

## PR1: provider abstraction, no behaviour change → 1.67.0

### Brief
| | |
|---|---|
| Branch / PR | `claude/llm-provider-abstraction`, **one PR**, titled "LLM provider abstraction (1.67.0)" |
| Commits | P0 → A1 → A2 → A3 → A4 → T → D → R, one commit per step (more is fine, fewer is not). **D and R are in this PR**, not a follow-up |
| Version | **1.67.0** (Decision 1) |
| Data | synthetic only; stubbed `generate` or `Net::HTTP`; never a real model call |
| Read first | `CLAUDE.md`, `AGENTS.md`; this plan; `docs/summarization.md`; `docs/architecture.md` (summaries, project scans, fact supersede) |
| MCP surface | **unchanged** (22 / 12 / 9 / 22; snapshots byte-identical) |
| Migration / settings | **none** / **none** |

### Goal
- One seam, `Llm::Router`, through which every LLM call in `app/` goes, so PR4 can add a provider without touching
  the call sites again.
- Every request body, prompt string and result Hash is **byte-identical** to today's (characterization specs prove
  it before and after).
- One log line per call that says which task, which provider and how much, never the prompt or the answer.
- Specs can swap in a fake provider, and fail if app code ever starts a process.

### Non-goals
- Any new provider, the anonymizer, `cloud_allowed`, the bridge, a setting, a migration, a queue, a budget.
- Changing `SummaryGenerationClient`, its options, its 8,192-char cut, or either transport.
- `home_snapshot/health.rb`'s probe and `check_connection` (left as they are; PR4 adds the probe).

### Design
`app/services/llm/` (YARD on every public method; files under ~500 lines, methods under ~60):

- **`Llm::Provider`** (base): `name` (String), `generate(prompt, style:, options: nil)` → Hash, `available?`,
  `cloud?` (false). Documented contract: the returned Hash has at least `ok`, `text`, `error`, `latency_ms`, and may
  carry `prompt_tokens`, `done_reason`, `http_status`.
- **`Llm::OllamaProvider`** (`name` "ollama", covers both `SummaryGenerationClient` transports):
  `SummaryGenerationClient.generate(prompt, style: style)` when `options` is nil, else
  `SummaryGenerationClient.generate(prompt, style: style, options: options)`, so each call site's call shape and
  every existing stub stay exact. `available?` delegates to `SummarizationConfig.llm_usable?`.
- **`Llm::Registry`**: `fetch(:ollama)` → the provider; `Llm::Registry.override(name, provider)` for specs only
  (reset after each example by the spec helper).
- **`Llm::Router`**:
  - `generate(task, prompt, style:, options: nil, inline: false)`; `task` ∈ `:summary`, `:scan`, `:judge`
    (an unknown task raises `ArgumentError`).
  - The chain is hard-wired to `[:ollama]` in PR1. With a one-element chain the Router returns the provider's Hash
    **unchanged except for one added key, `provider: "ollama"`**; error strings are not rewritten (the summarizer
    shows them as `fallback_reason`).
  - `usable?(task)` delegates to `SummarizationConfig.llm_usable?` (PR4 makes it per task).
  - `client(task, inline: false)`: a tiny adapter object that responds to `generate(prompt, style:, options:)` and
    calls `Router.generate(task, …)`; it becomes `Judge.call`'s default `client:`.
  - Writes the usage line (below) after each call, also on failure; a logging error never fails the call.
- **`Llm::Prompt`**: an ordered list of segments, each `trusted` (instructions written by us) or `data` (evidence,
  file contents, observation text, names). `to_s` joins them **byte-identically** to today's strings. PR2's
  anonymizer will rewrite only `data` segments. Used by `SummarizerService#build_prompt`,
  `ExtractionPrompt.text` and the judge's `prompt`, each still returning a String to its caller.
- **`Llm::UsageLog`**: one `Rails.logger.info` line per call, prefix `[llm]`, JSON: `task`, `provider`, `model`
  (`resolved_config[:model]`), `inline`, `prompt_chars`, `est_in_tokens` (`TokenBudget::CHARS_PER_TOKEN`),
  `out_chars`, `est_out_tokens`, `latency_ms`, `outcome` (`ok` / `error`), plus `prompt_tokens` when present.
  **Never** the prompt, the answer, an error body or a project name.
- **Inline flag:** `Proposals.call` gains `inline: false`, passed to `Judge.call(…, client: Llm::Router.client(:judge,
  inline: inline))`; `detect_contradictions_tool.rb:115` passes `inline: true`. Internal Ruby keyword only: the tool's
  arguments, description and snapshot don't change. PR5 uses it (inline calls never wait on a cloud queue).
- **Spec support** (`spec/support/llm.rb`): `FakeProvider` (records calls, returns a canned Hash or a block's Hash)
  and `with_llm_provider(fake) { … }`; `SubprocessGuard` that, around every example, makes `Open3.*`,
  `Kernel#system`, `Kernel#spawn`, `Process.spawn`, `IO.popen` and backticks raise when the **caller** is a file
  under `app/` or `lib/` (spec and `bin/` callers pass, so `up_spec` and `agent_text_sync_spec` stay green).

### Steps

#### P0. Characterization specs (first commit, on unchanged code)
- `spec/services/llm/characterization_spec.rb` (or one per call site), all with `Net::HTTP` stubbed as
  `summary_generation_client_spec.rb` does:
  - G1: the exact prompt String for a synthetic `SynthWidget` evidence set, and the exact Ollama request body
    (no `options` beyond today's defaults).
  - G3: the exact prompt for part 1 of 2 and part 2 of 2 of a `Dir.mktmpdir` tree, and the exact body
    (`num_ctx`, `num_predict`, `format`, `truncate: false`), plus the result keys `ChunkedExtraction` reads.
  - G4/G5: the exact judge prompt and body for one batch.
  - The same G1/G3/G4 bodies under `openai_compatible`.
- Golden strings live in the spec (or `spec/fixtures/llm/*.txt`); they must pass on `main` **before** A1.

#### A1. `Llm` core
- `Provider`, `OllamaProvider`, `Registry`, `Router` (with `usable?` and `client`), `UsageLog`, with unit specs:
  pass-through of every key, `provider` added, options passed only when given, an unknown task raises, the log line
  has the fields and none of the forbidden ones (grep the line for the synthetic prompt text), a failing logger
  doesn't fail the call.
- Not wired to any call site yet.

#### A2. Prompt parts
- `Llm::Prompt` with `trusted`/`data` segments; `SummarizerService#build_prompt`, `ExtractionPrompt.text` and
  `Judge#prompt` build one and return `to_s`. P0's golden strings stay green unchanged.

**Checkpoint 1:** P0–A2 pushed, CI green, a **draft PR** open. Paste in the PR the P0 golden prompt for G1 and the
`[llm]` line from an A1 spec. Stop for Steve's review.

#### A3. Route the call sites
- `summarizer_service.rb:422/428` → `Llm::Router.usable?(:summary)` / `Llm::Router.generate(:summary, prompt,
  style: @style)`.
- `llm_extraction.rb:131` → `Llm::Router.usable?(:scan)`; `chunked_extraction.rb:87` →
  `Llm::Router.generate(:scan, prompt, style: "concise", options: request_options)`.
- `judge.rb:48` default `client: Llm::Router.client(:judge)`; `judge.rb:60` and `proposals.rb:88` →
  `Llm::Router.usable?(:judge)`; `Proposals.call(…, inline: false)`; `detect_contradictions_tool.rb:115` passes
  `inline: true`. `FactSupersedeJob` is unchanged (inline false).
- `settings_group_update.rb:43` keeps `SummaryGenerationClient.reset_instance!` (no Router state to reset in PR1).
- Every existing spec green **unchanged**, P0 green.

#### A4. Fake provider and subprocess guard
- `spec/support/llm.rb` as in Design; one example per call site (G1, G3, G4, G5) using `FakeProvider` instead of a
  `SummaryGenerationClient` stub, asserting the task, the `inline` flag (true only for G5) and the result.
- `SubprocessGuard` spec: a call from a temp file under `app/` raises; a call from a spec passes; `up_spec` and
  `agent_text_sync_spec` green.

**Checkpoint 2:** A3–A4 pushed, CI green. Paste the four call-site examples' output and the `[llm]` lines of one
scan with two parts. Stop for Steve's review.

#### T. Specs (beyond the ones per step)
- Payload parity: P0 green; a `git diff` of the P0 golden files empty since P0.
- Architecture spec: in `app/`, `SummaryGenerationClient.generate` is called only from `llm/ollama_provider.rb`
  (grep the tree); no `Open3`, `system(`, `spawn(`, backtick or `IO.popen` in `app/` or `lib/`.
- MCP surface: `mcp_tool_registry_spec.rb`, `mcp_official_spec.rb`, `mcp_structured_output_stdio_spec.rb` counts
  unchanged (22 / 12 / 9 / 22); `spec/mcp/tools_list_snapshot_spec.rb` green **without** re-recording; `git diff
  spec/fixtures/mcp/snapshots` empty. `git diff db/structure.sql` empty.

#### D. Docs
- `docs/summarization.md`: an "LLM providers" section: the Router, the three tasks, today's single provider, the
  `[llm]` log line and its fields (and that it never logs prompts), the plan for the train (one paragraph, linking
  this file).
- `docs/architecture.md`: the `app/services/llm/` layer between the three call sites and `SummaryGenerationClient`.
- `docs/plans/ui-dashboard-plan.md`: row AC1 ✅ with the PR number.
- Generic paths only, no host or user names.

#### R. Release
- `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` (`graph-mem-version:`) → **1.67.0**.
- `CHANGELOG.md` `## [1.67.0] - <merge date>`, summary "One internal seam for every LLM call":
  - **Added:** `Llm::Router` and `Llm::OllamaProvider` (every summary, scan part and fact-supersede judgement goes
    through them); one `[llm]` info log line per call (task, provider, model, sizes, latency, outcome; never the
    prompt).
  - **Changed:** nothing visible: requests, prompts and results are unchanged.
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** T, D, R pushed, CI green; mark the PR ready for review.

### Security checklist
- The usage line never contains prompt text, answers, error bodies, project or entity names (spec'd).
- No new outbound connection, no new process (architecture spec + `SubprocessGuard`).
- Prompt segments are labelled but rendered exactly as today; nothing from a model answer is executed or used as a
  path.

### Size
About **500–700 changed lines** (over half specs): P0 ~150, A1 ~200, A2 ~80, A3 ~60, A4 ~120, T ~60, D ~40, R ~15.
**If the diff passes ~1,000 lines, stop and ask Steve.**

### Decisions (open, with the recommended default)
1. **Version.** *Default:* **1.67.0** (new internal layer and a new log line; the train's first release).
   Alternative: 1.66.1.
2. **Result type.** *Default:* the **Hash** superset of today's (adds `provider` only). Alternative: a `Data` object
   with `[]` (more code, every stub to touch, no gain yet).
3. **Tasks.** *Default:* `:summary`, `:scan`, `:judge` plus an `inline:` flag. Alternative: a separate
   `:judge_inline` task (a fourth chain to configure in PR4).
4. **Prompt parts in PR1.** *Default:* yes, rendered byte-identically, so PR2 only adds the anonymizer.
   Alternative: leave the prompts as Strings until PR2.
5. **Usage log.** *Default:* `info` level, JSON, no prompt. Alternative: `debug` (invisible in production logs).
6. **`FakeProvider` location.** *Default:* `spec/support`. Alternative: `app/services/llm/` (a test double shipped in
   production code).
7. **`SubprocessGuard` in PR1.** *Default:* yes, scoped to callers in `app/` and `lib/`. Alternative: add it in PR4
   with the bridge client.
8. **`usable?(task)` seam.** *Default:* yes: the four `llm_usable?` checks go through the Router now (PR4 makes them
   per task). Alternative: keep `SummarizationConfig.llm_usable?` at the call sites until PR4.
9. **Provider name.** *Default:* `"ollama"` for both transports (`openai_compatible` included). Alternative: report
   `resolved_config[:provider]` (more accurate, but then the name changes with a setting).

### Acceptance criteria
- Every LLM call in `app/` goes through `Llm::Router`; `SummaryGenerationClient.generate` is called only by
  `Llm::OllamaProvider`.
- P0's golden prompts and request bodies are unchanged after A3 for both transports; each result Hash equals
  today's plus `provider: "ollama"`.
- Every existing spec is green **without edits** (apart from added examples).
- One `[llm]` line per call, with the listed fields and no prompt or answer text.
- `detect_contradictions` passes `inline: true` internally; its arguments, description and snapshot are unchanged.
- MCP: 22 / 12 / 9 / 22, snapshots byte-identical; no migration, no setting.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) green; files under ~500 lines, methods
  under ~60. Synthetic data only.

### Stop and ask Steve if
- Anything would add an MCP tool, change a tool's arguments or description, or change an MCP snapshot.
- A P0 golden string or request body has to change, or an existing spec has to be edited to pass.
- A quoted line no longer matches the code (`attempt_llm_synthesis`, `ChunkedExtraction#extract`,
  `Judge#judge_batch`, `Proposals.call`).
- The design needs a migration, a setting, a gem, a job or a queue.
- `SubprocessGuard` can't be scoped without breaking `up_spec` or `agent_text_sync_spec`.
- The diff passes ~1,000 lines.

---

## Later PRs (scopes; each gets its own step list)

**PR2: anonymizer + `cloud_allowed` (1.68.0).** There is no `projects` table: a project is a `memory_entities` row
with `entity_type` "Project" (`node_operations_strategy.rb:14`). A migration adds `cloud_allowed` (boolean, default
**false**, not null) to `memory_entities`, read only for Project entities and editable on the project page (operator
only, a confirm); its plan decides how a task finds its project (scan: the scanned project; judge: the fact's
project; summary: every project in the evidence must allow it). `Llm::Anonymizer` rewrites only the
`data` segments of an `Llm::Prompt`: entity names, aliases, file paths, e-mail addresses, hosts, URLs and anything
token-like become typed HMAC tokens (`⟦ENT_xxxx⟧`, `⟦PATH_xxxx⟧`, …) keyed by a per-install secret, and the answer is
de-tokenized before any caller sees it; unknown tokens in an answer are dropped, never guessed. The Router refuses a
provider with `cloud?` true when the task's project (or any project in a summary's evidence) doesn't allow cloud,
and falls through to the next provider in the chain (in PR2 there is none, so nothing changes). Specs: round trips,
no raw synthetic name in an anonymized prompt, the gate. No MCP change.

**PR3: host bridge + profiles + lockdown gate (1.69.0).** Everything under `script/llm_bridge/`, outside the Rails
load path, Python stdlib and POSIX shell only, no new gem. A **bridge** listening on `127.0.0.1` only, requiring an
`X-GM-Bridge-Token` header (read from a token file with `0600` permissions), one request at a time per profile, a
hard timeout and an output cap (256 KiB); it maps CLI outcomes to HTTP (timeout, killed, refused by the gate, bad
profile, CLI missing, "prompt too long" → 413). A **wrapper** runs one CLI non-interactively from a **profile**
(`profiles/<name>.json`: binary, flags that turn off every tool, MCP server and file access, prompt on stdin, the
envelope fields to read, which env vars pass through, the HOME policy), with a `--check` mode and a `--test-seed`
mode. A **deny hook** logs and refuses any tool call. The **lockdown test** (`lockdown_test.sh --profile --models
--listen-ip`) plants a canary file and decoy secrets, asks the CLI to read, list, fetch and run things, checks for
the markers, checks nothing new listens, and writes `gates/<profile>.json` (PASS/FAIL, CLI version, date); the bridge
refuses a profile whose gate is missing, failed or for another CLI version. Profiles: `claude` and `devin`. **Gate /
decision: does each CLI accept a synthetic HOME?** *Default:* a synthetic, empty HOME per run for `claude`; for
`devin` Steve's check on his workstation decides; a CLI that needs the real HOME gets `env.home: real` in its profile,
the strongest neutralizing flags it has, and the lockdown report lists that as a WARN. The run-as model: the
workstation's own user by default; a dedicated low-privilege user optional. Docs: install, the token file, running
the gate. Specs: bridge unit tests run with a fake CLI script only.

**PR4: `AgentCliProvider` + normalizer + chains (1.70.0).** `Llm::AgentCliProvider` (`cloud?` true) posts to
`LLM_BRIDGE_URL` with `LLM_BRIDGE_TOKEN` (env only, never a setting or log line; loopback only, enforced), and
`Llm::ResponseNormalizer` unwraps the CLI's JSON envelope (`result` / `is_error` for `claude`, per profile), strips
fences and chatter around JSON answers, applies the caller's `max_output_length` **after** unwrapping, and maps
bridge errors to today's result keys (413 → `http_status` 413 so the scan still splits). Settings: `llm_chain_summary`,
`llm_chain_scan`, `llm_chain_judge` (default `ollama` each, so nothing changes), the bridge profile per provider, and
a probe (System → Summarization and a rake task) that reports reachability, profile and gate status. Decisions for
its plan: how a cloud window sizes scan parts; whether a failed scan part may fall back to the next provider
mid-scan; whether the judge's 8,192-char cut is lifted. Specs use the PR3 sanitized envelope fixtures and a stubbed
bridge.

**PR5: switch-over (1.71.0).** Per-task switch-over behind the chains (still `ollama` by default); the inline gate (an
inline call, i.e. `detect_contradictions`, never waits on the cloud: it uses Ollama or returns unjudged, the job
picks up the rest); an `llm_cloud` Solid Queue queue with one thread so cloud calls run one at a time; per-task and
daily budgets (calls and estimated tokens) with a hard stop; an `llm_usage` table (one row per call, the `[llm]`
fields, no prompt) and a small usage card on System; adopter docs (how to enable a chain for one project, what leaves
the machine, how to turn it off). Starts only after PR4 and a **PASS** gate for each profile it enables.
