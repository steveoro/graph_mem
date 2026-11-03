# Agent-CLI LLM backend → graph_mem 1.67.0–1.71.0: a second, opt-in way to reach a model

**Written 2026-11-03 (Europe/Rome)** for Claude, from `main` at `3336473` (#147 merged, **1.66.0**). Every file:line
in "What the code looks like today" was checked against that commit. If a line has moved, find the code by the quoted
text. If the code no longer matches the description, **stop and ask Steve** instead of improvising. Only code was
read while writing this plan. **No spec was run.**

Context: today every LLM call in graph_mem goes through `SummaryGenerationClient` to a local Ollama (or an
OpenAI-compatible server). This train adds an **opt-in** second backend: an agent CLI (Claude Code, Devin, …) run on
the operator's workstation behind a small host-side HTTP bridge, with the data anonymized and a per-project
`cloud_allowed` gate. It is five PRs. **This plan details PR1** (a provider abstraction with no behaviour
change; done, #151, 1.67.0) **and PR2** (the anonymizer and `cloud_allowed`, written Nov 3 from `d779aff`); PR3–PR5
get one-paragraph scopes and will each get their own step list before they start.

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
| **PR1** | `claude/llm-provider-abstraction` | Provider abstraction, **no behaviour change**: `Llm::Provider`, `Llm::OllamaProvider`, `Llm::Router`, `Llm::Registry`, prompt parts, one usage log line per call, spec-side `FakeProvider` and `SubprocessGuard` | `main` (1.66.0) ✅ #151 | **1.67.0** |
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

## PR2: anonymizer + `cloud_allowed` → 1.68.0

**Written 2026-11-03 (Europe/Rome)** from `main` at `d779aff` (#151 merged, **1.67.0**). Every file:line below was
checked against that commit; if a line has moved, find it by the quoted text; if the code no longer matches, **stop
and ask Steve**. Only code was read; **no spec was run**.

### Brief
| | |
|---|---|
| Branch / PR | `claude/llm-anonymizer`, **one PR**, titled "LLM anonymizer (1.68.0)" |
| Commits | M → A1 → A2 → A3 → U → T → D → R, one commit per step (more is fine, fewer is not). **D and R are in this PR** |
| Checkpoints | **push and continue**: push, get CI green, keep going; Steve reviews as it lands. Stop only for the conditions in "Stop and ask Steve if" |
| Version | **1.68.0** (Decision 1) |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, `Zq7Canary…` canaries); never a real model call |
| Read first | `CLAUDE.md`, `AGENTS.md`; this plan (hard rules, PR1); `docs/summarization.md` ("LLM providers"); `app/services/llm/*`; `spec/support/llm.rb` |
| MCP surface | **unchanged** (22 / 12 / 9 / 22; snapshots byte-identical); no tool gains or loses an argument |
| Migration / settings | **one** migration (`cloud_allowed` on `memory_entities`) / **none** |

### Goal
- Before any prompt reaches a provider with `cloud?` true, the Router rewrites its **data** segments so that no
  project or entity name, alias, path, host, URL, e-mail, IP, username or secret-looking string leaves the app, and
  restores the answer before any caller sees it.
- A per-project `cloud_allowed` flag (default **false**) that the Router checks on every cloud call; a refused call
  never reaches the provider.
- All of it provable today with a `FakeProvider` flagged as cloud (no cloud provider exists until PR4).
- With no configuration, nothing changes: the only provider is still Ollama, `cloud?` false, and every request,
  prompt, result, log line and REST/MCP output is **byte-identical** to 1.67.0's.

### Non-goals
- Any real cloud provider, the bridge, the fallback chain settings, budgets (PR3–PR5).
- Settings for custom regex patterns or allow/deny lists (the detectors are built in; a setting group can come with
  PR4 if Steve wants one).
- A structural outline instead of raw code for scans (notes option 2); a stricter "keep scans local" switch beyond
  `cloud_allowed` itself.
- Any change to the Ollama path, `SummaryGenerationClient`, prompts' rendered text or the P0 goldens.

### What the code looks like today (verified at `d779aff`)

**The Router takes a String.** `app/services/llm/router.rb:39-47`:
`def generate(task, prompt, style:, options: nil, inline: false)` → `provider = Registry.fetch(CHAIN.first)` →
`provider.generate(prompt, style: style, options: options).merge(provider: provider.name)`, with
`UsageLog.record(task:, provider:, inline:, prompt:, result:)` in an `ensure`. `CHAIN = %i[ollama]` (:17),
`usable?(task)` (:53), `client(task, inline: false)` (:62) returns `Client = Data.define(:task, :inline)` whose
`generate(prompt, style: "concise", options: nil)` (:26) calls `Router.generate`.

**Every call site renders the Prompt before the Router sees it**, so today the segments are lost at the seam:
- `summarizer_service.rb:490` `build_prompt(evidence)` builds an `Llm::Prompt` (`.data(@query)`, `.data(@style)`
  twice, per evidence entry `.trusted("\n- [observation_id=…, entity_id=…, entity=").data(entity.name)` and
  `.data(observation.content)`) and returns `prompt.to_s`; `:441-442` `prompt = build_prompt(evidence)` /
  `Llm::Router.generate(:summary, prompt, style: @style)`.
- `project_scanner/extraction_prompt.rb:59-65` `def text(files_text, part:, parts:, project_name:, names: [])`:
  `.data(project_name)`, `prompt.trusted(NAMES_PREFIX).data(kept.join("; "))`, `.data(files_text)`, then `.to_s`.
  `chunked_extraction.rb:85-87` calls `ExtractionPrompt.text(…, names: @merger.names(limit: MAX_NAMES))` and
  `Llm::Router.generate(:scan, prompt, style: "concise", options: request_options)`; `ChunkedExtraction.new(chunks:,
  project_name:, num_ctx:, num_predict:, timeout:, on_part: nil)` (:35) is built once per scan by
  `llm_extraction.rb:28-31` with `project_name: prompt_project_name` (`@project_name || File.basename(@project_root)`,
  :78-80). One `ChunkedExtraction` = one scan = up to 16 parts plus splits.
- `fact_supersede/judge.rb:158-162` `def prompt(batch)`: `.data(project_name(@fact.memory_entity))`, `.data(fact)`
  (JSON), `.data(JSON.generate(batch.map { |candidate| statement(candidate) }))`, then `.to_s`; `:96`
  `@client.generate(prompt(batch), style: "concise", options: { …, format: "json" })`. `statement` (:164-171) puts
  each candidate's `entity.name` and `project_name(entity)` (or `"(no project)"`) in the JSON. `project_name` (:174-178)
  is the entity itself for a Project, else `entity.project&.name || "(no project)"`. Default client: `Judge.call(…,
  client: Llm::Router.client(:judge))` (:74); `proposals.rb:69` passes `Llm::Router.client(:judge, inline: true)`.

**`Llm::Prompt`** (`prompt.rb`): `initialize` takes no argument (:18), `trusted`/`data` return self, `segments` is a
copy, `to_s` joins (:40). **`spec/services/llm/prompt_segments_spec.rb:12`** wraps `Llm::Prompt.new` with
`and_wrap_original { |original, *args| … }` and reads `prompts.sole`: so `Prompt.new` must keep taking no keyword
and each summary/judge/scan-part call must still build **exactly one** `Llm::Prompt` (the anonymizer must not build
Prompts).

**`Llm::Provider#cloud?`** (`provider.rb:34`) returns false; nothing reads it yet. **`Llm::UsageLog.record`**
(`usage_log.rb:22`, fields at :29). **`Llm::Registry.override`** (`registry.rb:29-33`) raises outside the test env.

**`FakeProvider`** (`spec/support/llm.rb:16`, `initialize(name: "fake", available: true, result: DEFAULT_RESULT,
&answer)` at :34) has **no `cloud:` keyword**; `with_llm_provider(provider)` (:68) overrides `:ollama`.

**Projects.** No `projects` table: a project is a `memory_entities` row with `entity_type` "Project" and `project_id`
NULL (`node_operations_strategy.rb:14`, `memory_entity.rb:6-11`); members point at it via `project_id`. Columns
(`db/structure.sql`, `CREATE TABLE memory_entities`): `name`, `entity_type`, `aliases` (text, comma list),
`description`, `embedding`, `project_id`, `project_scope` (generated). Names are unique per scope, case-insensitive.

**How an entity is written today** (none of these may set `cloud_allowed`):
- MCP `graph_edit` → `GraphEditService#update_entity` (`graph_edit_service.rb:117-119`):
  `attributes.slice(:name, :entity_type, :aliases, :description)`.
- REST `api/v1/memory_entities_controller.rb:213`: `permit(:name, :entity_type, :aliases, :description)`; **but**
  `:93` and `:153` `render json: @memory_entity`, i.e. `MemoryEntity#as_json` (`memory_entity.rb:46-48`, excepts
  only `:embedding`), so a new column would **appear in REST output** unless excepted.
- Explore UI `explore/entities_controller.rb:24`: `permit(:name, :entity_type, :aliases, :description)`.
- Export `export_strategy.rb:147-148` lists fields explicitly; merge `node_operations_strategy.rb:98` `merge_into`.
- Audit: `Auditable` (`after_update :audit_update`) records every changed column. `ChangeSet::KINDS`
  (`change_set.rb:15-19`) is a closed list (plus `policy.*` / `explore.*` patterns).

**The Projects page** is an index only (`config/routes.rb:116-117` `get "projects"` + `namespace :projects`;
`ProjectsController#index`; `ProjectsOverview::Row = Data.define(:project, :last_scan, :last_import, :review_groups)`,
`projects_overview.rb:14`; table in `app/views/projects/index.html.haml`; strings in `config/locales/projects.en.yml`).
`Projects::BaseController` is operator only. There is **no project show page**: the toggle goes in the table.

### Design

#### 1. Prompts carry their scope; the Router gets the Prompt
- `Llm::Prompt#scoped(scope)` → self (stores an `Llm::Scope`); `#scope` reader. `Prompt.new` and `to_s` unchanged.
- The three call sites hand the Router the **Prompt object** instead of its String:
  - `SummarizerService`: `build_llm_prompt(evidence)` returns the scoped Prompt; `build_prompt` stays as
    `build_llm_prompt(evidence).to_s` only if something else calls it (today only :441 does; then fold it).
  - `ExtractionPrompt.build(…)` returns the Prompt; `text(…)` stays as `build(…).to_s` (prompt_segments_spec and the
    goldens call `text`). `ChunkedExtraction` calls `build(…).scoped(@llm_scope)`.
  - `Judge#prompt` returns the scoped Prompt (drop the `.to_s`); `judge_batch` passes it to `@client.generate`.
- `Router.generate` accepts a `String` or an `Llm::Prompt`. For a provider with `cloud?` false it does exactly what
  it does today with `prompt.to_s` (a String's `to_s` is itself): same provider call, same Hash, same `[llm]` line.
  `OllamaProvider` and every `SummaryGenerationClient` stub keep receiving a String.

#### 2. `Llm::Scope`: which projects a prompt touches
A small class (not `Data`: it memoizes), built **lazily** so the Ollama path runs no extra query:
- `Scope.for_entities(entities)`: each entity's project is itself if it is a Project root, else `project_id`; any
  entity with neither ⇒ `unscoped`. Summary: every evidence entity. Judge: the fact's entity **and every candidate's
  entity** (a `"(no project)"` candidate makes the call unscoped).
- `Scope.for_scan(project_name)`: the Project root whose name matches case-insensitively (`entity_type` "Project",
  `project_id` NULL), resolved on first use; none (a first scan, before reconcile creates it) ⇒ `unscoped`.
- `#session`: one `Llm::Anonymizer::Session`, built on first cloud use and kept for the Scope's life. Summary and
  judge build one Scope per call (one session per call); `ChunkedExtraction` builds **one Scope per scan**
  (`llm_scope:` keyword, default `Scope.for_scan(project_name)`), so every part and split of one scan shares one
  mapping, and names restored from part 1 re-mask to the same tokens in part 2's names line.

#### 3. `Llm::CloudGate`
`allowed?(scope)`: true only if the scope is present, not unscoped, names at least one project, and **every** id is
a Project root with `cloud_allowed` true (one `where(...).count` per call, never cached, so turning it off takes
effect on the next call, mid-scan included). No timestamps are read.

#### 4. Router cloud path (only when `provider.cloud?`)
1. Not an `Llm::Prompt` ⇒ refuse `prompt_not_segmented`.
2. `CloudGate.allowed?(prompt.scope)` false ⇒ refuse `cloud_not_allowed`.
3. `scope.session.mask(prompt)` ⇒ masked String + counts, or refuse `anonymizer_refused` (collision, detector
   timeout, dictionary over its cap, leftover hit).
4. Prepend one trusted instruction (cloud path only): "Tokens like ⟦ENT_1a2b⟧ stand for names, paths or
   addresses. Copy them exactly as written; never translate, split, merge or invent them."
5. `provider.generate(masked, style:, options:)`.
6. If `ok`: `session.unmask(text, json: options&.dig(:format) == "json")` ⇒ restored text, or the result becomes
   `ok: false, text: nil, error: "anonymization_round_trip_failed"`.
7. A refusal returns `{ ok: false, text: nil, error: <reason>, latency_ms: 0.0, provider: <name> }` **without calling
   the provider**, and the Router moves on to the next provider in `CHAIN` (PR2's chain is `[:ollama]`, so in
   production there is no cloud provider to refuse; PR4 fills the chain). Callers already handle `ok: false`:
   the summarizer shows `fallback_reason`, a scan part counts as failed (and the scan falls back to the
   deterministic extraction as today), the judge returns unjudged.
The cloud path lives in its own file (`app/services/llm/cloud_call.rb`) so `router.rb` stays small.

#### 5. `Llm::Anonymizer` (`app/services/llm/anonymizer/`: `session.rb`, `dictionary.rb`, `detectors.rb`, `tokens.rb`)
**What is masked:** `data` segments only; `trusted` segments (instructions, labels, ids, the scope label) are never
touched, so ids the summarizer's citation check and the judge's parser rely on survive.
- **Dictionary** (built once per session, two `pluck` queries): every Project root's name and aliases (global: a
  summary about one project may mention another) ⇒ `PRJ`; every member of the scope's projects (name, aliases) ⇒
  `ENT`, or `PER` when `entity_type` is a person type ("Person", "User"). Aliases split as `NodeOperationsStrategy`
  does (comma list). Terms shorter than 3 chars and a small built-in allow list of generic words (`Rails`, `User`,
  `Service`, `Controller`, …) are skipped. Cap: **20,000 terms**; over it ⇒ refuse (fail closed).
- **Variants** per term, all matched case-insensitively at Unicode word boundaries: separators (space, `-`, `_`,
  none), CamelCase / camelCase / SCREAMING_SNAKE, possessive `'s`, plural `s`/`es` for terms ≥ 5 chars, and the
  term's JSON-escaped form when it differs (a name with `"` or `\` inside the judge's JSON).
- **Identifier-aware**: identifiers and path segments are split into words (camel/snake/kebab); a dictionary term
  covering a word run is replaced inside the identifier (`GadgetProjectController` → `⟦PRJ_ab12⟧Controller`,
  `lib/gadget_project/x.rb` → `lib/⟦PRJ_c3d4⟧/x.rb`). Repo-relative paths keep their shape (Decision 6).
- **Detectors** (built-in regexes, each with `Regexp.new(…, timeout: 1.0)`; a timeout ⇒ refuse): in this order,
  secrets first:
  - `SECRET` (untyped `⟦SECRET⟧`, **not in the map**, never restorable): PEM blocks, `sk-…`, `ghp_`/`gho_`/
    `github_pat_…`, `xox[abp]-…`, `AKIA…`, JWTs, the value in `password|secret|token|api[_-]?key` `=`/`:` contexts,
    long high-entropy runs (≥ 32 chars of mixed base64/hex classes).
  - `URL` (whole, git remotes `git@host:org/repo.git` included), `EMAIL`, `IP` (IPv4/IPv6, public too), `HOST`
    (FQDNs outside URLs/e-mails only when they end in a private suffix: `.local`, `.lan`, `.internal`, `.home`,
    `.corp`, `.intranet`, `.localdomain`; plain `a.b` method chains are not hosts), `PATH` (absolute Unix paths
    with ≥ 2 segments, `~/…`, Windows drive paths; whole).
  - `USER`: the owner segment of a home-directory path (the Linux, macOS and Windows forms) joins the session's
    dictionary, so the same username elsewhere in the text is masked too.
- **Tokens**: `⟦TYPE_hhhh⟧`, `hhhh` = the first 4 hex of `HMAC-SHA256(session salt, "TYPE\0surface")`, lengthened
  to 6 then 8 on a clash within the session. The salt is `SecureRandom.bytes(32)` per session (Decision 4): stable
  within one call or one scan, unlinkable across them. **One token per surface form** (Decision 5), so
  `unmask(mask(x)) == x` exactly for every non-secret text.
- **Matching**: one left-to-right pass over a word tokenization with a Hash of case-folded word n-grams (n ≤ the
  longest term's word count, capped at 8), **longest match first**, leftmost wins; detectors run before the
  dictionary on the raw text so a URL is one token, not a URL with tokens inside.
- **Collision (input)**: a data segment that already contains `⟦`, `⟧` or a token-like `(PRJ|ENT|PER|PATH|HOST|URL|
  EMAIL|IP|USER)_[0-9a-f]{4,8}` ⇒ refuse (Decision 7).
- **Leftover check (input)**: after masking, the masked text is re-scanned with the dictionary, variants and
  detectors; any hit ⇒ refuse. Nothing is sent on doubt.
- **Unmask**: a tolerant regex accepts `⟦ENT_ab12⟧`, `⟦ ENT_ab12 ⟧`, `[[ENT_ab12]]`, and a bare `ENT_ab12` whose
  suffix is in the map, with a trailing plural/possessive kept as written. A well-formed token not in the map (an
  invented placeholder) ⇒ the whole answer is rejected (Decision 8). Any `⟦` or `⟧` left after restoring (a partial
  de-anonymization) ⇒ rejected. `⟦SECRET⟧` is restored as the literal `[redacted]`. In JSON mode each restored
  value is inserted JSON-escaped (`JSON.generate(value)[1...-1]`), so a name with a quote keeps the answer valid
  and the callers' parsers run unchanged.
- **Leftover check (output)**: an original masked term appearing in the answer is counted; for `:scan` (whose
  answer writes to the graph) it rejects the answer; for `:summary` and `:judge` it is only counted.
- **Lifetime**: the map is a Ruby object on the Scope; never persisted, logged, serialized, put in a review row,
  an `OperationProgress`, a job argument or an exception message.

#### 6. `cloud_allowed` on project entities
- **Migration** `db/migrate/2026110…_add_cloud_allowed_to_memory_entities.rb`: `add_column :memory_entities,
  :cloud_allowed, :boolean, null: false, default: false` (no index: Project roots are few). `db/structure.sql`
  gains the column and the version row; nothing else in it changes.
- **Model**: a validation that it can be true only on a Project root; a `before_validation` that resets it to false
  when an entity stops being a Project root (retyped or given a `project_id`), so `graph_edit` retyping a project
  keeps working; `as_json` excepts `cloud_allowed` alongside `embedding` (REST output byte-identical);
  `EMBEDDING_FIELDS` unchanged (no re-embed). `merge_into` keeps the **target's** flag (never inherits the source's).
- **How it is set** (Decision 3): **only** on the Projects page, by the operator. A "Cloud" column per row: a badge
  (Off / On) and a `button_to` (`PATCH /projects/cloud_access/:id`, `allowed=true|false`) with a `turbo_confirm`
  ("Allow this project's data, anonymized, to be sent to a cloud model once one is configured?"). A note under the
  table says no cloud provider is configured yet, so the flag has no effect until one is.
  `Projects::CloudAccessController#update` (< `Projects::BaseController`, so guests get 403; a non-Project id 404),
  wrapped in `ChangeSet.record(kind: "project.cloud_access", subject: project, summary: …)` (new entry in
  `ChangeSet::KINDS`), audited by `Auditable`, undoable like any audited change.
- **Not settable** through REST (`permit` lists unchanged), MCP (`graph_edit`/`graph_write` slices unchanged; no tool
  argument added), the Explore edit form, import (never read) or export (never written). Guard specs pin each.

#### 7. Logging
- Ollama (`cloud?` false) lines: **unchanged**, same keys, same values.
- Cloud lines add: `anonymized` (true), `masked` (counts per type, e.g. `{"PRJ":1,"ENT":4,"PATH":2}`), `secrets`
  (count), `round_trip` (`ok` / `failed`), `leftover_out` (count), and `refused` (the reason) for a refusal;
  `prompt_chars`/`est_in_tokens` measure the **masked** text. Never a token, a mapping entry, an original value, a
  name, a project id or the salt. `UsageLog` gets an allow list of keys and a spec greps a cloud line for every
  canary.

#### 8. Performance
- Ollama path: zero added cost (no Scope resolution, no session, no query; spec'd by `not_to receive(:new)`).
- Cloud path: two `pluck` queries per session (per call; per scan for scans), dictionary build O(terms × variants),
  masking O(chars × n-gram length), detectors with timeouts. Target: a 200 KB scan part against 10,000 terms masks
  in well under a second; a spec with a generous bound (3 s) catches quadratic blow-ups. Summary and judge prompts
  are small.

### Steps

#### M. Migration, model, scope and gate
- The migration and `db/structure.sql`; `MemoryEntity` validation, reset, `as_json` except; `ChangeSet::KINDS` +
  `project.cloud_access`.
- `Llm::Scope` (`for_entities`, `for_scan`, lazy resolution, `#session` placeholder until A1), `Llm::CloudGate`,
  `Llm::Prompt#scoped` / `#scope`.
- Specs: default false; true refused on a non-Project and on a member; reset on retype; REST show/create/update JSON
  byte-identical (no `cloud_allowed` key); merge keeps the target's flag; scope resolution for each task shape
  (members, roots, unscoped, unknown scan project); gate truth table.

#### A1. Anonymizer core (not wired)
- `Llm::Anonymizer::{Dictionary, Detectors, Tokens, Session}` as in Design §5.
- Specs: every detector type, including negatives (`foo.bar` method chains, `Rails.logger`, version numbers are not
  hosts/IPs); secrets ⇒ `⟦SECRET⟧`; variants; identifier-aware masking; longest match (`Gadget` vs `Gadget
  Project`); a **property round trip** (seeded `Random`, a few hundred generated texts mixing terms in every variant,
  paths, hosts, URLs, e-mails, IPs and noise ⇒ `unmask(mask(x)) == x`); same session ⇒ same token, new session ⇒
  different tokens; clash lengthening; collision refusal; leftover refusal; regex timeout refusal; dictionary cap
  refusal; unmask of tolerant forms; invented token rejected; partial restore rejected; JSON-mode escaping keeps
  `JSON.parse` working.

#### A2. Router cloud path
- `Llm::CloudCall` (Design §4), `Router.generate` branching on `provider.cloud?`, String-or-Prompt, refusal results,
  next-provider loop over `CHAIN`; `UsageLog` cloud fields with the key allow list.
- `spec/support/llm.rb`: `FakeProvider` gains `cloud: false` (a new keyword, default false: no existing example
  changes); `cloud?` returns it.
- Specs: with a non-cloud `FakeProvider` the provider receives `prompt.to_s` (a String), the result Hash and the
  `[llm]` line are identical to 1.67.0's, `Llm::Anonymizer::Session` and `Llm::Scope` resolution are never
  instantiated; with `cloud: true`: refused for each reason without a provider call; masked prompt received;
  answer restored; round-trip failure result; log fields present and canary-free. If `Registry.override` cannot
  register a second name, test the next-provider loop with `stub_const("Llm::Router::CHAIN", …)` plus overrides,
  with no test-only code in `app/`.

**Checkpoint 1:** M–A2 pushed, CI green, open the **draft PR** (paste one cloud `[llm]` line and one masked synthetic
prompt in its description). **Continue** with A3; don't wait for review.

#### A3. Call sites hand over scoped Prompts
- `SummarizerService` (`build_llm_prompt`, `Scope.for_entities(evidence entities)`), `ExtractionPrompt.build` +
  `ChunkedExtraction` (`llm_scope:` keyword, one per scan) + `LlmExtraction` (passes `Scope.for_scan
  (prompt_project_name)`), `Judge#prompt` (`Scope.for_entities([fact entity, *candidate entities])`).
- **Leak specs with canaries**, one per call site, through a `FakeProvider(cloud: true)` that echoes the tokens back
  in a plausible answer: seed an allowed project `Zq7Canary Project` (alias `Zq7cp`), members `Zq7CanaryWidget`,
  `Zq7 Alpha Service`, observations carrying `ops@zq7canary.example`, `10.7.7.7`, `build.zq7canary.internal`,
  a home-directory path for the user `zq7user`, `https://git.zq7canary.example/org/repo.git`, `sk-` + 40 random chars; for the scan a
  `Dir.mktmpdir` tree with the canary in identifiers (Camel, snake, SCREAMING), path segments, comments, a
  Gemfile and a config file. Assert **no canary in any variant** in any `FakeProvider` call's prompt, and the
  caller's output carries the restored originals (summary text, scan entity names, judge `reason`).
- **Session stability**: a two-part scan (plus one forced 413 split) uses the same token for the same name in every
  part and in part 2's names line; two scans use different tokens.
- **Gate at the call sites**: default false ⇒ summary `fallback_reason` `cloud_not_allowed`, scan falls back to the
  deterministic extraction, judge returns unjudged, and the fake records **no** call; a summary spanning an
  allowed and a disallowed project ⇒ refused; a judge candidate with no project ⇒ refused; turning the flag off
  between two parts ⇒ the second part refused.
- P0 goldens and every existing spec green **unchanged**.

#### U. Projects page toggle
- Route (`namespace :projects` → `resources :cloud_access, only: [ :update ]`), `Projects::CloudAccessController`,
  the column and note in `index.html.haml`, strings in `projects.en.yml`, `ProjectsOverview` unchanged (the row's
  `project` already has the column).
- Request specs: operator toggles on and off (flash, change set of kind `project.cloud_access`, audit row); guest
  403; a member or unknown id 404; a bad `allowed` value 422. Guard specs: `graph_edit` `update_entity` and
  `graph_write` with a `cloud_allowed` key, the REST `PATCH` with `memory_entity[cloud_allowed]`, the Explore form and
  an import file carrying it all leave the flag false; an export of an allowed project has no `cloud_allowed`.

**Checkpoint 2:** A3–U pushed, CI green; paste the canary specs' output (example names) in the PR. **Continue.**

#### T. Cross-cutting specs (new files only)
- `spec/services/llm/cloud_architecture_spec.rb` (Prism/grep over `app/` and `lib/`, like
  `architecture_spec.rb`): `Llm::Anonymizer` is referenced only under `app/services/llm/`; `cloud_allowed` is written
  only by the migration, `MemoryEntity` and `Projects::CloudAccessController`, and read only by `Llm::CloudGate`, the
  model and the projects view; nothing under `app/services/llm/anonymizer/` calls `Rails.logger`, `File`, `IO` or
  `puts`; `CloudCall` is the only caller of `Session#mask`/`#unmask`.
- Performance spec (Design §8). `SubprocessGuard` stays active (no spec shells out).
- MCP surface: counts 22 / 12 / 9 / 22 unchanged; `spec/mcp/tools_list_snapshot_spec.rb` green without
  re-recording; `git diff spec/fixtures/mcp/snapshots spec/fixtures/llm` empty; `git diff db/structure.sql` shows only
  the column and the version.

#### D. Docs
- `docs/summarization.md`: "Anonymization and cloud access": what counts as data, the token types, one session per
  call / per scan, what is never logged, the refusal reasons, the Projects page toggle (default off), what still
  leaks (structure, domain vocabulary, numbers; pseudonymization, not anonymity), and that nothing leaves the
  machine until a cloud provider exists (PR4).
- `docs/architecture.md`: the anonymizer and gate inside the `app/services/llm/` layer.
- `docs/plans/ui-dashboard-plan.md`: row AC2 ✅ with the PR number. Generic paths only.

#### R. Release
- `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` (`graph-mem-version:`) → **1.68.0**.
- `CHANGELOG.md` `## [1.68.0] - <merge date>`, summary "Anonymized prompts and per-project cloud access":
  - **Added:** `Llm::Anonymizer` (typed reversible tokens for names, paths, hosts, URLs, e-mails, IPs, usernames;
    secrets redacted) and the cloud gate, both used only for cloud providers (none yet); `cloud_allowed` per project
    (default off) on the Projects page.
  - **Changed:** nothing visible with no cloud provider: requests, prompts, results and outputs are unchanged.
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** T, D, R pushed, CI green; mark the PR **ready for review**.

### Security checklist
- Nothing reaches a cloud provider without: a segmented Prompt, a scope whose every project allows cloud, a clean
  mask (no collision, no timeout, no leftover).
- The map, tokens, originals and salt never leave the process: not logged, persisted, serialized or raised.
- Secrets are redacted, not tokenized: a model answer can't bring one back.
- `cloud_allowed` can only be turned on by the operator on the Projects page; agents can't set it.
- An answer with an unknown token or a leftover bracket is rejected, not guessed.

### Size
About **1,300–1,700 changed lines** (over half specs): M ~180, A1 ~550, A2 ~250, A3 ~300, U ~200, T ~150, D ~60,
R ~20. **If the diff passes ~2,000 lines, stop and ask Steve.**

### Decisions (open, with the recommended default)
1. **Version.** *Default:* **1.68.0** (a migration, a new UI control, a new layer). Alternative: 1.67.1.
2. **Where the flag lives.** *Default:* a `cloud_allowed` column on `memory_entities`, meaningful on Project roots
   only. Alternative: a `project_policies` table (one more model, a join on every gate check).
3. **How it is set.** *Default:* the Projects page only (operator, confirm, change set, audit); REST, MCP, Explore,
   import and export can't set it. Alternative: also a REST `PATCH` param (an API key could then open a project to
   the cloud). An MCP argument is ruled out by the hard rules.
4. **Token key.** *Default:* a random salt **per session** (one session per call, one per scan): stable within a
   scan, unlinkable across calls. Alternative (the earlier one-paragraph scope): an HMAC key derived per install
   (stable across calls, so a provider could correlate the same project over time).
5. **Token granularity.** *Default:* one token per **surface form** (`GadgetProject` and `Gadget Project` get
   different tokens; exact round trip). Alternative: one token per term, restored in canonical form (the model
   sees they are one thing, but identifiers can come back altered).
6. **Code in scans.** *Default:* mask dictionary terms inside identifiers and path segments, absolute paths whole,
   keep repo-relative paths' shape. Alternative: mask every relative path whole (safer, but the scan loses most
   of its structure).
7. **Input collision** (`⟦`, `⟧` or a token-like string already in the data). *Default:* refuse the cloud call.
   Alternative: escape and restore (more code, one more way to get the round trip wrong).
8. **Unknown or invented tokens in an answer.** *Default:* reject the whole answer (`anonymization_round_trip_failed`).
   Alternative (the earlier scope): drop the unknown tokens and keep the rest.
9. **Refusal shape.** *Default:* an `ok: false` Hash with the reason in `error`, no provider call, then the next
   provider in `CHAIN` (none in PR2). Alternative: raise a `Llm::CloudRefused` (every caller would need a rescue).

### Acceptance criteria
- With no configuration: P0 goldens, every existing spec (only `FakeProvider` gains a defaulted `cloud:` keyword),
  REST JSON and MCP outputs are byte-identical; the Ollama `[llm]` line is unchanged; no anonymizer code runs.
- With `FakeProvider(cloud: true)`: no canary in any variant in any provider prompt for summary, scan and judge;
  callers receive the restored originals; one mapping per scan, stable across parts and splits.
- `cloud_allowed` defaults to false; with it false (or any project in scope false, or unscoped data) no cloud call is
  made and each caller degrades as on any LLM error.
- Invented tokens, partial restores, collisions, detector timeouts and leftovers all fail closed, each spec'd.
- The flag is settable only on the Projects page (operator), audited, change-set recorded; guard specs for REST, MCP,
  Explore, import, export.
- MCP: 22 / 12 / 9 / 22, snapshots byte-identical; one migration; no setting; no gem.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) green; files under ~500 lines, methods
  under ~60. Synthetic data only.

### Stop and ask Steve if
Checkpoints are push-and-continue; stop **only** for these:
- Anything would add an MCP tool, change a tool's arguments, description or output, or change an MCP snapshot.
- An existing spec or fixture (P0 goldens included) has to be edited to pass. Adding the defaulted `cloud:` keyword
  to `FakeProvider` and adding new spec files is planned and fine.
- The design needs a migration other than `cloud_allowed`, or a new gem.
- The diff passes ~2,000 lines.
- A quoted line no longer matches the code (`Router.generate`, `build_prompt`, `ExtractionPrompt.text`,
  `ChunkedExtraction#extract`, `Judge#prompt`, `GraphEditService#update_entity`, `MemoryEntity#as_json`,
  `prompt_segments_spec`'s `Llm::Prompt.new` wrapper).

---

## Later PRs (scopes; each gets its own step list)

**PR2: anonymizer + `cloud_allowed` (1.68.0).** Detailed above ("PR2: anonymizer + `cloud_allowed` → 1.68.0").

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
