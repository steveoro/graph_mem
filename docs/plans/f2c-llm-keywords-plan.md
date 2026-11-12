# F2c (LLM words for facts that name no entity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Facts with no entity mentions get 1–3 LLM words naming their subject (`llm_keywords`), and F2b's ladder uses them for two such facts on one entity. Also in scope: F2b's deferred minors and the `detect_contradictions` description. Release 1.83.0.

**Architecture:**
- `FactKeywords::LlmWords` (prompt, strict parse, normalize) fills a new column.
- `FactKeywordsJob` and the scan's reconcile pass call it.
- `FactKeywords::Relatedness.compare_paths` takes the words for the same-owner, no-mention case.
- The consumers already read the ladder, so they need no change.

**Tech Stack:** Rails 8.1, MariaDB (`db/structure.sql`), Solid Queue, HAML, RSpec.

**Spec:** `docs/plans/f2c-llm-keywords-design.md` (approved 2026-11-12).

## Global Constraints

- Every Ruby command: `source /usr/share/rvm/scripts/rvm && rvm use ruby-3.4.12@graph_mem && bundle exec …`; specs with `OLLAMA_URL=http://127.0.0.1:9`.
- **The LLM is faked only at the provider boundary:** `with_llm_provider(FakeProvider.new { |prompt, **| … })`, as `spec/services/project_scanner_fact_dedupe_spec.rb` does. The block may branch on the prompt text to answer scan and word calls differently.
- Synthetic data only.
- `LlmWords::BATCH_SIZE = 20`, `FactKeywordsJob::LLM_BATCHES_PER_RUN = 25`, at most 3 words per fact.
- `LlmWords::GENERIC = %w[thing value setting config data info item stuff way use]`.
- The call: `Llm::Router.generate(:summary, prompt, style: "concise", options: { format: "json" })`, with the prompt scoped by `Llm::Scope.for_entities`.
- The prompt text, verbatim from the design §2.
- `llm_keywords` and `llm_keywords_at` are never embedded, and never in `as_json`.
- With `llm_keywords_enabled` or `fact_keywords_enabled` off, every consumer behaves as in 1.82.0.
- Migration: after migrating, `git diff db/structure.sql` keeps every `vector(768)` line. If `StructureDumpGuard` refuses the dump, apply the DDL lines by hand (the 1.77.0 workaround) and check `canonical?`.
- Version **1.83.0**; one commit per task; never force-push.

## Review Focus

1. **The LLM answers words containing a value** ("rails 8"): normalization drops detail tokens, so `[rails]` remains. Owner: Task 2.
2. **The LLM returns an id it wasn't asked about, or the same id twice:** ignored or first-wins, never written to another fact. Owner: Task 2.
3. **A fact gains a mention later** (an entity created after its words): the words stay stored but are unused, because the ladder uses words only with no mentions. Owner: Task 4.
4. **Scan with the LLM down:** the dedupe and writes behave exactly as in 1.82.0, and the words stay pending. Owner: Task 5.
5. **A content edit through graph_edit:** the words are re-pended along with `keywords_at`. Owner: Task 1.

---

### Task 1: columns, model and the setting

**Files:**
- Create: `db/migrate/20261112120000_add_llm_keywords_to_memory_observations.rb` (mirror `20261110120000_add_keywords_to_memory_observations.rb`)
- Modify: `db/structure.sql`, `app/models/memory_observation.rb` (serialize, scope `llm_words_pending`, validation, `invalidate_keywords` also clears `llm_keywords_at`, `as_json` excludes both columns), `app/models/app_settings.rb` (`field :llm_keywords_enabled, default: true, type: :boolean`), `app/services/settings_schema.rb:121` (next to `fact_keywords_enabled`), `config/locales/system_settings.en.yml`
- Test: `spec/models/memory_observation_spec.rb` (or the keywords model spec, if one exists, via `grep -rln keywords_at spec/models`)

**Interfaces:**
- Produces:
  - `MemoryObservation#llm_keywords` (Array<String>) and `#llm_keywords_at`;
  - scope `MemoryObservation.llm_words_pending` (`where(llm_keywords_at: nil)`);
  - `AppSettings.llm_keywords_enabled?`.

- [ ] **Step 1: Write the failing specs:**
  - a new fact has `llm_keywords == []` and is pending;
  - a content change clears `llm_keywords_at` (Review Focus 5);
  - `as_json` has neither key;
  - a non-string word fails validation;
  - the setting defaults to true.
- [ ] **Step 2: Run** them. Expected: they fail (unknown attribute).
- [ ] **Step 3: Implement** the migration, then run `bin/rails db:migrate` and `RAILS_ENV=test bin/rails db:migrate`. Diff `db/structure.sql`: there must be no lost `vector(768)` lines.
- [ ] **Step 4: Run** the model specs and `spec/services/settings_schema_spec.rb`. Expected: pass.
- [ ] **Step 5: Commit** "MemoryObservation: llm_keywords columns and the llm_keywords_enabled setting".

### Task 2: `FactKeywords::LlmWords`

**Files:**
- Create: `app/services/fact_keywords/llm_words.rb`
- Test: `spec/services/fact_keywords/llm_words_spec.rb`

**Interfaces:**
- Consumes: Task 1's columns, `FactKeywords::Details.extract` and `RailsCodeMap.lookup_key`.
- Produces:
  - `LlmWords.words_for(entries) -> Hash{key => Array<String>}`. Each entry is `{ key:, text:, entity: }`. Keys the LLM didn't answer validly are absent. It is `{}` when the LLM is unusable or `llm_keywords_enabled` is off.
  - `LlmWords.compute!(observations) -> Integer`, the number stamped. It stamps `[]` (no call) on facts whose path has mentions, batches the rest, and leaves facts with a path still pending untouched.
  - `LlmWords.normalize(words) -> Array<String>`.

- [ ] **Step 1: Write the failing specs:**
  - **The prompt:** a captured prompt includes the verbatim instruction and each fact's id and text as data.
  - **Parsing:** `{"<id>": ["Rails","version"]}` gives `["rails","version"]`; an unknown id is ignored; a duplicate id keeps the first; non-JSON leaves everything pending.
  - **`normalize`:**
    - `["Rails 8", "Versions"]` → `["rails","version"]` (Review Focus 1);
    - `["email address"]` → `["address","email"]`;
    - a list made only of GENERIC words → `[]`;
    - a 4th word is dropped.
  - **`compute!`:**
    - a fact with mentions is stamped `[]` without a call;
    - a batch of 21 facts makes 2 calls;
    - with the LLM down, nothing is stamped and no error is raised;
    - with `llm_keywords_enabled` off, no call is made.
- [ ] **Step 2: Run** them. Expected: they fail (uninitialized constant).
- [ ] **Step 3: Implement.**
  - **Prompt:** the trusted instruction, then `.data(JSON.generate(batch.map { { id:, text: } }))`.
  - **Parsing:** strict; only the batch's ids, arrays of strings.
  - **Errors:** rescue the Router's failure result (`ok: false`) without raising.
- [ ] **Step 4: Run** the spec. Expected: pass.
- [ ] **Step 5: Commit** "FactKeywords::LlmWords: 1–3 subject words for facts that name no entity".

### Task 3: the job, the rake tasks

**Files:**
- Modify: `app/jobs/fact_keywords_job.rb` (after the paths, up to `LLM_BATCHES_PER_RUN` batches of `active.where.not(keywords_at: nil).llm_words_pending`, with `CooperativeStop.requested?` checked between batches), `lib/tasks/fact_keywords.rake` (`llm_refresh [PROJECT=]`, `llm_report`)
- Test: `spec/jobs/fact_keywords_job_spec.rb`, `spec/lib/tasks/fact_keywords_rake_spec.rb` (create if none exists)

- [ ] **Step 1: Write the failing specs:**
  - the job computes the words of pending no-mention facts after their paths;
  - the job stops between LLM batches when a scheduled run asks;
  - `llm_report` prints the pending, with-words and without-words counts;
  - `llm_refresh PROJECT=` re-pends only that project's facts.
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the specs plus `spec/jobs/scheduled_run_job_spec.rb`. Expected: pass.
- [ ] **Step 5: Commit** "FactKeywordsJob computes LLM words; llm_refresh and llm_report".

### Task 4: the ladder with words

**Files:**
- Modify: `app/services/fact_keywords/relatedness.rb` (`compare` passes the words when `llm_keywords_at` is present; `compare_paths(…, first_words: nil, second_words: nil)`)
- Test: `spec/services/fact_keywords/same_fact_spec.rb` (word rows)

**Interfaces:**
- Produces: `compare_paths` keyword arguments `first_words:` and `second_words:` (Array<String> or nil).

- [ ] **Step 1: Write the failing specs** (word rows, same owner, no mentions):
  - Rails 8.0/8.1 with `[rails, version]` on both sides → `same_subject: true`, `covers: :both`, `details: :different`, so `same_fact_different_detail?` is true;
  - `[email, presence]` vs `[name, presence]` → `:related`, not same subject;
  - `[bcrypt, password]` vs `[name, presence]` → `:unrelated`;
  - `[presence]` vs `[email, presence]` → `covers: :second`;
  - words missing on one side → `:unknown`, `"unclear"`;
  - a fact with a mention plus words, against one with only words → the words are ignored (Review Focus 3);
  - different owners with no mentions → unchanged siblings or unknown.
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement:** with the same owner and both mention lists empty and both word lists non-empty, use the words where F2b uses the subject sets: shared words, `covers` and `subject` (`:related` or `:unrelated`).
- [ ] **Step 4: Run** `spec/services/fact_keywords`, `spec/services/fact_supersede`, `spec/services/review_policies` and `spec/services/contradiction_detector_keywords_spec.rb`. Expected: pass.
- [ ] **Step 5: Commit** "Relatedness: two facts that name no entity compare by their LLM words".

### Task 5: the scan, inline

**Files:**
- Modify: `app/services/project_scanner.rb:375-380` (before the facts pass, `prepare_scan_llm_words!(reconciled)`), `app/services/project_scanner/fact_dedupe.rb` (`same_subject?` uses the words; `import_observations` stores the words on the fact it creates)
- Test: `spec/services/project_scanner_fact_dedupe_spec.rb`

- [ ] **Step 1: Write the failing specs** (the FakeProvider answers the word prompt by its instruction text and the scan prompt otherwise):
  - "skips a no-mention rewording with the same words": stored "Validates presence of name." with `[name, presence]`, then a rescan's "Name must be present." with the same words → skipped;
  - "writes a no-mention fact with a new word": stored `[name, presence]`, new `[email, presence]` → written;
  - "stores the words of the facts it writes";
  - "with the LLM down for the words, behaves as 1.82.0" (Review Focus 4).
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement.**
  - `prepare_scan_llm_words!`: collect `(entity, text)` for the items' new facts with no mentions (via `scan_mentions`), call `LlmWords.words_for` in batches, and keep `@scan_llm_words[[entity.id, text]]`.
  - `same_subject?`: when both texts have no mentions and both word lists are present, the new fact is a duplicate only if its words are a subset of the stored ones (`Details` `:different` already returned false first).
  - `import_observations`: `update_columns(llm_keywords:, llm_keywords_at:)` after `create!` when the words are known.
- [ ] **Step 4: Run** the dedupe spec, `project_scanner_spec.rb` and `project_scanner_reconcile_spec.rb`. Expected: pass.
- [ ] **Step 5: Commit** "Scan: LLM words for its no-mention facts, inline, and a subset dedupe".

### Task 6: display

**Files:**
- Modify: `app/views/entities/_observation.html.haml:16` and `app/views/review/kinds/_keyword_path.html.haml` (LLM chips, shared ones in bold)
- Test: the request specs for Explore's observation row and a review row (find them with `grep -rln "keyword-path" spec`)

- [ ] **Step 1: Write the failing specs:** a no-mention fact with words shows `[data-testid='llm-words']` with each word; a fact with mentions shows none; a review row bolds the shared words.
- [ ] **Step 2–4:** Run them (they fail), implement, then run them again (pass).
- [ ] **Step 5: Commit** "Explore and review rows show a fact's LLM words".

### Task 7: the folded-in clean-ups

**Files:**
- Modify: `app/services/review_policies/subject_check.rb` (`REASON_NOT_SAME = "not the same fact (keyword paths)"`; `reason(row)` returns it when the pair is `related?`), `lib/tasks/fact_keywords.rake` (`review_report` counts it on its own line), `config/locales/system_settings.en.yml:30,229`, `app/services/fact_keywords/details.rb`, the stale comments (`fact_dedupe.rb`, `candidates.rb`, `relatedness.rb`, `no_shared_subject.rb`), `app/tools/detect_contradictions_tool.rb:31`, `docs/mcp_tools.md:152`
- Test: `spec/services/review_policies/no_shared_subject_spec.rb`, `spec/services/fact_keywords/details_spec.rb`, the tool's description spec if one exists

- [ ] **Step 1: Write the failing specs.**
  - A related, not-same unjudged row is dismissed with "not the same fact (keyword paths)", and an unrelated one with the old reason.
  - Details:
    - `"2026-11-12T10:00:00Z"` → includes `"2026-11-12"`;
    - `"1.5x"` → `"1.5x"`;
    - `"10mins"` → `"10mins"`;
    - `"-5"` ≠ `"5"`;
    - `"1,000"` → `"1000"`.
  - `review_report` prints two dismiss lines.
- [ ] **Step 2–4:** Run them (they fail), implement, then run them again (pass). Run `spec/tools/detect_contradictions_tool_spec.rb` too: only the description text changes.
- [ ] **Step 5: Commit** "Clean-ups: the not-same reason, detail misses, stale comments, detect_contradictions text".

### Task 8: docs, release and the PR

- [ ] **Step 1:** `docs/architecture.md`, `docs/app_settings_reference.md` (`llm_keywords_enabled`), a CHANGELOG `## [1.83.0]` entry.
- [ ] **Step 2:** Bump to 1.83.0 and run `bin/rails graph_mem:sync_skill_version`.
- [ ] **Step 3:** `rubocop`, then the full suite with the test DB truncated before and after. Expected: 0 failures.
- [ ] **Step 4:** Commit "Release 1.83.0", push, and open a ready PR. In the body, list the migration, the existing-spec edits and the MCP description change, and suggest running `llm_report` on production first and draining the backlog with "Run all scheduled jobs now".
