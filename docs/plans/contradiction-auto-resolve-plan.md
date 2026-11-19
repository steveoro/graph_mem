# Plan: auto-resolve value-flip contradictions (one PR)

> Status: approved by Steve on 2026-11-19, not started. Written against `main` at 1a16c22 (1.91.0).
> Release: the **next minor** after `main` at release time. With `main` on 1.91.x that is **1.92.0**:
> this is one small PR and is expected to ship before the SQL exchange's release PR (four PRs), which
> then takes the following minor. If `main` already reads 1.92.x, this ships as 1.93.0. Minor, not
> patch: it adds a review policy and three settings.

## Context

The stale-memory contradiction pass pairs two active observations on one entity when they are close
(cosine distance < 0.35), one holds a negative marker and the other doesn't, and their keyword paths
(or LLM words) say they are about the same subject. A common case is the same fact with a flipped
value, written twice over time:

```
#101 SynthFeature  "Enabled: false"     (older)
#103 SynthFeature  "Enabled: true"      (newer)
distance 0.09 · confidence 0.99
```

Facts found on `main` (file:line at 1a16c22):

- The pair's **confidence is distance only**: `min((1 - distance) * 1.1, 0.99)`
  (`app/services/contradiction_detector.rb:319-323`), so any pair closer than about 0.1 reads 0.99.
  Polarity is only a filter (`:280`, `NEGATIVE_MARKERS` `:36-40` include `false`). No LLM judges a
  contradiction row.
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

Goal: resolve this narrow case unattended (opt-in), make the card show *what* differs, and stop the
"LLM:" label reading like a status.

## Decisions (Steve, 2026-11-19)

1. Off by default; an operator turns it on in Settings › Review policies.
2. Keep the newer side; the older one is **superseded by** the newer one (link set), with a reason,
   audited, undoable with the run.
3. MCP surface unchanged: `apply_maintenance_review` and the UI **Keep this** keep marking obsolete.

## A. Policy `ReviewPolicies::AutoApplyContradiction`

New `app/services/review_policies/auto_apply_contradiction.rb`, modelled on `AutoApplyFactSupersede`:

- `< AutoApply`; `applicable_kind?` lifts the hard rule for `"contradiction"` only (every other choice
  and destructive kind is still refused); `PER_RUN = 100`.
- `eligible`: active `contradiction` rows; each row is checked against the **live** observations
  (the payload's text is truncated and may be stale). A row qualifies only when all hold:
  1. both observations exist and are `active`;
  2. same `memory_entity_id`;
  3. same `source` and same `perspective` (NULL equals NULL);
  4. cosine distance (payload `distance`, re-read live with `VEC_DISTANCE_COSINE` when both are
     embedded) `<= auto_apply_contradiction_max_distance`;
  5. `FactKeywords::TokenDiff.value_flip?(a.content, b.content, max_tokens:)` (section C) is true;
  6. one side is clearly newer (below); a tie skips the row.
- **Newer side**: compare `valid_from` when both are set and differ; otherwise `created_at` when they
  differ; otherwise `updated_at` when they differ; otherwise tie → skip (counted as `skipped`).
- Act: overrides `with_locked_row` to call
  `CompactionReviewService.apply(row.row_uuid, { keep_observation_id: newer.id }, report_type: row.report_type, resolution: :supersede)`.
  - New keyword `resolution:` (default `:obsolete`) on `CompactionReviewService.apply` →
    `apply_row` → `CompactionReviewApplier.apply` → `CompactionReviewApplier::Contradiction.apply`.
    It is a Ruby keyword, never read from `action_params`, so the MCP tool and the UI can't reach it.
  - With `:supersede`, `Contradiction.apply` calls `older.supersede_with!(newer, reason: ...)`
    (`app/models/memory_observation.rb:178-195`) instead of `mark_obsolete!`. Reason:
    `"Superseded by observation #<newer> (auto-resolved contradiction: <old tokens> → <new tokens>)"`.
  - The eligibility is re-checked inside the row lock before writing (an operator action in between
    wins, as in `ReviewPolicies::Base`).
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
  (`"auto_apply_contradiction" => ["enable_auto_apply_contradiction", false]`); update the
  `CHOICE_KINDS` comment (`app/services/review_row_classifier.rb:23-24`). "Run policies now" and the
  nightly run pick it up through the runner.

### Settings (no migration: `AppSettings` is rails-settings-cached, `app/models/app_settings.rb:3-4`)

| Setting | Default | Range |
|---|---|---|
| `enable_auto_apply_contradiction` | `false` | — |
| `auto_apply_contradiction_max_distance` | `0.10` | 0.02–0.15 |
| `auto_apply_contradiction_max_tokens` | `2` | 1–3 |

Added to `REVIEW_NUMBERS`, the Review policies settings group, `config/locales/system_settings.en.yml`
(label + description) and `docs/app_settings_reference.md`. No confidence threshold: a contradiction's
confidence is a function of its distance, so the distance cap is the honest knob.

## B. UI

- Label: `ui.review.keyword_path.llm_words` "LLM:" → **"LLM topic:"** (`config/locales/ui.en.yml:37`),
  and the entity panel's `explore.panel.llm_words` (`config/locales/explore.en.yml:64`) the same, so the
  two places read alike. `en` is the only locale. Update the one spec asserting the old text
  (`spec/requests/review_keyword_paths_spec.rb:60`).
- Contradiction card (`app/views/review/kinds/_contradiction.html.haml:12`): when
  `FactKeywords::TokenDiff.diff(a, b)` finds 1–`TokenDiff::HIGHLIGHT_MAX` (3) differing tokens per
  side, each side's text is rendered with its differing tokens wrapped in `<mark>`; otherwise the text
  renders as today. The helper (`ReviewHelper#review_diff_text`) escapes the text and builds the marks
  with `safe_join`/`tag.mark`, never `html_safe` on content; it keeps the 300-character cut (a mark
  past the cut is dropped).
- Style: `.review-contradiction mark` uses the existing convention from
  `app/assets/tailwind/search.css:216-220` (`background: var(--color-ui-warn-soft); color: inherit;
  border-radius: 2px;`), added in `app/assets/tailwind/application.css` next to `.review-contradiction`
  (`:538`). Accessibility: colour is not the only cue — each side also gets a visually hidden line
  ("Differs: false → true", a `review-sr-only` class like `system-sr-only` in
  `app/assets/tailwind/system.css:524`), and contrast stays that of normal text.

## C. Shared helper `FactKeywords::TokenDiff`

New `app/services/fact_keywords/token_diff.rb`, used by the policy gate and the view:

- Tokens: words and values with their character offsets; versions, decimals and numbers with units
  are one token (reuse `FactKeywords::Details::PATTERNS`, `app/services/fact_keywords/details.rb`);
  punctuation and whitespace separate tokens; comparison is case-insensitive.
- `diff(a, b)` → `{ left: [spans], right: [spans] }`: the tokens outside the longest common token
  subsequence on each side.
- `value_flip?(a, b, max_tokens:)`: true only when both sides differ in the **same number** of tokens,
  `1..max_tokens`, each differing token is a value (a boolean word from `true/false, yes/no, on/off,
  enabled/disabled`, or a number/version per `Details`), paired tokens are of the same class (boolean
  with boolean, number with number), and the texts are not dated events
  (`ContradictionDetector::DATED_EVENT`). An inserted "not" or any other word fails it.

## Specs (synthetic names only: `SynthFeature`, `SynthWidget`, "Enabled: false" / "Enabled: true")

- `spec/services/fact_keywords/token_diff_spec.rb`: booleans each way, numbers and versions
  (`"Timeout: 5s"`/`"Timeout: 10s"`, `"Uses v1.7.2"`/`"Uses v1.8.0"`), 2 tokens OK and 3 refused at
  max 2, inserted "not" refused, word change refused, boolean vs number refused, case-insensitive,
  offsets right for multibyte text, dated events refused.
- `spec/services/review_policies/auto_apply_contradiction_spec.rb`: setting off → nothing (and
  `"disabled" => true`); positive case → older `superseded` with `superseded_by_id` = newer, reason set,
  newer untouched, row approved, one audit row with actor `policy:auto_apply_contradiction`; negative:
  different entity, different source, different perspective, >2 tokens, distance over the cap, a tie
  on all three timestamps, newer by `valid_from` beating an older `created_at`, either side inactive,
  a non-contradiction kind still refused.
- Undo: the policy run's change set undone → older `active`, `superseded_by_id` NULL,
  `obsoleted_at`/`obsolescence_reason` NULL, row reopened; redo works.
- MCP unchanged: `apply_maintenance_review` on a contradiction row with
  `action_params: { keep_observation_id:, resolution: "supersede", supersede: true }` still marks the
  other side obsolete with no link; the tool snapshots and counts (12 / 9 / 22) are byte-identical.
- View/request: the card shows `<mark>` around `false` and `true`; no `<mark>` when more than 3 tokens
  differ; HTML in content stays escaped; "LLM topic:" label on the card and the entity panel.
- `spec/models/app_settings_spec.rb`: defaults and ranges of the three settings.

## CHANGELOG (`## [Unreleased]`, then the release entry)

- Added: **Auto-resolve value-flip contradictions** review policy (Settings › Review policies, off by
  default): a contradiction pair on one entity, same source and perspective, whose texts differ only
  in 1–2 value tokens (true/false, yes/no, on/off, enabled/disabled, numbers, versions) is resolved by
  keeping the newer observation and marking the older one superseded by it. Undo the run to revert.
- Added: the contradiction card highlights the tokens that differ between the two sides.
- Changed: the "LLM:" label on review cards and the entity panel reads "LLM topic:" (it names what a
  fact is about; it was never a status).

## Delivery

One PR, branch `claude/contradiction-auto-resolve`. No migration, no new gem or package, no MCP
surface change (tool params, outputs, descriptions and counts unchanged), nothing touching the
lockdown or the anonymizer/cloud gate. Expected diff about 600–900 lines with specs.

## Known limits

- Only pairs the contradiction pass already finds: a value flip without a negative marker
  ("Port: 3000" / "Port: 3001") is not paired today, so the policy never sees it.
- The newer-wins rule trusts timestamps; an older fact re-written later (a newer `created_at`) wins.
