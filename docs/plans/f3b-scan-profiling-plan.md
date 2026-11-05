# F-3b scan profiling and tuning → graph_mem 1.73.0: a safe, measurable first scan, and less noise

**✅ DONE:** shipped in #157 as **1.73.0** (steps F, S, P, M, N, K, B, D and R; user docs in `docs/scan_profiling.md`). Departures from this plan, noted in #157: the profiler never grants cloud access (only the Projects page may set `cloud_allowed`), so it runs on local Ollama only: a cloud `BACKEND` and `ALLOW_CLOUD=1` are refused up front (Steve's call on #157), and the gate refusal stays spec'd underneath; the noise filter's "no observations" rule only drops an item that also has no relations and that nothing relates to; `synth` has a `code` profile too; timing uses an optional `on_part_done:` hook; the setting defaults are unchanged until a real-model baseline.

**Written 2026-11-05 (Europe/Rome)** for Claude, from `main` at `7769d58` (#156 merged, **tagged `v1.72.0`**). Every
file:line in "What the code looks like today" was checked against that commit. If a line has moved, find the code by the
quoted text. If the code no longer matches the description, **stop and ask Steve** instead of improvising.

Context: `docs/plans/f3-scan-chunking-plan.md` (F-3, shipped as 1.66.0), `docs/plans/ui-dashboard-plan.md` §6.F **F-3b**
("a profiling script … over a few small open-source repos … to tune `project_scan_bytes_per_token`,
`project_scan_chunk_output_tokens` and `project_scan_max_chunks`"), `docs/plans/agent-cli-backend-plan.md` (the LLM
router, `CloudCall`/`CloudGate`, anonymizer; train complete 1.67.0–1.71.0), `docs/summarization.md`.

**Why.** Steve has never run a real project scan, not even in development, for fear of filling a graph with noise. F-3b
gives him a first run that is **safe** (open-source or synthetic code only, a throwaway database, local Ollama, nothing
touches the development or production graph) and **measurable** (counts, failed parts, timing, noise metrics). It then
uses those numbers to tune the scan settings and cut the noise.

**Version.** A new profiling task plus a scan behaviour change (the noise filter, step N) ⇒ **minor: 1.73.0**.

## Brief

| | |
|---|---|
| **Branch / PR** | **One PR**, `claude/f3b-scan-profiling`, off `main`, title `F-3b scan profiling and tuning (1.73.0)`. Open it as a **draft** at checkpoint 1; mark it ready only after R. Steve merges and tags. Never merge, tag, push tags or run `rake release`. |
| **Commits** | **F** fixture manifest + synthetic repo, **S** safety guards (throwaway DB, backend), **P** the profiler and report, **M** noise metrics, **N** noise filter, **K** settings sweep, **B** baseline report, **D** docs, **R** release. Review fixes go in new commits. No force-push after review starts. |
| **Scope** | A rake task + library code for profiling; a conservative, spec'd noise filter in the scan; setting defaults changed only if B's numbers support it. No MCP surface change, no migration, no new gem or non-stdlib package, no REST change. |
| **Code scanned** | **Only** the pinned open-source repos below (mainly Steve's own) or the generated synthetic repo; `graph_mem` itself only as a temp clone at its tag. Never a private project, a copy of one, or any folder outside the profiler's own temp dirs. |
| **Data** | Synthetic specs (`SynthWidget`, `Alpha Service`, `Gadget Project`, `.example` hosts, temp dirs). Never a real graph, a dump or credentials. |
| **Read first** | `CLAUDE.md`, `AGENTS.md`, `.devin/rules/*`, the F-3 plan, `app/services/project_scanner.rb` and `app/services/project_scanner/*`, `app/services/llm/{router,scope}.rb`, `app/services/scan_root_policy.rb`, `skills/project-scan/SKILL.md`. |

## What the code looks like today (verified at `7769d58`)

- `lib/graph_mem/version.rb`: `VERSION = "1.72.0"`. `skills/graph-mem-mcp-toolset/SKILL.md:18` holds `graph-mem-version`.
- `app/services/project_scanner.rb` (682 lines): `MAX_FILES = 50`, `MAX_FILE_BYTES = 50_000`, `MAX_TOTAL_INPUT_BYTES = 200_000` (`:28-30`); `initialize(project_root:, project_name:, aliases:, mode: "initial", dry_run:, file_globs:, operation_progress:, max_files:, max_total_input_bytes:, scan_id:, resuming:)` (`:95-97`); `call` (`:131`) discovers, extracts (`extract_knowledge`), reconciles and validates; `scan_result` (`:186-209`) returns `entities_created/updated`, `observations_created/obsoleted/moved`, `relations_created/deleted`, `entities_reparented`, `errors`, `fallback(_reason)`, `partial`, the skip counters and `parts_total`, `parts_failed`, `files_too_large`, `files_over_budget`. No timing.
- The scanner itself doesn't check `ScanRootPolicy`; the job, tool and REST paths do (`app/services/scan_root_policy.rb:41-43`, `GRAPH_MEM_SCANS`).
- `app/services/project_scanner/llm_extraction.rb`: plans parts (`:55`, `:60-61`, `TokenEstimate.input_budget`), builds `ChunkedExtraction` with `on_part: ->(part, parts) { part_progress!(part, parts) }` (`:31`) and `llm_scope: Llm::Scope.for_scan(project_root:, project_name:)` (`:32`); `summary_num_ctx` too small ⇒ deterministic fallback (`:19-20`).
- `app/services/project_scanner/chunked_extraction.rb` (145 lines): `Outcome = Data.define(:data, :parts_total, :parts_done, :parts_failed, :first_error)` (`:27`); a failed part is split in half once (`:125-130`); provider errors stop after `MAX_PROVIDER_ERRORS` in a row.
- `app/services/project_scanner/extraction_merger.rb` (110 lines): merges parts into `{ "project", "architecture" }`; `names(limit: 50)` feeds later prompts.
- `app/models/app_settings.rb:79-85`: `project_scan_chunk_output_tokens` 2048 (512..8192), `project_scan_max_chunks` 16 (1..64), `project_scan_bytes_per_token` 3.0 (2.0..6.0); `:43` `llm_chain_scan` default `"ollama"`.
- `app/services/llm/scope.rb:40-48` `for_scan`: a cloud provider is allowed only for a folder `CloudGate.scan_project` maps to a project with `cloud_allowed` (default false) and a matching name; otherwise `CloudGate` refuses.
- `config/database.example.yml:14-17`: development's primary DB is `graph_mem`, the same name as production's (`:31`). `db/structure.sql` is the schema.
- `skills/project-scan/SKILL.md:3-6`: `triggers: [user]`, `disable-model-invocation: true`. **Unchanged by this plan.**
- No profiling code exists (`script/` has `llm_bridge` and `mcp_compat`; `lib/tasks/` has no scan task).

## Fixtures (step F)

Mainly **Steve's own open-source repos**, so the first scan is on code he knows and can judge, plus one outside-author
control and the synthetic repo. `script/scan_profile/repos.yml`, every entry pinned by commit (all public; checked 2026-11-05):

| Key | Repo | Pin | License | Size (git) | Ruby files | Why |
|---|---|---|---|---|---|---|
| `graph_mem` | `steveoro/graph_mem` | tag `v1.72.0` = `7769d582be520882fad7eda373d4ecf9b09c423c` | LGPL-3.0 | ~10 MB, 1,185 files | ~790 | dogfood: Steve knows every entity |
| `goggles_db` | `steveoro/goggles_db` | `d14e6d705d985e6182b73e3ba69bae33a24be8f2` | LGPL-3.0 | ~45 MB, 975 files (most of it `db/data` seeds and migrations) | ~600 (95 models) | a small, namespaced Rails engine (most of its size is seed data); kept as a **full** fixture |
| `goggles_api` | `steveoro/goggles_api` | `e95fa8a9b44ad3f2b91d673d6e62bf5a6575edae` | LGPL-3.0 | ~1.5 MB, 239 files | ~170 (84 Grape API files) | an API app that depends on `goggles_db` (cross-repo names) |
| `dry-inflector` | `dry-rb/dry-inflector` | `65f186bb68e5a40be8552dafc203d03cd35223a9` | MIT | ~0.5 MB | small | **outside-author control**: tells "noise from the scan" apart from "noise from Steve's docs style" |
| `synth` | generated | — | — | tiny | — | deterministic, with an expected entity/relation list (recall/precision) |

**`ambgest4`** (`steveoro/ambgest4`, Steve's choice over the older `ambgest`) is **not added yet**: on 2026-11-05 it isn't publicly reachable (GitHub answers 404), so it can't be cloned or pinned. Add it once it's public, with its license, a pinned commit and, if it's large, a path/part cap like the others. The older `ambgest` is not used.

Dropped from the first version of this plan: `rubocop-rake` and `rack-cors` (one control is enough; `dry-inflector` is
the better-documented of the three).

**Dogfood rules (`graph_mem`).** The scan target is always a **fresh temp clone at the pinned tag**, never the working
tree, the checkout the task runs from, or any other local folder. Its `docs/plans/**` (21 files, ~1 MB of plans,
decisions and file:line lists), `docs/images/**`, `spec/fixtures/**`, `script/mcp_compat/**` and `CHANGELOG.md` are
excluded: they are planning history, not architecture, and they alone would fill the input cap. Since
`DEFAULT_FILE_GLOBS` includes `docs/**/*.md`, the `graph_mem` entry lists its globs explicitly.

**Profiles and caps per repo.** `DEFAULT_FILE_GLOBS` (`project_scanner.rb:12-24`) reads only READMEs, manifests and
`docs/**/*.md`, so on the default globs the Goggles repos are 5–8 files (24–39 KB, 2–3 parts), while a
code scan of any of them is over `MAX_TOTAL_INPUT_BYTES` (200 KB, about 12–13 parts). Each entry therefore has:
- `profiles`: `docs` (the default globs, or the curated list for `graph_mem`) and `code` (a curated glob list, e.g.
  `app/models/**/*.rb`, `lib/**/*.rb` for `goggles_db`; `app/api/**/*.rb` for `goggles_api`; `app/services/*.rb`, `app/models/*.rb`, `app/tools/*.rb`
  for `graph_mem`), passed as the scanner's `file_globs:`;
- `max_total_input_bytes` and `max_files`, passed straight to `ProjectScanner.new` (both keyword arguments exist at
  `:95-97`; no scanner change). **First-run default: 64 KB and 20 files per scan** (about 4–5 parts), so a full first
  run stays short; `FULL=1` uses the scanner's own caps (200 KB / 50 files). **`goggles_db` is always full**: its
  entry sets `full: true`, so it gets the scanner's own caps on every run;
- the task options `REPOS=graph_mem,goggles_db` (default: all), `PROFILE=docs|code` (default: both) and `RESCAN=0`.

**Estimated time on local Ollama** (assumptions: an 8B-class model, `summary_num_ctx` 8192 ⇒ ~15–16 KB of files per
part, 2048 output tokens, ~60–120 s per part; the report measures the real figure):

| Repo | `docs`, first-run cap | `code`, first-run cap | `code` with `FULL=1` |
|---|---|---|---|
| `graph_mem` | 64 KB, ~5 parts, 5–10 min | ~5 parts, 5–10 min | ~13 parts, 13–26 min |
| `goggles_db` (always full) | 39 KB, ~3 parts, 3–6 min | ~13 parts, 13–26 min | same |
| `goggles_api` | 24 KB, ~2 parts, 2–4 min | ~5 parts, 5–10 min | ~13 parts, 13–26 min |
| `dry-inflector` | 1–2 parts, 1–4 min | 1–3 parts, 1–6 min | same |
| `synth` | 1–2 parts, 1–4 min | — | — |

A full first run (all repos, both profiles, first-run caps, `goggles_db` full) is about 40–85 min, doubled with the rescan (`RESCAN=0`
halves it). The suggested very first command is `REPOS=synth,goggles_api PROFILE=docs` (a few minutes).

- Cloned with `git clone --filter=blob:none` + `git checkout <sha>` into `Dir.mktmpdir("graph_mem-scan-profile")`, removed at the end (also on error). A missing or moved commit fails that repo, not the run.
- The synthetic repo is generated by `GraphMem::ScanProfile::SynthRepo` into a temp dir: a `Gadget Project` README, a few Ruby classes (`SynthWidget`, `AlphaService`) with known relations, one file over `MAX_FILE_BYTES`, one generated/vendored file, and one long file that must split. It carries an **expected** entity/relation list, so recall and noise can be measured (M).
- Adding a repo means an open-source license, a public URL and a pinned commit; never a private or local folder. The task refuses any `REPOS` key that isn't in `repos.yml` or `synth`.

## Steps

### S. Safety guards (`lib/graph_mem/scan_profile/sandbox.rb`)
- **Throwaway DB.** The task connects the primary DB to `"#{configured_name}_scan_profile"` (e.g. `graph_mem_scan_profile`), creates it, loads `db/structure.sql`, and drops it at the end unless `KEEP_DB=1` (then it prints how to inspect and drop it). It refuses to start when `RAILS_ENV=production`, when the target name doesn't end in `_scan_profile`, or when the DB already exists and wasn't made by the profiler (a marker row in `ar_internal_metadata`). Every write goes there; the development and production graphs are never opened for writing. Spec the refusals.
- **Jobs.** `ActiveJob::Base.queue_adapter = :test` for the run, so nothing reaches Solid Queue (embeddings, review jobs); the report counts what would have been enqueued.
- **Backend.** Default `llm_chain_scan = "ollama"` in the throwaway DB's settings. `BACKEND=cloud|agent_cli` is **opt-in** and only sets the chain; it does **not** bypass `CloudGate`: the profiler creates the throwaway project with `cloud_allowed: true` only when `ALLOW_CLOUD=1` is also given, and every cloud part still goes through `CloudCall` and the anonymizer. The report states the backend and whether anything left the machine.
- **No automatic scans.** It's a rake task run by hand (`bin/rails graph_mem:scan_profile`); no recurring entry, no job, no MCP tool, no UI button. `skills/project-scan/SKILL.md` frontmatter is untouched.

### P. Profiler and report (`lib/tasks/scan_profile.rake`, `lib/graph_mem/scan_profile/{runner,report}.rb`)
- Per repo × setting combination: run `ProjectScanner.new(project_root: tmp, project_name: key, mode: "initial").call` directly (the temp dir is the sandbox; `ScanRootPolicy` is not widened), then a second `mode: "rescan"` run unless `RESCAN=0` (rescan stability is a noise signal).
- Timing: wall time per scan and per part. Prefer a profiler-only wrapper around the `on_part` callback (`llm_extraction.rb:31`); if that needs a scanner change, keep it to an optional `on_part_done:` hook with no default behaviour change.
- Report: Markdown + JSON in `tmp/scan_profile/<UTC timestamp>/` (git-ignored): per run `entities_created/updated`, `observations_created/obsoleted`, `relations_created/deleted`, `parts_total/failed/split`, `files_too_large/over_budget`, `partial`, `fallback(_reason)`, wall time, p50/p95 part latency, plus the M metrics. No file contents and no absolute paths in the report (repo key + relative paths only).

### M. Noise metrics (`lib/graph_mem/scan_profile/metrics.rb`, read-only queries on the throwaway DB)
- entities with 0 observations; observations under 20 chars or duplicated (normalized) within an entity; entities whose name is a bare filename/extension or a generic word (`Utils`, `Helper`, `Config`, `Main`, a fixed list); relations to self or to the project root only; entity-type spread;
- rescan churn: entities/observations created or obsoleted by the second run of unchanged code;
- synthetic repo only: recall and precision against its expected list.

### N. Noise filter (the scan behaviour change)
A small `ProjectScanner::NoiseFilter` applied to the merged extraction before reconcile: drop architecture items with no observations, drop exact/normalized duplicate observations, drop self-relations, drop items whose name is only a filename extension or on the generic list **when** they have ≤ 1 observation. Each rule spec'd with a synthetic example; counts of dropped items go into the scan result (`noise_dropped`, an additive key in the Ruby result; not added to MCP outputs) and the `[scan]` log line. Keep the rule list in one constant. If a rule drops an expected synthetic entity, remove the rule.

### K. Settings sweep
`SWEEP=bytes_per_token:2.5,3.0,3.5;chunk_output_tokens:1024,2048;max_chunks:16,32` (defaults: the current values only) runs every combination on every selected repo and adds a comparison table to the report. The settings are written only into the throwaway DB.

### B. Baseline report
Claude runs the task on `synth` with the spec bridge stub / a fake Ollama (no real model in CI) to show the report shape, and pastes it in the PR. **The real-Ollama baseline is Steve's first run** (`bin/rails graph_mem:scan_profile` with the defaults). Default changes to `project_scan_*` happen **only** if a real baseline is in the PR by then; otherwise the defaults stay and D documents the sweep.

### D. Docs
`docs/scan_profiling.md`: what it scans, why it's safe (throwaway DB, temp dirs, local Ollama default, opt-in cloud through the gate), how to run it and read the report, how to try a setting, how to add a fixture repo (OSS license + pinned commit). Link it from `docs/summarization.md` and `README.md`. Mark F-3b done in `ui-dashboard-plan.md` §6.F.

### R. Release 1.73.0
`lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` → `1.73.0`; CHANGELOG `## [1.73.0]`: Added `graph_mem:scan_profile` (OSS/synthetic repos, throwaway DB, report); Changed the scan's noise filter (and any default changed by B). Mark this plan DONE.

## Later (not in this PR)

- Comparing scan facts with an existing graph's `goggles_db` entities (some were merged wrongly by an early dream-state compactor) to fix or delete the bad merges is out of scope; F-3b has no access to any real DB, but the report's JSON (repo key, pinned commit, entities with type, observations and relations) must stay stable and versioned (`schema_version`) to support that comparison later.

## Size

About 1,500–2,200 changed lines, half of them specs. Files under ~500 lines, methods under ~60, YARD on public methods.

## Decisions (defaults; Steve may change any)

1. **Version 1.73.0** (minor: a new task and a scan behaviour change).
2. **Fixtures:** Steve's open-source repos `graph_mem` (at `v1.72.0`), `goggles_db` and `goggles_api` (`ambgest4` once it's public), `dry-inflector` as the one outside-author control, and `synth`. Larger third-party repos (Mastodon/Discourse subsets) are later, as a pinned subdirectory if wanted.
3. **First-run caps:** 64 KB / 20 files per scan (`goggles_db` always full), `docs` and `code` profiles; `FULL=1` for the scanner's own caps.
4. **Throwaway DB** `<dev name>_scan_profile`, created and dropped by the task; `KEEP_DB=1` keeps it.
5. **Backend:** local Ollama; cloud or agent CLI only with `BACKEND=…` **and** `ALLOW_CLOUD=1`, still through `CloudGate`/`CloudCall`.
6. **Rescan run on by default** (churn is the clearest noise signal).
7. **Noise filter on by default**, conservative rules only; no setting to turn it off (add one only if Steve asks).
8. **Setting defaults** change only with a real baseline in the PR.
9. **Reports** stay local under `tmp/` and are never committed.

## Acceptance criteria

- The `graph_mem` fixture is always a temp clone at the pinned tag, with `docs/plans/**` and the other listed paths excluded (spec'd on the resolved file list); the per-repo caps reach `ProjectScanner.new`.
- `bin/rails graph_mem:scan_profile REPOS=synth` runs end to end with the stub backend in specs; the refusals (production, wrong DB name, foreign existing DB, unknown repo key) are spec'd.
- After a run, the development DB is unchanged (spec: the profiler never connects to a name without `_scan_profile` for writing) and the temp dirs are gone.
- Default backend is Ollama; with no `ALLOW_CLOUD=1`, a cloud chain is refused by the gate (spec'd).
- Noise filter rules spec'd; existing scanner specs green (small edits listed in the PR are fine).
- MCP snapshots byte-identical; counts 22 / 12 / 9 / 22; `db/structure.sql` unchanged; Gemfile/lock unchanged.
- `skills/project-scan/SKILL.md` frontmatter unchanged; no scan starts without an explicit request.
- Full suite, rubocop, brakeman and the four Actions jobs green.
- No real hostnames, IPs, usernames or home paths in docs or reports.

## Stop and ask Steve if

- anything would change the MCP surface (a tool, argument, description, schema, output key or snapshot) or push `/mcp` past 12 tools;
- the work needs a **new migration**, a new gem or a non-stdlib package;
- the diff passes ~3,000 lines;
- anything would weaken the lockdown or the anonymizer and cloud gate (`CloudGate`, `CloudCall`, `cloud_allowed`, `ScanRootPolicy`, `GRAPH_MEM_SCANS`);
- anything would make scans start automatically (a recurring job, a hook, a skill trigger, a model-invocable path);
- the work would scan or copy any code that isn't a pinned open-source repo or the synthetic repo;
- the throwaway DB can't be isolated from the development DB without changing `config/database*.yml` semantics.
