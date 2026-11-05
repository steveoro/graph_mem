# Scan profiling (`graph_mem:scan_profile`)

`bin/rails graph_mem:scan_profile` runs real project scans, with the real scanner and model, on
**pinned open-source repos or a generated synthetic repo**, into a **throwaway database**, and writes
a report: what each scan created, how many parts it sent, how long they took, and how noisy the
result is. Use it for a first scan you can judge without risking a graph, and to tune the three scan
settings (`project_scan_bytes_per_token`, `project_scan_chunk_output_tokens`,
`project_scan_max_chunks`; see [Summarization › Project scans](summarization.md#project-scans)).

It is a rake task you run by hand. Nothing schedules, enqueues or exposes it: there is no MCP tool,
REST endpoint, UI button or job for it.

## Why it's safe

- **A throwaway database.** The task connects the primary database to `<configured name>_scan_profile`
  (`graph_mem_scan_profile` for the default development config). It creates that database, loads it
  from `db/structure.sql` and marks it in `ar_internal_metadata`. Every write goes there, and the
  task drops it at the end (also on error) unless you pass `KEEP_DB=1`. The configured
  (development) database is never connected to.
- **It refuses to start** in production; with a `DB=` name that doesn't end in `_scan_profile` (or
  is the configured name); on an adapter other than MariaDB/MySQL; and when a database of that name
  exists that the profiler didn't make. It leaves such a database alone: drop it yourself or pick
  another `DB=`.
- **Temp dirs only.** Repos are cloned at their pinned commit into one `Dir.mktmpdir`, removed at
  the end. A local folder is never scanned, and neither is graph_mem's own working tree: the
  `graph_mem` fixture is a fresh clone at its release tag. The scanner runs directly on the temp
  dir; `ScanRootPolicy` and your scan folders aren't used or widened.
- **Nothing reaches the app's queues or caches.** During the run, jobs go to the `:test` adapter
  (the report counts what would have been enqueued; none runs). `Rails.cache` and the settings cache
  are a private in-memory store, and embeddings are skipped (the metrics don't need them).
- **Local Ollama only.** The scan chain is `ollama`. **The profiler never grants cloud access**
  (only the Projects page can), so a cloud chain could only be refused by `Llm::CloudGate` and fall
  back. A cloud `BACKEND=` and `ALLOW_CLOUD=1` are therefore refused before anything runs. The
  report still says whether anything left the machine.

## The fixtures

`script/scan_profile/repos.yml` lists every repo, pinned by full commit SHA:

| Key | Repo | Pin | License | `docs` profile | `code` profile |
|---|---|---|---|---|---|
| `synth` | generated "Gadget Project" | — | — | README, Gemfile, `docs/**/*.md` | `lib/**/*.rb`, `vendor/**/*.rb` |
| `graph_mem` | `steveoro/graph_mem` | tag `v1.72.0` | LGPL-3.0 | README, Gemfile, `docs/*.md` and the `api`, `guides`, `operator`, `rules` docs | `app/services/*.rb`, `app/models/*.rb`, `app/tools/*.rb` |
| `goggles_db` | `steveoro/goggles_db` | `d14e6d7` | LGPL-3.0 | the scanner's defaults | `app/models/**/*.rb`, `lib/**/*.rb` |
| `goggles_api` | `steveoro/goggles_api` | `e95fa8a` | LGPL-3.0 | the scanner's defaults | `app/api/**/*.rb` |
| `dry-inflector` | `dry-rb/dry-inflector` | `65f186b` | MIT | the scanner's defaults | `lib/**/*.rb` |

- `graph_mem` is a dogfood scan. Its `docs/plans/**`, `docs/images/**`, `spec/fixtures/**`,
  `script/mcp_compat/**` and `CHANGELOG.md` are deleted from the clone before scanning: they are
  planning history, not architecture, and alone would fill the input cap.
- `dry-inflector` is the outside-author control: it tells noise from the scan apart from noise from
  one docs style.
- **Caps.** Each scan gets the first-run caps, **64 KB and 20 files** (about 4–5 parts), passed as
  `ProjectScanner.new(max_total_input_bytes:, max_files:)`. `FULL=1` uses the scanner's own caps
  (200 KB / 50 files). `goggles_db` always gets them (`full: true`).
- **`synth`** is written by `GraphMem::ScanProfile::SynthRepo`: `SynthWidget`, `AlphaService`,
  `FrameBuffer`, a long `ReportBuilder` that must split, one file over the 50 KB file cap (so its
  `code` scans are always *partial*) and a generated file. It carries the expected entities and
  relations, so the report can show recall and precision.

## Running it

The model comes from the usual summarization settings, but the throwaway database starts with
**default settings**, not your development ones. So pass the model by environment
(`SUMMARY_URL`, `SUMMARY_MODEL`, `SUMMARY_NUM_CTX`, …, as in [Summarization](summarization.md)), or
with `SETTINGS=`. Without either, it's `http://localhost:11434`, `qwen3:8b`, 8192 tokens.

A first run, a few minutes on an 8B model:

```bash
REPOS=synth,goggles_api PROFILE=docs bin/rails graph_mem:scan_profile
```

| Option | Default | Meaning |
|---|---|---|
| `REPOS=a,b` | every key, `synth` first | the repos to scan; a key that isn't in `repos.yml` (or `synth`) is refused |
| `PROFILE=docs\|code` | both | the glob profile(s) |
| `RESCAN=0` | rescan on | skip the second, `mode: "rescan"` scan of the same code (halves the time) |
| `FULL=1` | first-run caps | the scanner's own caps for every repo |
| `SWEEP=…` | the current values | try settings, below |
| `SETTINGS="k=v;k=v"` | none | `summary_*` and model settings (e.g. `summary_model=qwen3:14b;summary_num_ctx=16384`), written to the throwaway database only; never the scan chain, budgets or inline tasks |
| `BACKEND=ollama` | `ollama` | the scan chain; any cloud chain (and `ALLOW_CLOUD=1`) is refused (above) |
| `KEEP_DB=1` | dropped | keep the throwaway database to look at it (`mariadb graph_mem_scan_profile`); the next run drops it, or `DROP DATABASE graph_mem_scan_profile;` |
| `DB=<name>_scan_profile` | `<configured>_scan_profile` | another throwaway name |
| `REPORT_DIR=…` | `tmp/scan_profile` | where reports go |

Estimated time on local Ollama (an 8B model, `summary_num_ctx` 8192, so about 15 KB of files per
part, 2048 output tokens, 60–120 s per part). The report measures the real numbers.

| Repo | `docs`, first-run caps | `code`, first-run caps | `code`, `FULL=1` |
|---|---|---|---|
| `graph_mem` | ~5 parts, 5–10 min | ~5 parts, 5–10 min | ~13 parts, 13–26 min |
| `goggles_db` (always full) | ~3 parts, 3–6 min | ~13 parts, 13–26 min | same |
| `goggles_api` | ~2 parts, 2–4 min | ~5 parts, 5–10 min | ~13 parts, 13–26 min |
| `dry-inflector` | 1–2 parts, 1–4 min | 1–3 parts, 1–6 min | same |
| `synth` | 1–2 parts, 1–4 min | ~3 parts, 3–6 min | same |

All repos and both profiles take about 40–85 minutes, doubled by the rescan (`RESCAN=0` halves it).

**On a CPU-only machine** (no usable GPU), generation runs at about 15 tokens a second for a 4B
model, slower for an 8B one, and a part can outlast the scan's 120 s request timeout: every part then
fails and the scan falls back. Give parts more time and fewer, larger parts, for example
`SETTINGS="summary_timeout=900;summary_num_ctx=16384"` (a 16K window fits goggles_api's docs in one
part). A small model such as `gemma3:4b` is much faster than `qwen3:8b` there, with weaker answers.

**Without a model** (to see the report's shape, or to check the task works),
`script/scan_profile/fake_ollama.rb` answers `/api/generate` with the synth repo's canned answers.
Only `synth` gives meaningful results with it:

```bash
ruby script/scan_profile/fake_ollama.rb 3995 &
SUMMARY_URL=http://127.0.0.1:3995 REPOS=synth bin/rails graph_mem:scan_profile
```

## Reading the report

`tmp/scan_profile/<UTC timestamp>/report.md` (a summary) and `report.json` (everything). Both use
repo keys and relative paths only: no file contents and no absolute paths. Reports stay local and
are never committed.

- **Header:** the chain, model and window; whether anything left the machine; the throwaway
  database; the jobs that would have run.
- **Scans:** one row per scan (initial, rescan): entities created/updated, observations
  created/obsoleted, relations created/deleted, parts total/failed/split, files too large/over budget,
  partial, fallback (with its reason), wall time, the p50/p95 time of one part, and what the noise
  filter dropped. A fallback means no part succeeded; partial means a part failed or a file was left
  out (nothing was marked missing).
- **Noise (first scan):** on the graph after the first scan:
  - entities with no observations;
  - observations under 20 characters, and duplicate observations within an entity (ignoring case,
    punctuation and spacing);
  - entities named like a file (`user.rb`, `.md`, `Gemfile`) or by a generic word (`Utils`,
    `Helper`, `Config`, …);
  - entities whose only relations are to the project root, and entities with no relation at all;
  - the type spread;
  - **rescan churn**: what the second scan of unchanged code created, obsoleted or deleted. The
    clearest noise signal: a stable scan has none;
  - for `synth`, **recall** and **precision** of entities and relations, with the missed and
    unexpected names.
- **Settings sweep:** with `SWEEP`, one row per combination (below).
- **JSON** (`schema_version: 1`): the same, plus each scan's resulting graph by name (entities with
  type, observations and relations), the pinned commit and the LLM usage counters. The shape is
  stable so that a later tool can compare a report with another graph. A new key means a new
  `schema_version`.

## Trying a setting

```bash
REPOS=synth,goggles_api PROFILE=docs \
  SWEEP="bytes_per_token:2.5,3.0,3.5;chunk_output_tokens:1024,2048;max_chunks:16,32" \
  bin/rails graph_mem:scan_profile
```

Every combination runs on every selected repo and profile (here 12 per repo and profile), with the
values written only into the throwaway database. Each value must be in the setting's range
(`bytes_per_token` 2.0–6.0, `chunk_output_tokens` 512–8192, `max_chunks` 1–64). The "Settings
sweep" table puts parts, failures, splits, time, entities, noise, churn and (synth) recall side by
side. To adopt a value, set it on **Settings › Summaries**. The defaults change in a release only
with a real-model baseline behind them.

## The noise filter

Since 1.73.0, every LLM scan (not only the profiler's) drops a little noise from the merged
extraction before it touches the graph (`ProjectScanner::NoiseFilter`). The rules, all
conservative:

- an observation equal to an earlier one of the same entity, ignoring case, punctuation and spacing;
- a relation from an entity to itself (by its name or an alias);
- an entity named only by a file extension (`.rb`, `md`) or a generic word (`Utils`, `Helper`,
  `Config`, `Main`, …) with at most one observation;
- an entity with no observations and no relations that nothing else relates to.

The counts are in the scan's Ruby result (`noise_dropped`) and one `[scan]` log line (numbers only).
They aren't in MCP or REST outputs. The deterministic fallback isn't filtered.

## Adding a fixture repo

Add an entry to `script/scan_profile/repos.yml`: a public `https://github.com/<owner>/<repo>.git`
URL, a full 40-character commit SHA, the repo's open-source license (SPDX id), and `docs` / `code`
profiles (`default` or a glob list). Add an `exclude` list for paths that aren't architecture, and
`full: true` if it should always use the scanner's own caps. The manifest refuses anything else: a
local path, another host, a branch, a short SHA, no license. Never add a private project or a copy
of one.
