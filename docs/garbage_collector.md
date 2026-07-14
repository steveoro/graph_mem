# Garbage Collector

GraphMem's **garbage collector** is a scheduled maintenance job that scans the knowledge graph for hygiene issues, writes diagnostic reports, deletes duplicate observations, and prunes old audit logs. It is **non-destructive toward entities and relations**, but it actively repairs `MemoryObservation` duplicates and `memory_observations_count` counters. Operators and MCP clients use its reports to decide what else to clean up manually—or rely on the separate [dream-state compactor](dream_state.md) for automated graph compaction.

## Purpose

Over time, agent sessions can leave behind:

- **Disconnected entities** — nodes with no observations and no relations at all
- **Duplicate observations** — the same text stored more than once on one entity
- **Stale audit history** — change logs that exceed the retention window

The garbage collector surfaces orphans as `MaintenanceReport` records and performs the automatic cleanups it is allowed to do: deleting duplicate observations, repairing `memory_observations_count` counters, and deleting expired `AuditLog` rows.

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
        ├── cleanup_duplicates  → MaintenanceReport (type: duplicates)
        └── prune_audit_logs    → AuditLog.prune! (90-day retention)

`GraphIntegrityService` (called by `GarbageCollectionJob` and before a new dream-state run) wraps `GarbageCollectionRunner` plus `RelationIntegrityRepairer` and a full counter recount.
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

### 2. Duplicate observation cleanup (`cleanup_duplicates`)

Scans `MemoryObservation` grouped by `(memory_entity_id, content)`. Groups with `COUNT(*) > 1` are cleaned by deleting every row except the lowest `id` for that group.

Each reported group includes:

- `entity_id`
- `content_preview` — truncated to 100 characters
- `count` — original number of duplicate rows
- `deleted_count` — total duplicate observations removed across all groups

The counter cache on affected entities is repaired after deletion. This keeps the graph healthy even if a dream-state run failed before it could finish deduplication.

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
| **Mutates graph?** | Yes (duplicate observations + counters) | Yes — parents orphans, dedupes observations, auto-merges entities |
| **Orphan definition** | No observations **and** no relations | No incoming `part_of`/`depends_on` (non-Project) |
| **Duplicate observations** | Deletes duplicates, keeps lowest id | Deletes byte-identical duplicates |
| **Schedule (production)** | 2:00 PM GMT daily | 3:00 AM GMT daily |
| **MCP status tool** | — | `dream_state_status` |

Use the garbage collector for periodic **visibility** into graph health. Use dream-state compaction for **automated cleanup** with a human review queue for ambiguous cases.

## Typical operator workflow

1. Review dashboard stat chips after the daily run (or click **Run now**).
2. For orphan reports, inspect sample entities in the dashboard details panel or via `get_maintenance_reports`.
3. Decide whether to delete empty stray nodes (web UI / `delete_entity`) or attach them to a project (`merge_entities`, relation tools, or let dream-state handle high-confidence matches).
4. For duplicate reports, the GC has already removed duplicates; review the report if any edge cases remain.
5. Audit log pruning requires no action; it runs automatically every GC pass.
