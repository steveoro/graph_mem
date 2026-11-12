# GraphMem main future development ideas:

## Management UI
- [Superseded?] A quick report on duplicated observations, so that we can clean them easily with a single click. Duplicated observations have same source and target entities and same relation type. Investigate if the current implementation of the Garbage collector already handles this.
- Add a statistic report page given by GetGraphStatsTool

## Search UI
- [Done?] A "smart search" that interprets numbers as entity IDs (rank 1), and generic text strings as entity names (rank 2), aliases (rank 3), or descriptions (rank 4).

## Background jobs
- A scheduled run can overlap a queued `FactKeywordsJob` (noted in #170, 1.84.0). "Run all scheduled jobs now" runs its steps with `perform_now`, which skips the job's `limits_concurrency`. A `FactKeywordsJob` queued by an agent's write can therefore run at the same time and ask the LLM about the same pending facts twice. That wastes LLM calls but loses no data. The longer uncapped LLM-word walk makes the window wider. Possible fixes: take the same concurrency key inside the scheduled step, or have the queued job skip while a scheduled run is on its Fact keywords step.
