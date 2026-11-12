# GraphMem main future development ideas:

## Management UI
- [Superseded?] A quick report on duplicated observations, so that we can clean them easily with a single click. Duplicated observations have same source and target entities and same relation type. Investigate if the current implementation of the Garbage collector already handles this.
- Add a statistic report page given by GetGraphStatsTool

## Search UI
- [Done?] A "smart search" that interprets numbers as entity IDs (rank 1), and generic text strings as entity names (rank 2), aliases (rank 3), or descriptions (rank 4).

## Background jobs
- A scheduled run can overlap a queued `FactKeywordsJob` (noted in #170, 1.84.0). "Run all scheduled jobs now" runs its steps with `perform_now`, which skips the job's `limits_concurrency`. A `FactKeywordsJob` queued by an agent's write can therefore run at the same time and ask the LLM about the same pending facts twice. That wastes LLM calls but loses no data. The longer uncapped LLM-word walk makes the window wider. Possible fixes: take the same concurrency key inside the scheduled step, or have the queued job skip while a scheduled run is on its Fact keywords step.

## Carried over from the done plans (open, not scheduled)
These were still open when their plans moved to `docs/plans/done/`:
- **Agent memory eval (AR-E)**, and AR-F text fixes only if the eval shows the new texts doing worse: `docs/plans/done/agent-rules-plan.md` §8. Nothing under `eval/` yet.
- **AR-D4 docs follow-ups:** `docs/plans/done/agent-rules-plan.md` §D.
- **D-4 dead UI code:** the `dm-*` rules in `app/assets/stylesheets/graph.css` and the other leftovers listed in `docs/plans/done/ui-dashboard-plan.md` §6.D.
- **D-8 tool description length spec:** a spec capping every registered tool's description (`docs/plans/done/ui-dashboard-plan.md` §6.D).
- **UI-8 polish:** command palette, saved searches, dark mode (the light/dark theme switch), keyboard help overlay, activity feed filters (`docs/plans/done/ui-dashboard-plan.md` §6 UI-8 and §7).
