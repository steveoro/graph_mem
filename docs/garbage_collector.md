# Garbage Collector

GraphMem's **garbage collector** is a scheduled maintenance job that scans the knowledge graph for hygiene issues, writes diagnostic reports, and prunes old audit logs. It is intentionally **non-destructive toward graph data**: it does not delete entities, observations, or relations. Operators and MCP clients use its reports to decide what to clean up manually—or rely on the separate [dream-state compactor](dream_state.md) for automated graph compaction.

## Purpose

Over time, agent sessions can leave behind:

- **Disconnected entities** — nodes with no observations and no relations at all
- **Duplicate observations** — the same text stored more than once on one entity
- **Stale audit history** — change logs that exceed the retention window

The garbage collector surfaces the first two categories as `MaintenanceReport` records and performs the one automatic cleanup it is allowed to do: deleting expired `AuditLog` rows.

## Architecture

```
Solid Queue (recurring.yml)
        │
        ▼
GarbageCollectionJob
        │
        ▼
GarbageCollectionRunner
        ├── report_orphans      → MaintenanceReport (type: orphans)
        ├── report_duplicates   → MaintenanceReport (type: duplicates)
        └── prune_audit_logs    → AuditLog.prune! (90-day retention)
```

| Component | Location | Role |
|---|---|---|
| `GarbageCollectionJob` | `app/jobs/garbage_collection_job.rb` | Solid Queue entry point; checks the feature flag, then delegates to the runner |
| `GarbageCollectionRunner` | `app/services/garbage_collection_runner.rb` | Performs all scan and prune work in a single synchronous pass |
| `MaintenanceReport` | `app/models/maintenance_report.rb` | Persists report payloads; auto-prunes to 30 reports per type |

## What each step does

### 1. Orphan detection (`report_orphans`)

An entity is flagged as an **orphan** when **all** of the following are true:

- It has **no observations**
- It does not appear as `from_entity_id` in any relation
- It does not appear as `to_entity_id` in any relation

This definition is stricter than the dream-state "orphan" concept (see [dream_state.md](dream_state.md)). A node linked into the graph via `part_of` or `depends_on` but carrying no observations is **not** reported here.

The report stores:

- `count` — total orphans found
- `entities` — up to 100 sample rows (`id`, `name`, `entity_type`)

### 2. Duplicate observation detection (`report_duplicates`)

Scans `MemoryObservation` grouped by `(memory_entity_id, content)`. Groups with `COUNT(*) > 1` are reported.

Each reported group includes:

- `entity_id`
- `content_preview` — truncated to 100 characters
- `count` — number of duplicate rows

Again, this step **reports only**; it does not delete duplicate observations. The dream-state compactor handles byte-identical deduplication during its tree-walk phase.

### 3. Audit log pruning (`prune_audit_logs`)

Calls `AuditLog.prune!`, which deletes rows older than `AuditLog::MAX_AGE_DAYS` (90 days). This is the only mutating action the garbage collector performs on the database.

The runner returns `audit_logs_pruned` with the number of rows removed.

## Scheduling and configuration

### Recurring schedule

Defined in `config/recurring.yml`:

| Environment | Schedule |
|---|---|
| **production** | Daily at 2:00 PM GMT |
| **development** | Not scheduled (manual or operator trigger only) |

Solid Queue must be running for scheduled invocations to fire.

### Feature flag

| Setting | Default | Effect |
|---|---|---|
| `enable_garbage_collector` | `true` | When `false`, both `GarbageCollectionJob` and manual runs are skipped |

Toggle via **Operator → System Settings → Feature Flags** (`/operator/settings`). Workers read the flag directly from the database, so changes apply without restart.

See [app_settings_reference.md](app_settings_reference.md) for details.

## Operator controls

The home dashboard includes a **Garbage Collector** card showing:

- Counts from the latest `orphans` and `duplicates` reports
- Timestamps of the last run per report type
- A **Run now** button (`POST /operator/maintenance/garbage_collection/run`)

Manual runs require operator sign-in and respect the `enable_garbage_collector` flag.

## MCP and REST access

Garbage collector output is readable through maintenance APIs:

- **MCP:** `get_maintenance_reports` with `report_type: "orphans"` or `"duplicates"`
- **REST:** `MaintenanceController` endpoints (see [api/rest_api_reference.md](api/rest_api_reference.md))

There is no dedicated MCP tool to *trigger* garbage collection; use the operator dashboard or enqueue `GarbageCollectionJob` from the Rails console.

## Report retention

`MaintenanceReport` keeps at most **30 reports per `report_type`**. Older reports of the same type are deleted automatically on create. Sample payloads inside a report are capped at **100 entries** even when `count` is higher.

Valid report types today: `orphans`, `duplicates`, `compaction_review`, `embedding_maintenance`. The legacy `stale` type was removed in v1.8.1 when automatic "stale node" deletion was dropped in favor of protecting `Project` root entities.

## Garbage collector vs. dream-state compactor

| | Garbage collector | Dream-state compactor |
|---|---|---|
| **Goal** | Diagnose hygiene issues | Actively compact the graph |
| **Mutates graph?** | No (except audit logs) | Yes — parents orphans, dedupes observations, auto-merges entities |
| **Orphan definition** | No observations **and** no relations | No incoming `part_of`/`depends_on` (non-Project) |
| **Duplicate observations** | Reports only | Deletes byte-identical duplicates |
| **Schedule (production)** | 2:00 PM GMT daily | 3:00 AM GMT daily |
| **MCP status tool** | — | `dream_state_status` |

Use the garbage collector for periodic **visibility** into graph health. Use dream-state compaction for **automated cleanup** with a human review queue for ambiguous cases.

## Typical operator workflow

1. Review dashboard stat chips after the daily run (or click **Run now**).
2. For orphan reports, inspect sample entities in the dashboard details panel or via `get_maintenance_reports`.
3. Decide whether to delete empty stray nodes (web UI / `delete_entity`) or attach them to a project (`merge_entities`, relation tools, or let dream-state handle high-confidence matches).
4. For duplicate reports, either wait for dream-state deduplication or remove duplicates manually.
5. Audit log pruning requires no action; it runs automatically every GC pass.
