# F2c → graph_mem 1.83.0: LLM words for facts that name no entity

**Status (2026-11-12): DESIGN, for Steve's review.** Written from `main` at `50c92d0` (1.82.0). Builds on F2b's
same-fact ladder (`docs/plans/f2b-same-fact-design.md`).

## Why

F2b tells the same fact from a related one through the entities two facts mention. A fact that mentions no other
entity ("Validates presence of name.", "Developed using Rails 8.0" where Rails isn't an entity) has no usable
subject: it stays "unclear", so the scan's dedupe and the review generators fall back to embedding distance. Most
of the reworded-fact churn of a scan is such facts. F2c gives them a subject: 1–3 words from the LLM.

## Decisions (Steve, 2026-11-10 to 2026-11-12)

1. LLM words only for facts whose keyword path has **no entity mentions**; never merged with the path; a separate
   column, `llm_keywords`.
2. They are compared only between two facts on the **same own entity**, neither mentioning an entity, at **full
   weight**: no word shared means unrelated.
3. The words name the **subject, never a value** (the prompt Fable proposed): "Developed using Rails 8.0" and
   "Updated using Rails 8.1" get the same words.
4. Scan dedupe: the new fact's words must be a **strict subset** of the stored one's (plus F2b's detail rules).
5. Scans compute their own new facts' words **inline**, in batches, before dedupe; the background job fills the rest.
6. On by default (`llm_keywords_enabled`); the backlog drains through `FactKeywordsJob` (the nightly schedule, or
   "Run all scheduled jobs now", which can stop it between batches).
7. Folded in: F2b's deferred minors (texts, comments, detail-regex misses) and the `detect_contradictions` MCP
   description (text only).

## Design

### 1. Storage

- `memory_observations.llm_keywords` (JSON array of strings, NOT NULL, default `[]`, checked as JSON, like
  `keywords`) and `llm_keywords_at` (datetime(6), NULL = pending), index `(llm_keywords_at, status)`.
- `MemoryObservation`: serialized, validated as strings, never embedded, left out of `as_json` (so REST and MCP
  output don't change). A content change re-pends it, as it does `keywords_at`.
- After the migration, `git diff db/structure.sql` keeps every `vector(768)` line.

### 2. Computing the words (`FactKeywords::LlmWords`)

- **Which facts:** active, keyword path computed, no mentions (`FactKeywords.mentions` empty). Any other fact is
  stamped `[]` without a call.
- **The call:** one `Llm::Router.generate(:summary, prompt, style: "concise", options: { format: "json" })` per
  `BATCH_SIZE` (20) facts. The facts' texts are `data` segments; the prompt is scoped with
  `Llm::Scope.for_entities`, so a cloud chain passes the per-project gate as summaries do.
- **The prompt** (trusted text):
  > For each statement, name what it is about, not what it says about it: 1–3 lowercase singular nouns, taken from
  > the statement where possible. Name the attribute or role, never its value: no versions, numbers, dates,
  > quantities, the name of the current choice, or status words (updated, new, deprecated, now). Two statements
  > that differ only in a value must get the same words. Examples: "Developed using Rails 8.0" → ["rails",
  > "version"]; "Updated using Rails 8.1" → ["rails", "version"]; "Validates presence of email" → ["email",
  > "presence"]. Answer with JSON only: {"<id>": ["word", …], …}.
- **Parsing, strict** (as `FactSupersede::Judge`): an id outside the batch is ignored; a missing or malformed entry
  stays pending; a valid empty list is stamped `[]`.
- **Normalizing:** each word through `RailsCodeMap.lookup_key`, split into single words, singularized, detail tokens
  (`FactKeywords::Details`) dropped, de-duplicated, sorted, at most 3. A list made only of generic words
  (`GENERIC`: thing, value, setting, config, data, info, item, stuff, way, use) counts as empty.
- **LLM down or off:** nothing is stamped, nothing fails; the facts stay pending.

### 3. Who fills them

- **`FactKeywordsJob`:** after the paths, up to `LLM_BATCHES_PER_RUN` (25) batches of pending words; it checks
  `CooperativeStop.requested?` between batches (a scheduled run's Stop).
- **Scans:** after the deterministic paths of the reconcile pass, the scan batches the words of **its own** new facts
  with no mentions before their dedupe check, and stores them with the fact. A failed call leaves them pending and
  the dedupe uses F2b's rule.
- **Setting:** `llm_keywords_enabled` (default true; needs `fact_keywords_enabled`), in the schema and Settings.
- **Rake:** `graph_mem:fact_keywords:llm_refresh [PROJECT=]` (re-pend and compute now) and `llm_report`
  (read-only: pending, with words, without).

### 4. The ladder with words (`FactKeywords::Relatedness`)

For two facts on the **same own entity**, neither with mentions, both with non-empty words, the words take the
place mentions take in F2b:
- `same_subject` when one word set contains the other's; `covers` as for mentions (`:both`, `:first`, `:second`);
- `subject: :related` when some words are shared but neither contains the other;
- `subject: :unrelated` when none is shared (full weight).

`details` comes from `FactKeywords::Details` as in F2b, so "Updated using Rails 8.1" over "Developed using Rails
8.0" (both `[rails, version]`) is the same fact with a different detail. Words pending or empty: today's answer
(`:unknown`, "unclear"). Every other case (siblings, mentions, the project root) is unchanged. All consumers read
the ladder, so they pick this up without changes of their own: the supersede boost, unjudged seeding and the judge's
level; contradictions (the 0.15 rule now applies only while words are missing); `no_shared_subject`.

### 5. Scan dedupe

A close fact with no mentions is a duplicate when its words are a subset of the stored fact's and the details
aren't `:different` (F2b's `:dropped` rule kept). Stored words pending: F2b's rule.

### 6. Display

Explore's fact row and the review rows (`_keyword_path`) show a fact's LLM words as chips marked "LLM", the shared
ones in bold, when the fact has no mentions.

### 7. Folded-in clean-ups

- `ReviewPolicies::SubjectCheck`: a second reason, "not the same fact (keyword paths)", for related-but-not-same
  rows; `review_report` counts it on its own line; the settings label and description say both.
- Stale comments in `fact_dedupe.rb`, `candidates.rb`, `relatedness.rb`, `no_shared_subject.rb`.
- `FactKeywords::Details`: ISO date-times (the date kept), decimals with a unit (`1.5x`), long glued units
  (`10mins`), a sign (`-5` ≠ `5`), thousands separators (`1,000`), each with a spec row.
- `detect_contradictions`' description and `docs/mcp_tools.md`: over-cap candidates are judged later by
  `FactSupersedeJob`; only the same fact with a different detail comes back as an unjudged row.

### 8. Tests (synthetic; the LLM faked at the provider boundary)

`LlmWords` (prompt, strict parsing, normalizing, generic words, LLM down); the job (batches, cap, Stop); the ladder
fixture's word rows (Rails 8.0/8.1 with no mentions → same fact, different detail; presence of email vs name →
related; no shared word → unrelated; pending → unclear); scan dedupe (a same-word rewording skipped, a new-word fact
written, LLM down → F2b's rule); the views; the clean-ups.

### 9. Docs and release

`docs/architecture.md`, `docs/app_settings_reference.md`, `docs/mcp_tools.md`, CHANGELOG, **1.83.0**.

## Not in F2c

- Words for facts with mentions (decision 1); a role-level match such as "Solid Queue" / "Sidekiq" still needs a
  `replaces:` tag.
- A drift report (judge `superseded` verdicts on pairs that aren't the same subject).
