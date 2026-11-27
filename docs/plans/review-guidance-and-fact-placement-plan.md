# Plan: Review guidance and fact placement

> Status: built in 1.96.1, 2026-11-27 (see "As built (1.96.1)"). Draft written on `main` at 1.96.0. Steve asked for it on 2026-11-26 after an
> "Outdated by a fact" row he couldn't place. He agreed to items 1-4 and asked for the plan once Dream
> State R1b shipped. He answered the plan's four questions on 2026-11-27 (see "Answers"). The plan has
> one PR and one kickoff.

## Context

An "Outdated by a fact" row on Review & Fix paired two facts with nothing in common:
- a source fact about how entity deletes take the membership lock, written from `docs/architecture.md`;
- an agent's fact about a test-driver fix.

Both are held by the same Project entity. The LLM judge said `superseded` (confidence 0.7) and offered a
replacement that made no sense. The legacy guard disagreed in red ("context: names a version the fact
doesn't"). The card offered **Supersede…**, **Retire…**, **Dismiss** and **Snooze 30 days**, with nothing
saying what each does. Dismiss was right: nothing changes, and the pair isn't proposed again.

Why the pair reached the judge at all:
- **Keyword paths can't separate them.** `FactKeywords::Relatedness` reads a fact held by a Project root
  as about the whole project. Two facts on one entity that mention no other entity are compared by their
  LLM words instead (1.83.0).
- **The words said "unrelated" and nothing came of it.** These two shared no LLM word, but an answer from
  words alone is soft on purpose: words are asked per fact and can name one subject two ways (Steve,
  1.83.0). So the pair was judged, the judge was wrong, and the guard alone kept the row from auto-apply.
- **The skill puts every source fact there.** It says to write a source fact "on the project's entity".
  So each one lands on the root, where keyword paths can't tell it apart from any other root fact.

## Measurements (production graph, 2026-11-27, read-only, counts only)

| What | Count |
|---|---|
| "Outdated by a fact" rows: approved / dismissed / pending | 1 (its facts are gone since) / 329 / 3 |
| Dismissed rows the NoSharedSubject policy closed, by reason: "share no subject" / "not the same fact" | 112 / 158 |
| Dismissed rows whose facts are gone (Dangling, not comparable now) | 59 |
| Pairs on one entity with no mentions and **no shared LLM word** (words-unrelated): approved / dismissed / pending | **0 / 66 / 1** (all 66 unjudged and closed by the policy; the 1 pending is judged: the row above) |
| Contradiction rows that are words-unrelated: approved / dismissed | 0 / 6 |
| Contradiction rows that are words-related: approved / dismissed / pending | 10 / 43 / 3 |
| Active facts / held by a Project root | 3,701 / 433 (12%) |
| Root-held active facts mentioning no other entity / one / two or more | 407 / 20 / 6 |
| Active source facts / held by a Project root | 86 / **67 (78%)**, none of them mentioning another entity |

What they say:

- **Words-unrelated fact pairs have never been right.** That's 0 of 67 for "Outdated by a fact" and 0 of
  6 for contradictions. The words-related ones are another matter: 10 contradictions were approved.
- **These rows reach the operator only when the judge is wrong.** The policy closes unjudged ones. A
  judged one stays, because a judged row is never dismissed for being related (1.82.0) and words-unrelated
  isn't "unrelated" (1.83.0).
- **Source facts sit on the root because the skill says so.** Elsewhere only 12% of facts are on a root.
- **Moving root facts afterwards can't do much.** 407 of the 433 root facts name nothing to move them to.
  The lever is where agents write, not a later cleanup.

## 1. A caption under each Review button

- **Where:**
  - the detail card's actions (`app/views/review/_detail.html.haml`);
  - the buttons that kind cards render themselves:
    - "Outdated by a fact": Supersede… and Retire…;
    - `relation_retype`: Move and Keep;
    - contradiction: Keep this (one per side), and "Both are right", which is Dismiss there;
  - the preview cards' confirm writes: Apply on `_preview_card.html.haml`, and Supersede / Retire on
    `_fact_supersede_apply.html.haml`. They need their own key, `ui.review.actions.<kind>.confirm`,
    because the "Apply…" caption describes the preview step, not the write;
  - the group cards' bulk actions: Apply high-confidence, Dismiss all and Snooze 30 days on
    `_group_card.html.haml`, and the confirm on `_group_preview_card.html.haml`.

  The list rows (`_row.html.haml`) stay one line. They get the same text as a `title` only. Their
  contradiction link, "Choose a side", opens the card.
- **What:** one short line per action and kind, under the buttons, saying what happens. It is visible
  text, not a hover tooltip: tooltips are easy to miss and don't work on touch. Each caption is tied to
  its button with `aria-describedby`.
- **Wording:** locale keys `ui.review.actions.<kind>.<action>`, with a default per action. Drafts, to be
  checked against each applier when built:
  - **Dismiss** (default): "Not right: nothing changes, and this suggestion isn't made again (Restore
    brings it back)."
  - **Snooze 30 days:** "Not now: hidden for 30 days, then shown again."
  - **Supersede…** ("Outdated by a fact"): "Replaces #ID with the text you edit; the old fact stays as
    history, and Undo brings it back."
  - **Retire…** ("Outdated by a fact"): "Marks #ID obsolete, with no replacement."
  - **Both are right** (contradiction): "Both facts stay; the pair isn't flagged again."
  - **Apply…** (default): "Shows what applying changes before anything is written."
  - **Restore:** "Brings the suggestion back as pending."
- **Spec:** every action button has a caption, either a kind-specific key or the action's default. It
  covers:
  - each kind's detail and preview cards (including the confirm writes);
  - the group cards.

  So a later button can't ship without one.

## 2. A hint when a guard fires

- **Where:** the "Outdated by a fact" card, under `Guard: context (…)`
  (`app/views/review/kinds/_fact_supersede.html.haml`).
- **What:** "The guard disagrees with the judge: this fact names a version, an environment or a work log
  that the source fact doesn't. Old isn't wrong, so Dismiss unless the source fact really replaces it."
  - **Wording:** it uses the card's own label for the left side. On a contradiction-fallback row (origin
    `FactSupersede::ContradictionFallback::ORIGIN`), that side is a "Newer observation", not a source
    fact.
  - **The `keep` guard** needs no hint: such rows are never proposed.
- **Also:** the same hint goes in front of the judge's suggested replacement when a guard fired, since a
  replacement written across a guard is the likeliest to be nonsense. It shows in two places:
  - on the card's "Suggested replacement" line;
  - above the preview's pre-filled textarea (`_fact_supersede_apply.html.haml`), where the replacement
    actually gets written.

## 3. Skip pairs that only the LLM words call unrelated (any one entity)

- **Today:**
  - `FactSupersede::Proposals` neither judges nor proposes a pair the keyword paths call unrelated
    (`Candidate#unrelated?`: paths unrelated and no search term matched).
  - A words-unrelated pair is still judged, and proposed when the verdict is `superseded`.
  - The NoSharedSubject policy dismisses such a row only while it is unjudged.
- **Change:**
  - Treat a words-unrelated pair like a path-unrelated one: not judged, not proposed, and an existing row
    of that kind dismissed by NoSharedSubject, judged or not.
  - A search-term match still overrides, as it does for path-unrelated pairs.
  - The words-related case doesn't change.
- **Scope (Steve, 2026-11-27): any one entity**, not only a Project root. The data has 0 right out of
  67, and the typical case is a Conventions entity holding many unrelated rules.
- **Contradictions are not part of it.** The 6 words-unrelated contradiction rows predate today's
  detector gates, and the words-related ones are useful (10 approved).
- **Where:** a sibling predicate on `FactKeywords::Relatedness::Comparison`, such as `words_unrelated?`
  (`subject == :unrelated && by_words`). Two places use it, so the generator and the policy stay in step:
  - `FactSupersede::Candidates#candidate_subject`, which today maps that case to `:unknown` before
    `Candidate#unrelated?` sees it;
  - `ReviewPolicies::SubjectCheck.fact_supersede_status`.

  `hard_unrelated?` and the contradiction path stay as they are. These rows get their own dismissal
  reason, a new constant: "the facts' LLM words share nothing (one entity, no mentions)".
  `resolution_reason` isn't part of the MCP output, so the new string is UI-only.
- **Specs:** the row from the Context section, in synthetic form, is neither judged nor proposed. A
  pending judged row of that shape is dismissed by the policy. A words-related pair is unchanged. A term
  match still proposes.

## 4. Where agents write facts (skill and prompt text)

**Today:**
- `skills/graph-mem-mcp-toolset/SKILL.md` ("Persist") puts source facts "on the project's entity". Its
  "Homes" bullet names User Preferences, `<Project> Conventions` and "environment facts on the entity they
  describe".
- The `persist` prompt (`app/prompts/persist_prompt.rb`) says nothing about source facts. Its step 4
  names the same homes as SKILL.md's "Homes" bullet, so the source-fact sentence is new there, not
  reworded.
- `AGENTS.md`'s graph_mem section and `docs/rules/` say nothing about placement, and they stay as they are
  (12-line limit, `agent_text_sync_spec`).

**Changes, in SKILL.md and the `persist` prompt:**
- **Source facts:** "on the entity the changed statement is about (a component, feature or configuration
  entity of the project: search for it, and create it `part_of` the Project if it doesn't exist); on the
  Project entity only for a statement about the whole project."
- **Other facts:** "on the most specific existing entity they are about, not on the Project entity".
  Conventions stay on `<Project> Conventions`.
- **Hierarchy**, kept shallow: "Project → Component or Feature → Task or Issue, three levels at most. An
  Issue goes `part_of` the component it is about, its fix is a PossibleSolution that `solves` it, and you
  search before creating."

**Surface:**
- No tool, parameter or schema change, and the MCP snapshots are untouched: prompt text isn't
  snapshotted.
- The `persist` prompt's text is MCP-visible, though. Steve approved changing it together with
  SKILL.md on 2026-11-27.

**Checks and measuring:**
- SKILL.md stays within `agent_text_sync_spec`'s limits and passes `skills-ref validate`.
- A spec asserts that SKILL.md and the `persist` prompt carry the same placement rule, for example the
  sentence that keeps the Project entity for whole-project statements, so the two texts can't drift.
- **Measure after**, counts only, about two weeks after the release:
  - the share of new source facts held by a Project root (78% today);
  - the share of new facts held by a root (12% today);
  - the new "Outdated by a fact" rows by relatedness class.
- **An adoption-eval run** follows the wording change (Steve, 2026-11-27). It needs his MCP token and
  config, so he starts it. The PR describes the session to run: a task that changes a doc, and what to
  look for (the source fact lands on a component entity, not the root). It also gives the counts query
  to read the result with.

**Not doing:** a dream-state step that moves root facts onto the entity they mention. Only 20 of 433 root
facts have such a target.

## As built (1.96.1)

- **Item 1, captions.** `ReviewHelper#review_action` (a row's action) and `#review_captioned` (any
  caption, the group cards' too) put the caption under the button with `aria-describedby`;
  `#review_action_caption` reads `ui.review.actions.<kind>.<action>`, else `ui.review.actions.default.<action>`.
  - Default actions: `preview` (Apply… and Repair…), `confirm` (the confirm card's write), `apply_now` (a
    safe kind's list-row Apply), `dismiss`, `snooze`, `restore`, `cancel`, `save` and `choose` (the list
    row's link of a choice kind). Kind keys: contradiction `keep`, `dismiss`, `choose`; fact_supersede
    `supersede`, `retire`, `dismiss`, `choose`, and `confirm_supersede` / `confirm_retire` (one kind with
    two writes, so two confirm keys); relation_retype `move`, `keep`; relation_review `dismiss`;
    delete_entity `confirm`; and the kind `group` (`apply_high`, `open`, `dismiss_all`, `snooze`,
    `confirm_apply`, `confirm_dismiss`, `confirm_snooze`).
  - Written from the services, not the drafts: Dismiss always suppresses the row's signature (every row
    has one), so it isn't made again until Restore; Snooze hides it for 30 days and the next policy run
    after that reopens it; Restore lifts the suppression but leaves an applied change applied (Undo
    reverts that); a delete_entity confirm can't be undone.
  - Besides the plan's buttons: Save (an editable kind) and the group card's Review link have captions,
    so every `.ui-btn` of the cards has one. The group cards show them visibly, in the digest and in the
    grouped lists alike (one partial); the list rows and the resolved list's Restore carry a `title`.
  - `spec/requests/review_action_captions_spec.rb` seeds a pending row of every kind the classifier names
    (relation_retype as retype, choice, swap and add), follows each detail card's preview links, and
    checks every `.ui-btn` of the detail, confirm, group and group confirm cards.
- **Item 2, guard hint.** `ReviewHelper#review_guard_hint`, for a `context` guard only: under the Guard
  line, in front of the suggested replacement, and above the confirm card's pre-filled text (supersede
  only). It leads "The guard disagrees with the judge:" on a `superseded` verdict and "… with this
  proposal:" on an unjudged row, and says "newer observation" instead of "source fact" on a
  contradiction-fallback row.
- **Item 3, words-unrelated pairs.** `Comparison#words_unrelated?` (`subject == :unrelated && by_words`)
  is read by `FactSupersede::Candidates#candidate_subject` (now `:unrelated`, so `Candidate#unrelated?`
  skips it unless a term matched) and by `ReviewPolicies::SubjectCheck` (`fact_supersede_status`
  dismisses it judged or not; `reason` gives the new `REASON_NO_SHARED_WORD`). `hard_unrelated?` and the
  contradiction branch are unchanged, and `FactSupersede::ContradictionFallback` needs nothing: its
  pairs are `:unknown` ones, which a words-unrelated pair isn't. The read-only `review_report` task
  counts the new reason on its fact_supersede line. Two existing examples changed with the rule
  (`keywords_spec`, `no_shared_subject_spec`: Steve's 1.83.0 "still judged" rule, now reversed);
  `spec/services/fact_supersede/words_unrelated_spec.rb` covers the rest.
- **Item 4, placement text.** SKILL.md's Homes bullet now ends on "every other fact on the most specific
  existing entity", a new bullet gives the shallow tree, and the source-fact bullet places the fact
  on the entity the statement is about. The persist prompt's step 4 carries the same sentences (its
  description, the snapshotted part, is unchanged). `spec/prompts/persist_placement_spec.rb` checks
  that both texts hold the same rule sentences.
- **Measuring:** the PR body has the adoption-eval session and the counts query (`bin/rails runner -`,
  read-only, counts only).

## Order, size and version

- **One PR with items 1-4.** It is roughly 500-900 lines with specs, mostly views, locale and policy.
  There is no migration, no new setting and no tool, parameter or schema change.
- **Version: 1.96.1** (Steve, 2026-11-27), a patch: guidance, a tighter generator and text. Dream State
  R2 stays 1.97.0 and the vector plan's steps 2-4 stay 1.98.0. The kickoff confirms against `version.rb`.
- **Docs:**
  - `docs/guides/ui-guide.md`: the captions and the guard hint;
  - `docs/dream_state.md` or `docs/summarization.md`, wherever "Outdated by a fact" and NoSharedSubject
    are described: item 3;
  - `docs/mcp_tools.md`: the source-fact placement;
  - the CHANGELOG.

## Answers (Steve, 2026-11-27)

1. **Item 3's scope:** any one entity, not only a Project root.
2. **Item 4's `persist` prompt:** its text changes together with SKILL.md.
3. **Item 4's check:** the counts after two weeks, plus an adoption-eval run that Steve starts.
4. **Version:** 1.96.1.

## What stays out

- No change to the judge, the legacy guard or the contradiction detector.
- No automatic move of existing facts.
- Nothing weakens the `/mcp` lockdown, the anonymizer or the cloud gate.
