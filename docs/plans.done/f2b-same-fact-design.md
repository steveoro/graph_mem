# F2b → graph_mem 1.82.0: "the same fact" is not "a related fact"

**Status (2026-11-12): DESIGN, for Steve's review.** Written from `main` at `3ced7f7` (1.81.0). F2c (LLM keyword
words for facts with no entity mentions) follows and builds on this ladder.

## Why

Being **related** and being **the same fact** are different things, and only the second may make one fact obsolete
(Steve, 2026-11-12). "Developed using Rails 8.0" may be superseded by "Updated using Rails 8.1": same subject, a
different detail. A fact about a related topic never outdates another.

Today "related" (`FactKeywords::Relatedness`: a shared mention, or one fact mentions the other's entity) still opens
three doors to obsolescence:
- **Supersede boost:** a related candidate scores +0.1 (+0.2 for a shared first mention) in `FactSupersede::Candidates`.
- **Unjudged rows:** without the judge, every pair that isn't `:unrelated` is seeded as an unjudged "Outdated by a
  fact" row.
- **The judge prompt** has no "same thing" rule: "superseded" is anything "the fact shows is no longer true".

A related scan bug: two close facts that mention no entity ("Developed using Rails 8.0" / "… 8.1") pass the scan's
dedupe as the same fact, so the newer one is dropped.

## Decisions (Steve, 2026-11-12; an independent review by Fable informed them)

1. Obsolescence (supersede, the losing side of a contradiction) needs **the same subject**; relatedness alone only
   ever reaches the judge.
2. LLM words stay limited to facts with **no** entity mentions (F2c), never merged with the path. For facts with
   mentions, "same subject" is decided by the entities alone: enough to send a pair to the judge, never enough for
   an unjudged row.
3. The judge prompt gains the "same thing, different detail" rule (its golden is re-recorded).
4. F2b is deterministic: the ladder, detail tokens, the consumers, the judge rule, the dedupe fix. F2c adds the LLM
   words.

## Design

### 1. The ladder (`FactKeywords::Relatedness`)

A fact's **subjects** are `{own entity} ∪ mentions` (its keyword path after the project). A fact with no mentions
has no usable subjects in F2b (its own entity alone says nothing about what it is about); F2c gives it LLM words.

`Relatedness.compare(first, second)` keeps today's `subject` (`:related`, `:unrelated`, `:one_sided`, `:unknown`,
siblings included) and adds:
- `same_subject` (Boolean): both facts have mentions, and one fact's subjects contain the other's (either
  direction). "AdminGrant belongs to a User" (on AdminGrant) and "User has many AdminGrants" (on User) are the
  same subject.
- `covers` (`:first`, `:second`, `:both`, nil): which fact's subjects contain the other's. Supersede needs the
  **new** fact (the source fact) to cover the old one, or obsoleting it would lose what only the old one says.
- `details` (`:same`, `:different`, `:none`): the two facts' detail tokens (§2) compared.

The level names used below:
- **unrelated:** `subject == :unrelated` (unchanged, the only hard skip).
- **same subject:** `same_subject`.
- **same fact, different detail:** same subject and `details == :different`.
- **duplicate:** same subject and `details != :different`.

### 2. Detail tokens (`FactKeywords::Details`)

`FactKeywords::Details.extract(text) -> Set<String>`, deterministic: version numbers (`8.1`, `v1.7.2`, `3.4.12`),
other numbers with an optional unit (`30`, `5s`, `768-dim` → `768`), ISO dates and years (`2026-11-12`, `2026`).
Normalized: lowercase, a leading `v` dropped, trailing `.0` kept (`8.0` ≠ `8`). `compare_details(a, b)`:
`:none` when both are empty, `:same` when equal, `:different` otherwise.

### 3. The consumers

- **`FactSupersede::Candidates`:** the boost goes to a same-subject candidate the source fact covers (+0.1,
  +0.2 when the details differ), not to a merely related one.
- **`FactSupersede::Proposals`, unjudged rows:** seeded only for **same fact, different detail** with the source
  fact covering the candidate, or a search-term / `replaces:` match (unchanged). Related, one-sided and unknown
  pairs are no longer seeded without the judge. The `:unrelated` hard skip stays as in 1.80.0.
- **`FactSupersede::Judge`:** unchanged for which pairs it sees (everything but the hard skip), but each statement
  carries its level (`"subject": "same" | "related" | "unclear"`), and the rules gain:
  > "superseded" requires the statement to be about the same thing as the fact and to differ in a detail (a
  > version, a value, a choice). A statement about a related topic is "still_valid", even when the fact is newer.

  `spec/fixtures/llm/g4_judge_prompt.txt` is re-recorded; the characterization spec otherwise unchanged.
- **`ContradictionDetector.pairable`:** a pair needs the same subject (either direction). Two facts with no
  mentions keep today's rule (cosine distance ≤ 0.15) until F2c gives them words. Related pairs that aren't the
  same subject are no longer paired. Applying a contradiction obsoletes one side, so the same rule as supersede.
- **`ReviewPolicies::SubjectCheck` / `no_shared_subject`:** mirrors the generators. Dismisses pending contradiction
  rows no longer pairable and **unjudged** "Outdated by a fact" rows the new seeding rule wouldn't seed. A
  **judged** row is dismissed only when the pair is `:unrelated` (as in 1.80.0), never just for being related.
  `review_report` counts both.
- **Scan dedupe (`ProjectScanner::FactDedupe`):** a close fact is a duplicate only when its mentions are a subset
  of the stored fact's (as today) **and** the details aren't different. "Developed using Rails 8.0" / "… 8.1" is
  written; it is a supersede candidate, not a duplicate.

### 4. Tests (synthetic, real instances)

- `FactKeywords::Details`: versions, numbers, units, dates, years, normalization.
- A **ladder fixture** of about 20 pairs (with their paths): Rails 8.0/8.1 with and without Rails as an entity,
  belongs-to vs validates (same subject, no detail: a duplicate-level pair the judge decides), siblings, one-sided,
  no mentions, covers both ways.
- Candidates: boost only for same subject covered by the source; Proposals: unjudged rows only for same fact,
  different detail; Judge: the level in each statement and the re-recorded golden; ContradictionDetector: a
  related-not-same pair no longer paired; SubjectCheck: dismissals mirror the generators, a judged related row kept.
- FactDedupe: the 8.0/8.1 rewording is written, a same-detail rewording is skipped.

### 5. Docs and release

`docs/architecture.md` (fact supersede, contradictions), `docs/dream_state.md`, CHANGELOG, **1.82.0**.

## Not in F2b

- F2c: `llm_keywords` (column, the subject-not-value prompt, the background job and scan inline, the backfill in
  `FactKeywordsJob`), and with it "same subject" for facts with no mentions.
- A role-level match for replacements with disjoint mentions ("Jobs run on Solid Queue" / "Sidekiq runs the jobs"):
  still needs a `replaces:` tag (decision 2).
