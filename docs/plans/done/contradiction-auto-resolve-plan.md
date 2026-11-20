# Plan: auto-resolve value changes and value-flip contradictions (one PR)

**✅ DONE:** shipped in #184 as **1.92.0**.

> Status (at writing): approved by Steve on 2026-11-19, not started. Written against `main` at 1a16c22 (1.91.0).
> Release: the **next minor** after `main` at release time. With `main` on 1.91.x that is **1.92.0**:
> this is one small PR and is expected to ship before the SQL exchange's release PR (four PRs), which
> then takes the following minor. If `main` already reads 1.92.x, this ships as 1.93.0. Minor, not
> patch: it adds a review policy, a detection path and four settings.

> **Revision 2026-11-19 (single-value changes).** Steve: a fact whose only difference from a newer
> one is its value ("Port: 3000", later "Port: 3001") is superseded by the newer one, no question
> asked. Added: a value-change pairing path in `ContradictionDetector` (section A), the key-value
> class applied by default (Decision 4, section B), the false-merge guards (section D) and their specs.

## Context

The stale-memory contradiction pass pairs two active observations on one entity when they are close
(cosine distance < 0.35), one holds a negative marker and the other doesn't, and their keyword paths
(or LLM words) say they are about the same subject. Two common cases are the same fact with a changed
value, written twice over time:

```
#101 SynthFeature  "Enabled: false"     (older)      #201 SynthService  "Port: 3000"   (older)
#103 SynthFeature  "Enabled: true"      (newer)      #204 SynthService  "Port: 3001"   (newer)
distance 0.09 · confidence 0.99                      not paired today (no negative marker)
```

Facts found on `main` (file:line at 1a16c22):

- Pairing needs a **polarity difference**: `next unless polarity_conflict?` in the candidate loop
  (`app/services/contradiction_detector.rb:280`, `NEGATIVE_MARKERS` `:36-40`, `polarity_conflict?`
  `:313-317`). "Port: 3000" / "Port: 3001" is never paired. The policies' re-check
  `ContradictionDetector.still_pairable?` (`:174-186`, used by `ReviewPolicies::SubjectCheck`
  `app/services/review_policies/subject_check.rb:63`) requires it too.
- The candidate loop already runs one vector query per anchor observation over the entity and its
  1-hop neighbours (`:251-295`, `limit(max_results)` 20 within 0.35); the texts of the candidates
  come back with it.
- The pair's **confidence is distance only**: `min((1 - distance) * 1.1, 0.99)` (`:319-323`).
  No LLM judges a contradiction row.
- **"LLM: done"** on each card is the fact's LLM words (`FactKeywords::LlmWords`, 1–3 nouns naming
  what a fact is *about*, never its value: `app/services/fact_keywords/llm_words.rb:33-43`), rendered by
  `app/views/review/kinds/_keyword_path.html.haml:15-24` through `MemoryObservation#shown_llm_words`
  (`app/models/memory_observation.rb:103-108`). "done" is the subject word, not a status or a verdict.
- **No auto-apply** reaches contradiction rows: `ReviewPolicies::AutoApply` refuses `CHOICE_KINDS`
  (`app/services/review_policies/auto_apply.rb:20-23`, `app/services/review_row_classifier.rb:25`);
  only `AutoApplyFactSupersede` lifts the rule, for its own kind (`auto_apply_fact_supersede.rb:17-19`).
- **Keep this** marks the other side obsolete, without a link
  (`app/services/compaction_review_applier/contradiction.rb:28`), and the MCP
  `apply_maintenance_review` description says so (`app/tools/apply_maintenance_review_tool.rb:22-23`).
- The scan job runs the review policies right after seeding: `ReviewPolicyJob.enqueue_if_seeded(trigger:
  "stale_scan", ...)` (`app/jobs/stale_memory_scan_job.rb:37`).

Goal: resolve value changes unattended, make the card show *what* differs, and stop the "LLM:" label
reading like a status.

## Decisions (Steve, 2026-11-19)

1. Keep the newer side; the older one is **superseded by** the newer one (link set), with a reason,
   audited, undoable with the policy run.
2. MCP surface unchanged: `apply_maintenance_review` and the UI **Keep this** keep marking obsolete,
   and contradiction row payloads keep exactly today's keys.
3. A single-value change is resolved with no question asked (Steve, "Port: 3000" → "Port: 3001").
4. **Default on for the key-value class only** (section B): `enable_auto_apply_contradiction` defaults
   to `true` and, by default, applies only rows whose two facts are one `Key: value` line each with the
   same key and one changed value. The wider free-text class (sentences that differ in 1–2 value
   tokens) stays **off** (`auto_apply_contradiction_free_text`). Why default on is acceptable here:
   - it touches no gate: not the `/mcp` lockdown, the anonymizer or the cloud gate; nothing is deleted;
   - the older row stays, `superseded` with its link and reason, and has an audit row;
   - each policy batch is one change set, undoable for 30 days (`ChangeSet::WINDOWS["audit"]`,
     `app/models/change_set.rb:24`) from Review › policy runs; after that the row can still be
     re-activated by hand (GC deletes only active exact duplicates,
     `app/services/garbage_collection_runner.rb:62-87`);
   - the CHANGELOG lists it under "Changed" as default-on, with the setting to turn it off.

## A. Detection: a value-change path in `ContradictionDetector`

Choice: **extend the existing candidate loop**, not a new pass.

- In `find_contradiction_pairs`, the filter `next unless polarity_conflict?(...)` (`:280`) becomes
  `next unless polarity_conflict?(...) || value_change?(anchor, candidate)`, where `value_change?` is
  `FactKeywords::TokenDiff.value_change(anchor.content, candidate.content)` (section C) plus the same
  `memory_entity_id`, `source` and `perspective`.
- A **key-value** change (section C) is paired without the keyword gate (`pairable`): two lines with
  the same key and one changed value are the same subject by construction, and on facts that mention no
  entity the gate would otherwise route them to the `:unknown` judge fallback (`:141-147`). Dated events
  are still excluded. A free-text value change keeps the keyword gate, like a polarity pair.
- `still_pairable?` accepts a value change the same way (both active, same entity/source/perspective,
  `TokenDiff.value_change` true), so `SubjectCheck` doesn't dismiss these rows.
- Cost: no new query. The texts are already in the candidate rows; the check is an in-memory token
  diff of two short strings, done only for the ≤ 20 nearest candidates of each anchor, so the work
  stays what the detector already does per entity. Near-identical texts like "Port: 3000" / "Port: 3001"
  are among the nearest neighbours, so the distance cut-off (0.35) doesn't hide them.
- Rejected: a dedicated embedding-free pass in the stale-memory scan (group each touched entity's
  active facts by a key-value signature). It would avoid the embedding for key-value lines, but it
  needs its own candidate query, watermark and report keys, and the loop above already reaches the
  same pairs once the facts are embedded (at write time or by the next backfill). It can be added
  later if unembedded facts turn out to matter.
- The row is an ordinary `contradiction` row with today's payload keys (`review_item`, `:88-105`);
  nothing new is stored. Whether a row is a key-value change, a free-text change or a polarity pair is
  recomputed from the live texts wherever it matters (the policy, the card), as the shared keywords
  already are. So MCP `list_maintenance_review` output is unchanged.

## B. Policy `ReviewPolicies::AutoApplyContradiction`

New `app/services/review_policies/auto_apply_contradiction.rb`, modelled on `AutoApplyFactSupersede`:

- `< AutoApply`; `applicable_kind?` lifts the hard rule for `"contradiction"` only (every other choice
  and destructive kind is still refused); `PER_RUN = 100` (a backlog drains 100 rows per run).
- `eligible`: active `contradiction` rows; each row is checked against the **live** observations (the
  payload's text is truncated and may be stale). Common conditions:
  1. both observations exist and are `active`;
  2. same `memory_entity_id`;
  3. same `source` and same `perspective` (NULL equals NULL);
  4. one side is clearly newer (below); a tie skips the row.
  Then by class:
  - **key-value** (default): `TokenDiff.value_change(a, b)` returns `class: :key_value`. No distance
    cap: the token diff is decisive.
  - **free text** (only with `auto_apply_contradiction_free_text` on): `class: :free_text` with
    `1..auto_apply_contradiction_max_tokens` differing tokens, and the live cosine distance
    (`VEC_DISTANCE_COSINE` of the two rows) `<= auto_apply_contradiction_max_distance`.
  - anything else (polarity pairs that aren't a value change, "X is used" / "X is not used"):
    never applied; it stays for the operator.
- **Newer side**: compare `valid_from` when both are set and differ; otherwise `created_at` when they
  differ; otherwise `updated_at` when they differ; otherwise tie → skip (counted as `skipped`).
- Act: overrides `with_locked_row` to call
  `CompactionReviewService.apply(row.row_uuid, { keep_observation_id: newer.id }, report_type: row.report_type, resolution: :supersede)`.
  - New keyword `resolution:` (default `:obsolete`) on `CompactionReviewService.apply` →
    `apply_row` → `CompactionReviewApplier.apply` → `CompactionReviewApplier::Contradiction.apply`.
    It is a Ruby keyword, never read from `action_params`, so the MCP tool and the UI can't reach it.
  - With `:supersede`, `Contradiction.apply` calls `older.supersede_with!(newer, reason: ...)`
    (`app/models/memory_observation.rb:178-195`) instead of `mark_obsolete!`. Reason:
    `"Superseded by observation #<newer> (value change: <old> → <new>)"`.
  - Eligibility is re-checked inside the row lock before writing (an operator action in between wins,
    as in `ReviewPolicies::Base`).
- Audit and undo: `supersede_with!` is an `update!`, so `Auditable#audit_update`
  (`app/models/concerns/auditable.rb:20-27`) writes one row with the `from`/`to` of `status`,
  `obsoleted_at`, `obsolescence_reason` and `superseded_by_id`, actor `policy:auto_apply_contradiction`,
  inside the batch change set (`app/services/review_policies/base.rb:54-68`).
  **Undo needs no new code as far as main shows:** `ChangeSetUndo::AuditInverse#invert_update`
  (`app/services/change_set_undo/audit_inverse.rb:86-104`) writes back every audited field except
  `IGNORED` (`:10-13`, which doesn't list `status` or `superseded_by_id`), so the older row returns to
  `active` with `superseded_by_id` NULL, and `ChangeSetUndo::ReviewRows` reopens the row (the existing
  `spec/services/change_set_undo/contradiction_undo_spec.rb` shows this for the obsolete path). A spec
  proves it for the supersede path; if it fails, the fix goes in this PR and is reported.
- Register: `ReviewPolicyRunner::POLICIES` after `AutoApplyFactSupersede`
  (`app/services/review_policy_runner.rb:12-16`); `AppSettings::REVIEW_POLICY_TOGGLES`
  (`"auto_apply_contradiction" => ["enable_auto_apply_contradiction", true]`); update the
  `CHOICE_KINDS` comment (`app/services/review_row_classifier.rb:23-24`). The scan's own policy run
  (`stale_memory_scan_job.rb:37`), the nightly run and "Run policies now" pick it up, so a value change
  is usually resolved in the same maintenance cycle that found it.

### Settings (no migration: `AppSettings` is rails-settings-cached, `app/models/app_settings.rb:3-4`)

| Setting | Default | Range | Applies to |
|---|---|---|---|
| `enable_auto_apply_contradiction` | `true` | — | the policy (key-value class) |
| `auto_apply_contradiction_free_text` | `false` | — | also the free-text class |
| `auto_apply_contradiction_max_distance` | `0.10` | 0.02–0.15 | free text only |
| `auto_apply_contradiction_max_tokens` | `2` | 1–2 | free text only |

Added to `REVIEW_NUMBERS`, the Review policies settings group, `config/locales/system_settings.en.yml`
(label + description; the toggle's text says it is on by default and what it changes) and
`docs/app_settings_reference.md`. No confidence threshold: a contradiction's confidence is a function
of its distance, so the distance cap is the honest knob.

## C. Shared helper `FactKeywords::TokenDiff`

New `app/services/fact_keywords/token_diff.rb`, used by the detector, the policy gate and the view:

- Tokens: words and values with their character offsets; versions, decimals and numbers with units
  are one token (reuse `FactKeywords::Details::PATTERNS`, `app/services/fact_keywords/details.rb`);
  punctuation and whitespace separate tokens; comparison is case-insensitive.
- `diff(a, b)` → `{ left: [spans], right: [spans] }`: the tokens outside the longest common token
  subsequence on each side.
- Value tokens: booleans (`true/false`, `yes/no`, `on/off`, `enabled/disabled`), numbers (ports
  included), versions (`v1.7.2`, `8.1`), numbers with a unit (`5s`, `10 ms`). Two paired value tokens
  must be of the same class (boolean with boolean, number with number, version with version).
- `value_change(a, b)` → `nil` or `{ class:, key:, from:, to: }`:
  - `:key_value` when each text is exactly one `Key: value` or `key = value` line (optional trailing
    period), the two keys are identical (case-insensitive, whitespace collapsed), each value is one
    value token (with its unit), the values differ, and the units are identical;
  - `:free_text` when the texts differ in the same number of tokens on each side, `1..2`, and every
    differing token is a value token of a matching class with the same unit;
  - `nil` otherwise.
- `HIGHLIGHT_MAX = 3`: the view highlights only when `diff` finds 1–3 differing tokens per side.

## D. Guards against false merges

Each is a `value_change` → `nil` rule (and a spec):

- **Different keys never pair:** "Port: 3000" / "Timeout: 3000"; "Port (dev): 3000" / "Port (test): 3001"
  have different key text, so a per-environment pair is never merged.
- **List-like content is excluded:** a value part with `,` `;` `|` or " and ", more than one value
  token, more than one `:`/`=` separator, or more than one line ("Ports: 3000, 3001").
- **Units must match:** "Timeout: 5s" / "Timeout: 5m" or "Size: 10 MB" / "Size: 10 GB" don't pair
  as a value change (the unit, not the value, changed).
- **Same key text on both sides** (above), the same entity, source and perspective.
- **Tie on newer → skip**, and either side inactive → skip.
- Dated events ("[2026-08-26] …") never pair (`ContradictionDetector::DATED_EVENT`).

## E. UI

- Label: `ui.review.keyword_path.llm_words` "LLM:" → **"LLM topic:"** (`config/locales/ui.en.yml:37`),
  and the entity panel's `explore.panel.llm_words` (`config/locales/explore.en.yml:64`) the same, so the
  two places read alike. `en` is the only locale. Update the one spec asserting the old text
  (`spec/requests/review_keyword_paths_spec.rb:60`).
- Contradiction card (`app/views/review/kinds/_contradiction.html.haml:12`): when `TokenDiff.diff`
  finds 1–`HIGHLIGHT_MAX` differing tokens per side, each side's text is rendered with its differing
  tokens wrapped in `<mark>`; otherwise the text renders as today. The helper
  (`ReviewHelper#review_diff_text`) escapes the text and builds the marks with `safe_join`/`tag.mark`,
  never `html_safe` on content; it keeps the 300-character cut (a mark past the cut is dropped).
- Style: `.review-contradiction mark` uses the existing convention from
  `app/assets/tailwind/search.css:216-220` (`background: var(--color-ui-warn-soft); color: inherit;
  border-radius: 2px;`), added in `app/assets/tailwind/application.css` next to `.review-contradiction`
  (`:538`). Accessibility: colour is not the only cue. Each side also gets a visually hidden line
  ("Differs: 3000 → 3001", a `review-sr-only` class like `system-sr-only` in
  `app/assets/tailwind/system.css:524`), and contrast stays that of normal text.

## Specs (synthetic names only: `SynthService`, `SynthFeature`, "Port: 3000" / "Port: 3001")

- `spec/services/fact_keywords/token_diff_spec.rb`: key-value changes (port, boolean, version, number
  with the same unit); key mismatch → nil; unit mismatch → nil; list-like values and multi-line or
  multi-pair texts → nil; free-text flips of 1–2 tokens; 3 tokens refused; inserted "not" refused; word
  change refused; boolean vs number refused; case-insensitive; offsets right for multibyte text; dated
  events refused.
- `spec/services/contradiction_detector_spec.rb` (extend): "Port: 3000" / "Port: 3001" on one entity
  is paired (no negative marker); "Port: 3000" / "Timeout: 3000" is not; facts on two entities, or with
  different source or perspective, are not paired by the value path; the payload keys are exactly
  today's; `still_pairable?` is true for a value change and false once one side is retired.
- `spec/services/review_policies/auto_apply_contradiction_spec.rb`:
  - defaults: the toggle is on, free text off;
  - Port 3000 → 3001: older `superseded`, `superseded_by_id` = newer, reason set, newer untouched, row
    approved, one audit row with actor `policy:auto_apply_contradiction`;
  - "Enabled: false" → "Enabled: true" resolved the same way;
  - not applied: key mismatch, unit mismatch, multi-value line, different entity, different source,
    different perspective, a tie on all three timestamps, either side inactive, a polarity pair that
    isn't a value change, a non-contradiction kind;
  - newer by `valid_from` beats a later `created_at`;
  - toggle off → nothing (`"disabled" => true`);
  - free text: off by default; on → a 2-token flip within the distance cap applies, 3 tokens or a
    distance over the cap doesn't.
- Undo: the policy run's change set undone → older `active`, `superseded_by_id` NULL,
  `obsoleted_at`/`obsolescence_reason` NULL, row reopened; redo works.
- MCP unchanged: `apply_maintenance_review` on a contradiction row with
  `action_params: { keep_observation_id:, resolution: "supersede", supersede: true }` still marks the
  other side obsolete with no link; the tool snapshots and counts (12 / 9 / 22) are byte-identical.
- View/request: the card shows `<mark>` around `3000` and `3001`; no `<mark>` when more than 3 tokens
  differ; HTML in content stays escaped; "LLM topic:" label on the card and the entity panel.
- `spec/models/app_settings_spec.rb`: defaults and ranges of the four settings.

## CHANGELOG (`## [Unreleased]`, then the release entry)

- Added: value changes are paired as contradictions: two facts on one entity, same source and
  perspective, that differ only in a value ("Port: 3000" / "Port: 3001") are found even without a
  negative word.
- Changed: **Auto-resolve value changes** review policy (Settings › Review policies, **on by
  default**): a `Key: value` fact whose newer twin has the same key and another value is marked
  superseded by the newer one. Undo the policy run to revert; turn the setting off to keep reviewing
  them by hand. Sentences that differ in 1–2 values are included only with "free text" on (off).
- Added: the contradiction card highlights the tokens that differ between the two sides.
- Changed: the "LLM:" label on review cards and the entity panel reads "LLM topic:" (it names what a
  fact is about; it was never a status).

## Delivery

One PR, branch `claude/contradiction-auto-resolve`. No migration, no new gem or package, no MCP
surface change (tool params, outputs, descriptions, review payload keys and counts unchanged), nothing
touching the lockdown or the anonymizer/cloud gate. Expected diff about 800–1,200 lines with specs.

## Known limits

- Detection needs both facts embedded (the vector query finds the candidates); a fact written while
  embeddings are down is paired after the next backfill.
- Two facts with the same key text that are both true in different contexts ("Port: 3000" for one
  environment, "Port: 3001" for another, with nothing in the key saying which) are merged; the
  operator undoes the run or re-activates the older row, and writes the context into the key.
- Newer-wins trusts timestamps; an older fact re-written later (a newer `created_at`) wins.
