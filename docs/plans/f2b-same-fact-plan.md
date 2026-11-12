# F2b (the same fact is not a related fact) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Obsolescence (supersede, a contradiction's losing side) needs the same subject. Being related only ever reaches the judge. Release 1.82.0.

**Architecture:**
- `FactKeywords::Details` extracts a fact's detail tokens deterministically.
- `FactKeywords::Relatedness::Comparison` gains `same_subject`, `covers` and `details`, plus one predicate, `same_fact_different_detail?`.
- The four consumers read those through it:
  - FactSupersede: boost, unjudged seeding and the judge's level and rule;
  - ContradictionDetector;
  - SubjectCheck;
  - FactDedupe.

**Tech Stack:** Rails 8.1, RSpec with a real MariaDB.

**Spec:** `docs/plans/f2b-same-fact-design.md` (approved 2026-11-12).

## Global Constraints

- Every Ruby command: `source /usr/share/rvm/scripts/rvm && rvm use ruby-3.4.12@graph_mem && bundle exec …`; specs with `OLLAMA_URL=http://127.0.0.1:9`.
- Synthetic data only; real instances over doubles (the LLM only at the provider boundary, as the judge specs do).
- The `:unrelated` hard skip of 1.80.0 is unchanged. With `fact_keywords_enabled` off, every consumer behaves as in 1.81.0.
- "Same subject" requires both facts to have mentions. A fact with no mentions is never "same subject" in F2b.
- The judge rule text, verbatim: `- "superseded" requires the statement to be about the same thing as the fact and to differ in a detail (a version, a value, a choice). A statement about a related topic is "still_valid", even when the fact is newer.`
- Each judge statement carries `"subject": "same" | "related" | "unclear"`.
- Version **1.82.0**: `lib/graph_mem/version.rb`, then `bin/rails graph_mem:sync_skill_version`.
- One commit per task; review fixes in new commits; never force-push.

## Review Focus

1. **A fact whose only "detail" is an id or count in its text** ("Fixed in #4227", "3 retries"): numbers decide `details`, so a rewording that changes an incidental number reads as "different detail". The ladder fixture includes one and documents the outcome (Task 1).
2. **Keywords off:** each consumer must fall back to 1.81.0 behavior (seeding unjudged rows included). Owner: Task 2, "as before with fact keywords off".
3. **A judged row that is related but not the same subject:** never dismissed by the policy. Owner: Task 3.
4. **A same-subject pair where the old fact covers more than the source fact:** no boost and no unjudged row, but it is still judged. Owner: Task 2.
5. **Scan dedupe on facts with no mentions and no details:** stays a duplicate, as today. Owner: Task 4.

---

### Task 1: details and the ladder

**Files:**
- Create: `app/services/fact_keywords/details.rb`
- Modify: `app/services/fact_keywords/relatedness.rb`
- Test: `spec/services/fact_keywords/details_spec.rb`, `spec/services/fact_keywords/same_fact_spec.rb` (the ladder fixture), `spec/services/fact_keywords/relatedness_spec.rb` (unchanged expectations must still pass)

**Interfaces:**
- Produces:
  - `FactKeywords::Details.extract(text) -> Set<String>`;
  - `FactKeywords::Details.compare(first_text, second_text) -> :none | :same | :different`;
  - `Comparison = Data.define(:subject, :strong, :shared, :same_subject, :covers, :details)`, with `#same_fact_different_detail? -> Boolean` (`same_subject && %i[first both].include?(covers) && details == :different`) and `#level -> "same" | "related" | "unclear"`;
  - `Relatedness.compare(first, second, connected: nil)`, which fills `details` from the two contents;
  - `Relatedness.compare_paths(…, connected: false, first_text: nil, second_text: nil)`.

- [ ] **Step 1: Write the failing specs.**
  - Details:
    - `"Developed using Rails 8.0"` → `{"8.0"}`;
    - `"v1.7.2 and 3.4.12"` → `{"1.7.2", "3.4.12"}`;
    - `"timeout 5s, 768-dim"` → `{"5s", "768"}`;
    - `"since 2026-11-12"` → `{"2026-11-12"}`;
    - `"no numbers"` → empty;
    - `compare` returns `:none`, `:same` (order-free) and `:different`.
  - Ladder fixture (`compare_paths` with texts), one example per row, at least 20 rows. Each row names the expected `same_subject`, `covers`, `details` and `level`. It includes:
    - Rails 8.0/8.1 with `Rails` in both paths → `same_subject: true`, `covers: :both`, `details: :different`, `same_fact_different_detail?` true;
    - the same pair with no mentions → `same_subject: false`, `level: "unclear"`;
    - belongs-to vs validates (`[p, AdminGrant, User]` both) → same subject, `details: :none`, so not a different-detail pair;
    - AdminGrant↔User cross-owned paths → same subject;
    - a source covering a superset → `covers: :first`, and the reverse → `:second`;
    - siblings → `:unrelated` with `same_subject: false`;
    - related but neither covers (`[p,A,B]` vs `[p,A,C,B]` vs `[p,A,C]`) → `level: "related"`;
    - one-sided → `"unclear"`;
    - Review Focus 1 (`"Fixed in #4227"` vs `"Fixed in #4230"`) → `:different`, documented.
- [ ] **Step 2: Run them.** Expected: they fail with `uninitialized constant FactKeywords::Details`.
- [ ] **Step 3: Implement.**
  - Subjects are `[owner] + mentions`, compared as sets, and only when both mentions are non-empty.
  - `covers`: `:both` when the sets are equal, `:first` when first ⊇ second, `:second` when second ⊇ first, otherwise nil.
  - Detail regex, in this order: ISO dates, versions (`v?\d+(\.\d+)+`), numbers with an optional unit (`\d+[a-z]{0,3}`, the unit kept, a following `-word` dropped).
- [ ] **Step 4: Run** the three spec files. Expected: all pass.
- [ ] **Step 5: Commit** "FactKeywords: detail tokens and the same-subject ladder".

### Task 2: FactSupersede

**Files:**
- Modify: `app/services/fact_supersede.rb` (Candidate gains `level`, `same_fact`), `app/services/fact_supersede/candidates.rb:74-84`, `app/services/fact_supersede/proposals.rb:86-88`, `app/services/fact_supersede/judge.rb` (PROMPT_RULES and `statement`)
- Re-record: `spec/fixtures/llm/g4_judge_prompt.txt`
- Test: `spec/services/fact_supersede/keywords_spec.rb`, `spec/services/llm/characterization_spec.rb` (golden only)

**Interfaces:**
- Consumes: `Comparison#same_fact_different_detail?` and `#level` from Task 1.
- Produces:
  - `Candidate#level` (String or nil);
  - `Candidate#same_fact` (Boolean or nil);
  - `Candidate#seed_unjudged? -> Boolean`: `term.present? || subject.nil? || same_fact`. A nil subject means keywords are off, so the 1.81.0 behavior applies.

- [ ] **Step 1: Write the failing specs** in `keywords_spec.rb`:
  - "boosts only a same-subject candidate the fact covers": SHARED_BOOST, or STRONG_BOOST when the details differ. A merely related candidate gets no boost.
  - "seeds an unjudged row only for the same fact with a different detail, or a term match": Rails 8.0 vs 8.1 is seeded; belongs-to vs validates is not; a candidate that covers more than the fact is not; a term match is.
  - "as before with fact keywords off": unjudged rows are seeded.
  - "gives the judge each statement's level": `Judge#statement` includes `subject: "same"` or `"related"` or `"unclear"`.
  - The rule line is in the prompt.
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement.**
  - The Candidates boost uses `comparison&.same_subject && %i[first both].include?(comparison.covers)`, plus STRONG_BOOST when `details == :different`.
  - `Proposals#proposal?`: for `superseded`, `!unrelated?` (unchanged); for `unjudged`, `!unrelated? && seed_unjudged?`.
  - `Judge#statement` adds `subject: candidate.level` when present, and PROMPT_RULES gains the rule line.
- [ ] **Step 4: Update the golden by hand.** `characterization_spec.rb` has no record mode, so edit `spec/fixtures/llm/g4_judge_prompt.txt`: insert the rule line after the `"superseded" … "unrelated"` rule, and add the `"subject":…` key to each statement exactly as the failing G4 example's diff shows. The file's diff must contain only those changes. Then run `keywords_spec.rb`, `characterization_spec.rb`, `judge_spec.rb` and `candidates_spec.rb`. Expected: all pass.
- [ ] **Step 5: Commit** "FactSupersede: only the same fact is boosted or seeded; the judge gets the level and the same-thing rule".

### Task 3: contradictions and the review policy

**Files:**
- Modify: `app/services/contradiction_detector.rb:83-91` (`pairable`), `app/services/review_policies/subject_check.rb` (`fact_supersede_status`)
- Test: `spec/services/contradiction_detector_keywords_spec.rb`, `spec/services/review_policies/no_shared_subject_spec.rb`

- [ ] **Step 1: Write the failing specs:**
  - ContradictionDetector "doesn't pair related facts that aren't the same subject": `[A, User, Team]` vs `[A, Team, Season]` with a negation is not paired, while `[A, User]` vs `[A, User]` with a negation is.
  - SubjectCheck:
    - an unjudged row for a related, not-same pair → dismissed;
    - an unjudged Rails 8.0/8.1 row → kept;
    - a **judged** row for a related, not-same pair → kept;
    - a judged row for an unrelated pair → dismissed (as in 1.80.0).
- [ ] **Step 2: Run** them. Expected: they fail.
- [ ] **Step 3: Implement.**
  - `pairable`: `comparison if comparison.same_subject`, otherwise the unchanged `:unknown` within 0.15 rule.
  - `fact_supersede_status`: for an unjudged row, dismiss unless the comparison is `same_fact_different_detail?` (with no term); for a judged row, dismiss only when `:unrelated`.
- [ ] **Step 4: Run** both files plus `spec/services/contradiction_detector_spec.rb`. Expected: all pass.
- [ ] **Step 5: Commit** "Contradictions and no_shared_subject: the same subject, not relatedness".

### Task 4: scan dedupe keeps a different detail

**Files:**
- Modify: `app/services/project_scanner/fact_dedupe.rb:42-49` (`same_subject?`)
- Test: `spec/services/project_scanner_fact_dedupe_spec.rb`

- [ ] **Step 1: Write the failing spec:** "writes a close rewording with a different detail". With no mentions, "Developed using Rails 8.0" stored and "Developed using Rails 8.1" new, the fact is written and not counted as deduped. Review Focus 5: a same-detail or no-detail rewording is still skipped.
- [ ] **Step 2: Run** it. Expected: the 8.1 fact is skipped.
- [ ] **Step 3: Implement.** `return false if FactKeywords::Details.compare(text, content) == :different`, before the mentions check, and regardless of the keyword setting.
- [ ] **Step 4: Run** the dedupe spec and `project_scanner_spec.rb`. Expected: all pass.
- [ ] **Step 5: Commit** "Scan dedupe: a close fact with a different detail is written".

### Task 5: docs, release and the PR

- [ ] **Step 1:** `docs/architecture.md` (fact supersede, contradictions, the ladder), `docs/dream_state.md` (`no_shared_subject`), and a CHANGELOG `## [1.82.0]` entry: Changed (the ladder, boost, seeding, judge rule, contradictions, policy) and Fixed (scan dedupe of a different detail).
- [ ] **Step 2:** Bump to 1.82.0 and run `bin/rails graph_mem:sync_skill_version`.
- [ ] **Step 3:** `rubocop`, then the full suite with the test DB truncated before and after. Expected: 0 failures.
- [ ] **Step 4: Commit** "Release 1.82.0". Push, and open a ready PR listing the existing-spec edits and the re-recorded golden. Suggest that Steve runs `review_report` on production before the policy runs.
