# Contradiction Detection

GraphMem can flag candidate contradictions between active observations. This is a review tool: it does not modify observations automatically.

## How It Works

The `detect_contradictions` MCP tool and the `POST /api/v1/memory_entities/:id/memory_observations/detect_contradictions` REST endpoint scan an entity's active observations plus observations from 1-hop related entities. They look for pairs that are:

1. **Semantically similar** — cosine distance between their vector embeddings is below the `max_distance` threshold (default `0.35`).
2. **Polarity opposites** — one statement contains negative markers such as `not`, `never`, `deprecated`, `unsupported`, or `removed`, while the other does not.
3. **About the same thing** (1.78.0, with `fact_keywords_enabled` on) — since 1.82.0 the **same subject**: both mention entities and one fact's subjects (its own entity and the entities it mentions, `FactKeywords`) contain the other's. Applying a contradiction obsoletes one side, so being related (one shared mention among others) isn't enough any more. Since 1.85.0 two facts that mention no entity at all no longer make a contradiction: such a pair (very close, `ContradictionDetector::STRICT_MAX_DISTANCE`, 0.15) goes to fact supersede instead (below). Pending paths are computed first. Before 1.78.0, two close facts on one entity were paired whatever they were about, as long as one had a negative word ("It belongs to a User." against "It is not linked to a Team.").

4. **Not two events** (1.85.0) — two facts that both start with a date (`[2026-08-26] …`, a release note or work log) are events, and two events don't contradict.
5. **Not about another project** (1.85.0) — a shared mention counts only when it names something in the facts' own projects: two facts of one owner that only share a mention of another Project root (a shared engine, say) aren't a contradiction pair; the judge decides them through the fallback below. Facts held by two different Project roots compare as unrelated.

**The no-mention fallback (1.85.0).** In production most contradiction rows came from the 0.15 fallback, and the real ones among them were all "a newer procedure replaces the older one". The scheduled stale scan sends those pairs through fact supersede's own filters (`FactSupersede::ContradictionFallback`): skipped while either side's LLM words are pending, across projects, or when `LegacyGuard` keeps the older one; then the judge (task `judge`), with the newer observation as the fact, at most 10 calls per scan. Only a `superseded` verdict queues a `fact_supersede` row (payload `origin: "contradiction_fallback"`). Applying it retires or supersedes the older observation and names the newer one in the obsolete reason (it isn't a tagged source fact, so it isn't recorded in `outdated_by`, and the row is never auto-applied). The `detect_contradictions` tool returns real contradiction pairs only.

When a candidate is found, it is returned with a `confidence` score and written as a `contradictions` `MaintenanceReport` for operator review. Review rows show both keyword paths, the shared names in bold, computed when the row is shown (nothing about the paths is stored in the row, which MCP review tools return verbatim).

## Triggering Detection

- **MCP**: `detect_contradictions(entity_id, max_distance: 0.35, max_results: 20)`
- **REST**: `POST /api/v1/memory_entities/:memory_entity_id/memory_observations/detect_contradictions?max_distance=0.35&max_results=20`

The feature requires vector embeddings and the `enable_contradiction_detection` setting (enabled by default). If vectors are unavailable or the flag is disabled, the tool returns an empty candidate list.

## Review

Contradictions are stored as `MaintenanceReport` records with `report_type: "contradictions"`. Use the existing `get_maintenance_reports` tool or `GET /api/v1/maintenance/reports` endpoints to review them and decide which observation to keep, supersede, or obsolete.

## Limitations

- Polarity detection is a keyword heuristic, not natural-language inference.
- Detection is limited to the target entity and its 1-hop neighbors.
- High vector similarity does not guarantee a contradiction; candidates should always be reviewed.
- Keyword paths only know the project's entities: two facts about the same concept that no entity names count as "mention nothing". Since 1.85.0 they never make a contradiction pair; within the strict distance they go to fact supersede's judge (the fallback above).
