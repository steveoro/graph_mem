# F-3 scan chunking → graph_mem 1.66.0: project scan input that fits the model's context window

**Written 2026-10-30 (Europe/Rome)** for Claude, from `main` at `dc571a8` (#143 merged, **tagged `v1.65.0`**). Every
file:line in "What the code looks like today" was checked against that commit. If a line has moved, find the code by
the quoted text. If the code no longer matches the description, **stop and ask Steve** instead of improvising. Only
code was read while writing this plan. **No spec was run.**

Context: `ui-dashboard-plan.md` §6.F **F-3** (found Oct 29, while planning fact supersede). Fact supersede's step S
already shipped half of it in 1.64.0: `summary_num_ctx` (default 8192) is now sent as `options.num_ctx` on every
Ollama request, and `docs/plans/**` is never read by a scan. F-3 is the rest: split the scan input into parts that
fit the window, extract each part, merge the parts before reconcile. Folded in: two optional leftovers from #132
(step L).

## Brief

| | |
|---|---|
| Branch / PR | `claude/f3-scan-chunking`, **one PR**, titled "F-3 scan chunking (1.66.0)" |
| Commits | L → C1 → C2 → C3 → C4 → C5 → C6 → T → D → R, one commit per step (more is fine, fewer is not) |
| Version | **1.66.0** (default, Decision 1): new settings and a visible behaviour change on every LLM scan |
| Data | synthetic only (`SynthWidget`, `Alpha Service`, `Gadget Project`, `Dir.mktmpdir` trees, stubbed HTTP); never a real graph, a copy of one, a real project folder, a real model call, or a real host or user name |
| Read first | `CLAUDE.md`, `AGENTS.md`; `docs/plans/ui-dashboard-plan.md` §6.F F-3; `docs/summarization.md`; `docs/architecture.md` (project scans, review rows); `docs/container_scan_mounts.md` |
| Depends on | 1.65.0 on `main` ✅; fact supersede step S (`summary_num_ctx`, the `options:` keyword on `generate`) ✅ in 1.64.0 |
| MCP surface | **unchanged**: no new tool, no new or changed tool argument or description; default `/mcp` stays at **12**, readonly 9, maintenance 22, 22 classes; `spec/fixtures/mcp/snapshots/*.json` byte-identical. `scan_project_status` already returns `counters` and `details` as free JSON, so the new chunk fields reach agents without a schema change |
| Migration | **none** (the two new settings are `AppSettings` fields) |

## Goal
- Every byte the scan reads is seen by the model: the input goes out in parts that each fit
  `num_ctx − num_predict − prompt`, never one 200 KB prompt that Ollama cuts without saying so.
- The model's JSON answer per part is long enough to be complete and is never cut by the client.
- The parts are merged by entity before reconcile, so a rescan of the same tree gives the same entities whether it
  took one part or ten, and a relation to an entity from another part is kept.
- A failed part never makes the scan delete or obsolete anything it didn't see.
- A resumed scan (a paused validation batch) doesn't run the LLM extraction again.
- Never staleness by age: nothing in this PR reads or compares timestamps to decide what is missing or obsolete.

## Non-goals (out of scope)
- A tokenizer gem or a call to Ollama's tokenizer: token counts are estimated (Decision 2).
- Summarizing or embedding the parts, a map-reduce "summary of summaries", or a second LLM pass over the merged
  result.
- Raising `MAX_FILES` (50), `MAX_FILE_BYTES` (50 KB) or `MAX_TOTAL_INPUT_BYTES` (200 KB); they stay as the outer caps.
- The guided scan (`ProjectScanSkill`): it makes no LLM call. Only its two #132 leftovers are in (step L).
- Pausing a scan between parts (Decision 4), a new MCP tool or argument, a new phase name, a migration.
- Any LLM provider other than the two that exist (`ollama`, `openai_compatible`).

## What the code looks like today (verified at `dc571a8`)

### The input: one prompt, up to 200 KB
- `app/services/project_scanner.rb:28-30`: `MAX_FILES = 50`, `MAX_FILE_BYTES = 50_000`,
  `MAX_TOTAL_INPUT_BYTES = 200_000`. `discover_files` (288-295) sorts the realpaths and keeps the first 50.
- `build_context` (327-346) joins every file as `"--- FILE: <relative>\n<content>\n---\n"`. A file over 50 KB is
  skipped without a trace (332, `next if File.size(file) > MAX_FILE_BYTES`); the loop **breaks** at the first file
  that would pass 200 KB (339-340), also without a trace.
- `call` (136-140): `@context_text = build_context(@discovered_files)` then `extract_knowledge(@context_text)`: one
  LLM call for the whole project.
- `extraction_prompt` (371-406): the instructions and the JSON shape come **first**, the files last (404-405).

### The request: window, output cap, client cut
- `extract_knowledge` (348-369) calls `SummaryGenerationClient.generate(prompt, style: "concise")` (355) **with no
  `options:`**, so it gets the defaults.
- `app/services/summary_generation_client.rb:92-109` (`request_ollama`): `num_ctx` is `options[:num_ctx] || @num_ctx`
  (102), default **8192** (`summarization_config.rb:11`); `num_predict` is `options[:num_predict] || @max_tokens`
  (101), default **256** (`summarization_config.rb:10`). The response's `prompt_eval_count` and `done_reason` are
  dropped (108 keeps only `"response"`).
- `generate` (50-66) always runs `truncate_output` (61, 154-156): the text is cut to `MAX_OUTPUT_LENGTH = 8_192`
  **characters** (10).
- `request_openai_compatible` (111-125) sends `max_tokens: @max_tokens` (120) and ignores `options`.
- The read timeout is `summary_timeout` (130-131), default **30 s** (`summarization_config.rb:9`).

What that adds up to, at the defaults:
1. 200 KB of files is roughly 50,000-65,000 tokens against an 8,192-token window. Ollama keeps the **end** of an
   over-long prompt and drops the start (newer releases may refuse it with a 400 instead, when `truncate` is false),
   so the instructions, the JSON shape and the first files (README, manifests) are exactly what the model never sees.
   Nothing in the response says so; the client doesn't read `prompt_eval_count`.
2. The answer is capped at **256 tokens**: far too short for an `architecture` array, so the JSON is usually cut,
   `parse_json` (409-421) returns nil and the scan falls back to `deterministic_extraction` (363-366), reported as
   "LLM response was not valid JSON".
3. Even with a bigger `num_predict`, `truncate_output` cuts any answer over 8,192 characters, with the same result.

### Merge order inside reconcile
- `reconcile` (536-555) walks `architecture` in order: `reconcile_architecture_item` (594-611) creates the entity,
  adds its observations, then resolves its relations at once. `resolve_relation_target` (703-710) looks in
  `@entities_by_path` (filled as items are processed) and then the database. On a first scan, a relation to an
  entity that comes **later** in the list finds nothing and is dropped (676). With several parts this gets worse,
  because "later" now includes every other part.
- `import_observations` (649-668) already skips an observation whose stripped text matches an active one: exact
  dedupe per entity is there.

### What a scan obsoletes
- `mark_missing_entities` (720-752, called at 548): every entity in the project subtree that this scan didn't
  produce gets its prior-scan observations marked obsolete ("not found in project scan") and, once empty, a
  `delete_entity` scan-review row. It runs whatever the coverage: today the 200 KB `break` and the head cut already
  make it obsolete facts from files the model never saw.
- `dismiss_conflicting_compaction_reviews` (790-800, called at 549) dismisses `relationship_proposal` rows between
  scanned entities when the scan has no relation between them; it has the same blind spot.

### Pause and resume
- The only pause is the validator's batch: `ProjectScanValidator#call`
  (`app/services/project_scan_validator.rb:69-97`) processes `project_scan_validation_batch_size` entities (default
  5, `app_settings.rb:51`) and saves `details["validation_state"]` (177-182); `ProjectScanner#call` returns
  `status: "paused"` (153-179) and `ProjectScanJob#perform` calls `operation.pause!` (143-145).
- A resume is `scan_project` with the paused `scan_id` (`app/tools/scan_project_tool.rb:45`): `ProjectScanJob.enqueue`
  claims the row paused → pending (`project_scan_job.rb:72-84`) and `perform` builds a **new** `ProjectScanner` with
  the same arguments (128-139). In `initial` or `rescan` mode that runs discovery, the **whole LLM extraction** and
  reconcile again before the validator picks up its saved batch (`load_validation_state!`, validator 133-145).
- The validator reads the scan input as text: `context_text:` (47-52) is used to keep or question usage relations
  (359, 387). It must keep getting **all** the text the scan read, not one part.

### Progress and display
- `update_progress!` (863-885) bumps `current` by one per call, with `total = max(total, 5)`, and broadcasts.
  Phases are labelled by `project_scan_phase_label` (`app/helpers/dashboard_helper.rb:44-52`).
- Projects › Scans › a scan (`app/views/projects/scans/show.html.haml`, 56 lines) shows the phase, the message, a
  "Deterministic fallback:" card from `details["fallback"]`/`["fallback_reason"]` (33-36) and every counter (38-45).
- `scan_project_status` and `GET /api/v1/scan/:id` return `counters` and `details` as they are
  (`scan_project_status_tool.rb:58-61`, `api/v1/scan_projects_controller.rb:77-80`).

### Settings and the existing estimator
- `SettingsSchema` group `:project_scans` (`app/services/settings_schema.rb:142-145`): `project_scan_subfolders`,
  `enable_project_scan_validation`, `project_scan_validation_batch_size`. Group `:summaries` (130-140) holds
  `summary_num_ctx` with its validator (`settings_schema/validators.rb:38`) and `NUM_CTX_RANGE` 2048-131072
  (`summarization_config.rb:17`).
- `TokenBudget::CHARS_PER_TOKEN = 4` (`app/services/token_budget.rb:9`) is the recall estimator: tuned for JSON
  payloads, optimistic for source code.
- Saving the `:summaries` group resets the client singleton (`settings_group_update.rb:43`).

### #132 leftovers
- `ProjectScanSkill#top_level_directories` (`app/services/project_scan_skill.rb:408-418`) uses
  `File.lstat(full).directory?` (414) inside one `rescue SystemCallError → []` (417-418): one entry removed between
  `Dir.children` and `lstat` empties the **whole** list.
- `ProjectScanner#top_level_directories` (`project_scanner.rb:510-519`) still uses **`File.directory?(full)`** (515),
  which follows a symlinked entry (#132 changed only the skill), with the same all-or-nothing rescue. It feeds the
  deterministic fallback (454-469), so a top-level symlink to an outside folder becomes a `Component`.
- `spec/services/project_scan_skill_spec.rb:163-180` ("names a symlinked source child without following it") only
  asserts what must **not** exist; nothing asserts what the link becomes (#132's PR notes: `lib/outside` is a
  `Class` named `Outside`).

## Design

### Budget (Decision 2, 3)
Per part, in estimated tokens:

```
input_budget = floor((num_ctx − num_predict − prompt_tokens) × 0.9)
```

- `num_ctx` = `SummarizationConfig.resolved_config[:num_ctx]` (already clamped to 2048-131072).
- `num_predict` = the new `project_scan_chunk_output_tokens` (default **2048**, 512-8192), sent as
  `options[:num_predict]`; it never reads `summary_max_tokens` (that stays the summary length).
- `prompt_tokens` = the estimate of the part prompt with an empty file list (instructions, JSON shape, the part
  header and the names from earlier parts, below).
- Estimate: `(text.bytesize / 3.0).ceil` (`ProjectScanner::TokenEstimate::BYTES_PER_TOKEN = 3`), plus the 10%
  margin above. Bytes, not characters, so non-ASCII text is over-counted, never under-counted.
- If `input_budget < 1024`, the scan doesn't call the model: deterministic fallback with the reason
  "summary_num_ctx (N) leaves no room for project files; raise it to at least 4096".
- At the defaults: (8192 − 2048 − ~700) × 0.9 ≈ 4,900 tokens ≈ **14.7 KB per part**; the 200 KB cap is ~14 parts.
  At `summary_num_ctx` 32768 it is ~3 parts.
- The `openai_compatible` provider has no per-request window; the same formula is used with `summary_num_ctx` as
  the assumed server window (documented), and `num_predict` is sent as `max_tokens` (C1).

### Parts (Decision 4)
`ProjectScanner::ChunkPlanner` (new, pure, no I/O beyond the reads it is handed):
1. Read each discovered file once (as `build_context` does today: UTF-8 with replacement). Files over
   `MAX_FILE_BYTES` are skipped **and counted** (`files_too_large`); the 200 KB outer cap stops reading **and counts**
   the rest (`files_over_budget`) instead of a silent `break`.
2. Order: README and manifests first (`manifest_file?`, 497-508), then the other files grouped by their top-level
   directory, each group sorted by path. Root files sort before directories.
3. Pack whole files greedily into the current part until the next file wouldn't fit. A group may continue into the
   next part; a part never starts in the middle of a file unless the file alone is larger than `input_budget`.
4. A file larger than `input_budget` is split at line boundaries (never inside a line, unless one line alone is
   larger: then at the byte limit, on a UTF-8 boundary) into pieces labelled
   `--- FILE: <relative> (part k of m)`.
5. At most `project_scan_max_chunks` parts (new setting, default **16**, 1-64). Files that would need more are
   not sent and are counted in `files_over_budget`, with their relative paths in `details["extraction"]["left_out"]`
   (first 50).
6. The planner returns `Chunk(index, files, text, estimated_tokens)` and the full text of everything read
   (`context_text` for the validator: unchanged meaning, all parts joined).

### One request per part (Decision 7, 8, 9)
`ProjectScanner::ChunkedExtraction` (new) replaces the body of `extract_knowledge` for the LLM path:
- Prompt: today's `extraction_prompt` (moved, wording unchanged except the lines below), plus a header
  "This is part i of n of one project (project name: X). Other parts hold other files; describe only the files in this
  part." and, from part 2 on, "Entities already found (reuse these exact names when you mean the same thing): …"
  with up to 50 names from earlier parts, most-mentioned first (Decision 7). The names are data inside the prompt
  and count against `prompt_tokens`.
- Request: `SummaryGenerationClient.generate(prompt, style: "concise", options: { num_ctx:, num_predict:,
  format: "json", truncate: false, timeout:, max_output_length: nil })` (C1 adds the last three).
  `truncate: false` asks Ollama to refuse an over-long prompt instead of dropping its start (Decision 9; versions
  that don't know the field ignore it). Timeout per part: `max(summary_timeout, 120)` seconds.
- A part **fails** when: the request fails; `done_reason == "length"` (the answer was cut); `prompt_tokens`
  (Ollama's `prompt_eval_count`) is at or above `num_ctx − num_predict` (the prompt was cut anyway); or the answer
  isn't a JSON object with an `architecture` array.
- Retry (Decision 8): a failed part with more than one file, or a split file piece, is split in half once and both
  halves are sent; a half that fails is final. No retry for a provider error (`provider_unavailable`): the next part
  is tried, and after **two** consecutive provider errors the remaining parts are skipped as failed.
- Progress: phase stays `extracting_knowledge`; `update_progress!(current: i, total: n, message: "Extracting
  knowledge: part i of n")`; `details["extraction"]` is kept current:
  `{ "parts_total", "parts_done", "parts_failed", "files_read", "files_too_large", "files_over_budget",
  "left_out", "input_budget_tokens", "num_ctx", "num_predict", "reconciled" }`.
- All parts failed (or the LLM is off): deterministic fallback, exactly as today, with the first failure as
  `fallback_reason`. Some failed: the merged result of the others is used (`fallback: false`), and the scan is
  **partial** (below).

### Merge (before reconcile)
`ProjectScanner::ExtractionMerger` (new, pure):
- Key: `[name.strip.downcase, ImportEntityResolver.canonical_type(type)]`. Same key from two parts → one item:
  aliases unioned (case-insensitive, first spelling kept), description = the first non-blank, observations unioned
  with the same stripped-text dedupe `import_observations` uses, in part order, relations unioned by
  `[to.strip.downcase, MemoryRelation.canonical_relation_type(type)]` with the highest confidence kept.
- Same name, different type: two items, as today.
- `project`: name and description from the first part that has them (part 1 holds the README), aliases unioned.
- Output: the same `{ "project" => …, "architecture" => [...] }` shape `reconcile` already takes, so
  `deterministic_extraction` and the merged result go through the same path.

### Reconcile in two passes
- `reconcile` creates or updates every entity and its observations first, then resolves every relation. A relation
  to an entity from any part (or later in one part) now resolves; with one part the result is the same as today plus
  the relations that used to be dropped.

### Partial coverage (Decision 5)
- The scan is **complete** when no part failed and `files_too_large`, `files_over_budget` are 0 (every discovered
  file was seen). Only a complete scan runs `mark_missing_entities` and `dismiss_conflicting_compaction_reviews`.
- A partial scan still creates and updates what it saw, never obsoletes or queues deletes, and says so:
  `details["extraction"]["partial"] = true`, a progress message "Partial: 2 of 9 parts failed; nothing was marked
  missing", and a card on the scan page. `success` stays true (it isn't an error), `errors` stays empty.
- A deterministic fallback keeps today's behaviour (it already runs `mark_missing_entities` on manifests and
  directories; out of scope to change).

### Resume (Decision 6)
- After reconcile, `details["extraction"]["reconciled"] = true` and `details["extraction"]["names"]` (the merged
  entity names, at most 500) are saved on the operation.
- When `ProjectScanJob#perform` continues a **claimed paused** scan whose details have `reconciled: true` for the
  same `project_root`, the scanner skips the LLM and reconcile: it reads the files again (no model call) to rebuild
  `context_text`, takes `extracted_data` names from the saved list, and goes straight to `validate_project_subtree!`.
  A changed tree doesn't matter: the reconcile it would redo already happened in batch 1, and the validator
  only needs the text and the names.
- A new scan (no `scan_id`) is unchanged.

## Steps

### L. #132 leftovers (first commit)
- `ProjectScanSkill#top_level_directories` (408-418): rescue `SystemCallError` **per entry** (skip that child) inside
  the `select`; keep the outer rescue for `Dir.children` itself.
- `ProjectScanner#top_level_directories` (510-519): the same, and `File.lstat(full).directory?` instead of
  `File.directory?` (with the skill's comment), so the fallback never lists a symlinked entry.
- Specs: in `project_scan_skill_spec.rb` "names a symlinked source child without following it", add the positive
  assertion `expect(MemoryEntity.where(name: "Outside", entity_type: "Class")).to exist`. New: one entry whose
  `File.lstat` raises `Errno::ENOENT` (stubbed for that path only) is left out while `app` and `docs` are listed (skill
  and scanner). Scanner: a top-level symlink to an outside folder is not a fallback `Component`.

### C1. `SummaryGenerationClient`: the options a part needs
- `options:` accepts `truncate:` (Boolean, Ollama only, sent top-level as `truncate`), `timeout:` (Integer seconds,
  this request only; open timeout stays `min(timeout, 5)`), and `max_output_length:` (Integer, or `nil` for no cut;
  default `MAX_OUTPUT_LENGTH` as today).
- The result hash gains `prompt_tokens:` (`prompt_eval_count`) and `done_reason:` when Ollama returns them (nil
  otherwise). Existing keys and every current caller are unchanged.
- `request_openai_compatible`: `max_tokens` is `options[:num_predict] || @max_tokens`; `done_reason` from
  `choices[0].finish_reason` (`"length"` maps as-is).
- Specs (`spec/services/summary_generation_client_spec.rb`, stubbed HTTP): the payload with and without each option;
  `max_output_length: nil` returns 20,000 characters intact; `prompt_tokens`/`done_reason` passed through; the
  default path byte-identical to today.

### C2. `ChunkPlanner` and the two settings
- `app/services/project_scanner/chunk_planner.rb` and `token_estimate.rb` as in "Budget" and "Parts".
- `AppSettings`: `project_scan_chunk_output_tokens` (default 2048, 512-8192) and `project_scan_max_chunks`
  (default 16, 1-64), both with `validates:` ranges, in `SettingsSchema` group `:project_scans`, locale labels and
  hints in `config/locales/system_settings.en.yml` (the hint states the budget formula in one line).
- Specs: pure planner specs (order; packing; a group spilling over; a file split at lines with "part k of m"
  labels; a single huge line split on a UTF-8 boundary; the 16-part cap with `left_out`; `files_too_large`;
  `input_budget < 1024` → planner reports `:window_too_small`); `settings_schema_spec.rb` picks up both fields.

### C3. `ExtractionMerger`
- `app/services/project_scanner/extraction_merger.rb` as in "Merge".
- Specs: same entity in two parts → one item with unioned aliases, observations (deduped, ordered) and relations
  (highest confidence); same name with two types → two items; project name/description from part 1; empty and
  malformed parts (missing `architecture`, non-Hash items) skipped.

**Checkpoint 1:** L, C1-C3 pushed, CI green; **open the PR as a draft**. No scan behaviour has changed yet. Stop for
Steve's review of the budget numbers and the merge key.

### C4. Wire the parts into the scan
- `ProjectScanner::ChunkedExtraction` as in "One request per part": prompt, options, failure rules, the one split
  retry, the two-provider-errors stop, progress and `details["extraction"]`.
- `ProjectScanner#call`: `build_context` is replaced by the planner (its `context_text` goes to the validator);
  `extract_knowledge` runs the parts and the merger; the fallback paths stay. Move `extraction_prompt` and
  `parse_json` out with it, so `project_scanner.rb` (886 lines today) **shrinks**; it must not grow.
- `reconcile` in two passes.
- `Result` gains `parts_total`, `parts_failed`, `files_too_large`, `files_over_budget`, `partial` (in `to_h`);
  `ProjectScanJob#perform` (147-160) adds the first four to `counters` and `partial` to `details`.

### C5. Partial coverage and the scan page
- Gate `mark_missing_entities` and `dismiss_conflicting_compaction_reviews` on a complete scan (Decision 5).
- `app/views/projects/scans/show.html.haml`: a "Partial extraction" card (`data-testid="scan-partial"`) when
  `details["extraction"]["partial"]`: parts failed of total, files left out (count, and the first 10 paths as
  `<code>`), and the sentence "Nothing was marked missing or queued for deletion." Locale keys in
  `config/locales/projects.en.yml`. All values HAML-escaped (file names are untrusted text).
- No new phase, so `project_scan_phase_label` is unchanged.

### C6. Resume without a second extraction
- As in "Resume". `ProjectScanJob#perform` passes `resuming: true` to `ProjectScanner.new` only when it continued a
  claimed paused row; the scanner checks `details["extraction"]["reconciled"]` and the `project_root` before
  skipping.

**Checkpoint 2:** C4-C6 pushed, CI green. Add one end-to-end example to `spec/services/project_scanner_spec.rb` and
paste its output in the PR: a `Dir.mktmpdir` tree of ~40 KB at `summary_num_ctx` 8192 → **3 parts, 3 stubbed
`generate` calls, one merged result**, a relation from part 3 to an entity from part 1 created, and
`scan_project_status`'s `details.extraction` shown. Stop for Steve's review.

### T. Specs (beyond the ones per step)
- `spec/services/project_scanner_spec.rb` (stub `SummaryGenerationClient.generate` per call, by the part header):
  - one part when the tree fits: one call, the result as today (existing examples stay green unchanged, apart from
    the now-kept relations if any example had a forward reference);
  - several parts: N calls, merged result, each prompt carries "part i of n", the project name, and from part 2 the
    names from earlier parts; every call sends `num_ctx`, `num_predict` 2048, `format: "json"`, `truncate: false`;
  - `summary_num_ctx` 16384 → fewer parts than 8192 for the same tree;
  - a part with `done_reason: "length"` is split once and both halves are sent; a half that fails again counts as
    failed;
  - `prompt_tokens` at the limit → failed part;
  - two provider errors in a row → remaining parts skipped, the scan partial (or fallback when none succeeded);
  - all parts fail → deterministic fallback with the first reason, as today;
  - **partial scan**: a prior-scan observation on an entity the failed part would have produced stays active, and no
    `delete_entity` row is seeded; the same tree with all parts succeeding marks it obsolete as today;
  - a file over 50 KB and a tree over 200 KB are counted (`files_too_large`, `files_over_budget`), and the scan is
    partial, not silent;
  - `window_too_small` (`summary_num_ctx` 2048, output 2048) → fallback with the stated reason, no `generate` call;
  - the validator receives the text of all parts.
- `spec/jobs/project_scan_job_spec.rb`: counters and `details.extraction` on completion; a resumed paused scan with
  `reconciled: true` makes **no** `generate` call and continues the validator batch; a resumed scan without it runs
  as today.
- `spec/requests/projects/scans_spec.rb`: the partial card renders (escaped file names); no card on a complete scan.
- `spec/tools/scan_project_status_tool_spec.rb` (or the existing request spec): `details.extraction` appears in the
  output; tool counts and snapshots unchanged.
- MCP surface: `mcp_tool_registry_spec.rb`, `mcp_official_spec.rb`, `mcp_structured_output_stdio_spec.rb` counts
  unchanged (22 / 12 / 9 / 22); `spec/mcp/tools_list_snapshot_spec.rb` green **without** re-recording; `git diff
  spec/fixtures/mcp/snapshots` empty.
- No spec makes a real HTTP call (stub `SummaryGenerationClient.generate`, or `Net::HTTP` as `summary_generation_client_spec.rb` does); trees are `Dir.mktmpdir` with synthetic names.

### D. Docs
- `docs/summarization.md`: a "Project scans" section: the budget formula with the default numbers, the two
  settings, `truncate: false`, what a partial scan does and doesn't do, the `openai_compatible` caveat (no
  per-request window; set the server's window to `summary_num_ctx`).
- `docs/app_settings_reference.md`: the two new rows in the project scans table.
- `docs/architecture.md` (project scans): planner → parts → merger → two-pass reconcile; complete vs partial; resume.
- `docs/mcp_tools.md` (`scan_project_status`): one line on `counters.parts_*` and `details.extraction`. Do **not**
  change any tool description or schema string.
- `docs/troubleshooting.md`: "a scan says Partial" and "a scan falls back: LLM response was not valid JSON" (raise
  `summary_num_ctx`, check the model's real window).
- `docs/plans/ui-dashboard-plan.md`: the F-3 row ✅ with the PR number; §6.F F-3 marked done.
- Generic paths only (`<project root>`, `/path/to/…`), no host or user names.

### R. Release
- `lib/graph_mem/version.rb` and `skills/graph-mem-mcp-toolset/SKILL.md:18` (`graph-mem-version:`) → **1.66.0**.
- `CHANGELOG.md` `## [1.66.0] - <merge date>`, summary "Project scans send their input in parts that fit the model's
  context window":
  - **Added:** chunked scan extraction (parts sized from `summary_num_ctx`, merged by entity before reconcile);
    settings `project_scan_chunk_output_tokens` (2048) and `project_scan_max_chunks` (16); `counters.parts_total`,
    `parts_failed`, `files_too_large`, `files_over_budget` and `details.extraction` on scans; a "Partial extraction"
    card on the scan page.
  - **Fixed:** a scan's prompt could be far larger than the model's window, so Ollama dropped its start (the
    instructions and the first files) without saying so; the scan's answer was capped at `summary_max_tokens` (256 by
    default) and 8,192 characters, so it was usually cut and the scan fell back to the deterministic extraction; a
    relation to an entity listed later in the answer was dropped on a first scan; files over 50 KB or past the 200 KB
    cap were left out silently; resuming a paused validation batch ran the whole LLM extraction again;
    `ProjectScanner`'s fallback listed a top-level symlink as a directory, and one entry removed mid-scan emptied the
    top-level directory list (scanner and guided scan).
  - **Changed:** a scan marks entities missing (and queues deletes) only when every discovered file was extracted.
- Don't tag, don't push tags, don't run `rake release`.

**Checkpoint 3:** T, D, R pushed, CI green; mark the PR ready for review.

## Security checklist
- **Prompt injection:** file contents and the earlier-parts names list are untrusted data inside the prompt; nothing
  from a model answer is executed, used as a path, or used to pick a file. Names and file paths shown on the scan page
  are HAML-escaped, never `html_safe`.
- **Reads:** the planner reads only the realpaths `discover_files` already checked (`kept_path`, denylist,
  `EXCLUDED_FILE_GLOBS`); no new glob, no new read path. Step L closes the scanner's symlink gap.
- **Resource use:** at most `project_scan_max_chunks` requests per scan plus one split retry each; stops after two
  provider errors in a row. One scan job at a time per scan_id, as today.
- **Deletes:** a partial scan never obsoletes or queues a delete. Nothing is decided by age.

## Size and split
About **1,100-1,400 changed lines** (about half specs): L ~80, C1 ~120, C2 ~250 (incl. settings), C3 ~150, C4
~250, C5 ~80, C6 ~80, T ~350, D ~60, R ~20. **If the diff passes ~1,500 lines, stop and ask Steve.** The natural split
is L + C1-C3 (no behaviour change, `[Unreleased]`, no bump) and C4-C6 + R (1.66.0). Files under ~500 lines and
methods under ~60: `project_scanner.rb` must end smaller than its 886 lines.

## Decisions (open, with the recommended default)
1. **Version.** *Default:* **1.66.0**: two new settings and a visible change on every LLM scan. Alternative: 1.65.1
   as a fix release.
2. **Token estimate.** *Default:* 3 bytes per token plus a 10% margin, no tokenizer (safe for source code, which runs
   denser than prose). Alternative: reuse `TokenBudget`'s 4 characters per token (fewer, fuller parts, more risk of
   a cut that `prompt_eval_count` then catches).
3. **Output budget and timeout per part.** *Default:* a new setting `project_scan_chunk_output_tokens` = 2048 sent
   as `num_predict`, no client-side output cut, and a timeout of `max(summary_timeout, 120)` s. Alternative: reuse
   `summary_max_tokens` (it would have to grow for every summary too).
4. **Too many parts.** *Default:* a cap `project_scan_max_chunks` = 16 (it covers the 200 KB cap at 8192); files
   past it are not sent, counted and listed, and the scan is partial. Alternative: pause the scan after N parts and
   resume like a validation batch (more state, more code; not recommended now).
5. **Partial coverage.** *Default:* only a complete scan runs `mark_missing_entities` and the compaction-review
   dismissal; a partial one creates and updates but never obsoletes or queues a delete. Alternative: keep today's
   behaviour (obsoletes facts from files the model never saw).
6. **Resume.** *Default:* a resumed paused scan with `reconciled: true` skips the LLM and reconcile and goes on with
   the validator batch. Alternative: re-run the extraction as today (slow, and its answers can differ between runs).
7. **Names from earlier parts.** *Default:* yes, up to 50 names in later prompts, so the parts reuse the same entity
   names. Alternative: independent parts (simpler prompts; more near-duplicate entities for the merge to miss).
8. **Failed part.** *Default:* split in half once and retry both halves; stop after two provider errors in a row;
   all failed → deterministic fallback. Alternative: no retry (a failed part is final).
9. **`truncate: false`.** *Default:* yes on scan parts, so an over-long prompt fails loudly instead of losing its
   start (ignored by Ollama versions without the field; `prompt_eval_count` is checked either way). Alternative: leave
   it out and rely on the estimate and the `prompt_eval_count` check.

## Acceptance criteria
- A tree larger than one part produces one request per part, each under the window by the estimate, each with
  `num_ctx`, `num_predict` = `project_scan_chunk_output_tokens`, `format: "json"`; the answers are merged into one
  result, and a relation across parts is created.
- A tree that fits in one part produces one request, and the graph result equals today's except for relations that
  used to be dropped.
- No answer is cut by the client; a cut answer (`done_reason: "length"`) or a cut prompt is detected and retried
  once by splitting.
- A partial scan obsoletes nothing and queues no delete, and says so on the scan page and in `details.extraction`.
- Files over 50 KB or past the caps are counted and visible, never dropped silently.
- A resumed paused scan makes no LLM call when its extraction was already reconciled.
- Step L: no symlinked top-level entry is listed by either `top_level_directories`; one vanished entry leaves the
  others listed; the positive spec assertion is in.
- MCP: 22 classes, default 12, readonly 9, maintenance 22; tool schemas, descriptions and
  `spec/fixtures/mcp/snapshots/*.json` unchanged. No migration: `git diff db/structure.sql` empty.
- Actions (lint, scan_ruby, scan_js) and CircleCI (rspec, rubocop, brakeman) green; the test DB left with 0 rows;
  files under ~500 lines, methods under ~60. Synthetic data only, no real model call.

## Stop and ask Steve if
- Anything would add an MCP tool, change a tool's arguments or description, or change an MCP snapshot.
- A quoted line no longer matches the code (in particular `build_context`, `extract_knowledge`, `request_ollama`
  or the resume path).
- The design needs a migration, a new gem (a tokenizer included), a new job or queue, or a new phase name.
- Keeping `mark_missing_entities` correct needs more than the complete/partial gate.
- The guided scan turns out to call the LLM after all.
- The diff passes ~1,500 lines, or a file passes ~500 lines and can't be split cleanly.
