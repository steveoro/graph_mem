# App Settings Reference

GraphMem stores operator-tunable runtime settings in the primary MariaDB `settings` table via [`rails-settings-cached`](https://github.com/huacnlee/rails-settings-cached) and the `AppSettings` model.

## Operator UI

- **URL:** `/system/settings` (one tab per group); the backup group is on `/system/backups`. The groups, labels, types, ranges and validators all come from `SettingsSchema` (`app/services/settings_schema.rb`), and a save writes only the posted group's keys: an invalid value answers `422` with the field marked and nothing saved. `project_scan_roots` is the one legacy key in no group (`SettingsSchema::LEGACY_KEYS`). The old `/operator/settings` URL redirects (301) until §6.D-6.
- **Auth:** session login at `/operator/login` (`OPERATOR_USERNAME` / `OPERATOR_PASSWORD`, or `credentials.operator.username` / `credentials.operator.password`). The same form signs in the optional read-only guest (see `enable_guest_access` below); guests can't open the settings.
- **Tabs:** Feature Flags, Embeddings, Summaries, Imports, Project Scans, Telemetry & retention, Review policies, Access. **Backups** has its own page.

## Feature Flags

| Setting | Default | Effect |
|---|---|---|
| `enable_dream_state_compactor` | `true` | When `false`, `DreamStateCompactionJob` and manual compaction start are skipped. |
| `enable_garbage_collector` | `true` | When `false`, `GarbageCollectionJob` and manual GC runs are skipped. |
| `enable_stale_memory_scan` | `true` | **Stale memory scan.** When `false`, the scheduled scan that flags stale observations for review is skipped. |
| `enable_contradiction_detection` | `true` | **Contradiction detection.** When `false`, the contradiction detector (in the stale memory scan and the `detect_contradictions` endpoint) finds no pairs. |

`enable_guest_access` is on the **Access** tab (see [MCP Access](#mcp-access)).

Boolean flags consumed by background workers use direct database reads so Solid Queue processes see UI changes without restart.

## Database Backup

On **System › Backups** (`/system/backups`), with **Run backup now** and the files. **Restore** asks you to type the file name again (checked on the server: a mismatch answers `422` and restores nothing); **Delete** asks for a confirmation.

| Setting | Default | Effect |
|---|---|---|
| `backup_folder_path` | `db/backup` | Relative to `Rails.root` or absolute path for `.sql.bz2` files. |
| `backup_keep_max` | `10` | Keep the N newest managed backups per environment (`*_<env>.sql.bz2`) after each successful dump. Legacy manually named files are not pruned. |
| `backup_schedule_cron` | from `recurring.yml` | Read-only display of `DatabaseBackupJob` schedules for the current environment. |
| `enable_scheduled_backups` | `false` | When `true`, `DatabaseBackupJob` runs on the production schedule in `config/recurring.yml` (1pm and 5pm GMT). |

### Rake tasks

- `bin/rails db:dump` — create `{YYYYMMDDHHMM}_{env}.sql.bz2`, then prune old files
- `bin/rails db:list_backups` — list backups for the current environment
- `bin/rails db:restore` — destructive restore (`FILE=` optional)

### Docker

Mount the host backup directory to match `backup_folder_path` (see `DB_BACKUP_HOST_PATH` in `docker-compose.yml`).

## Embeddings

| Setting | Default | Effect |
|---|---|---|
| `embedding_url` | `""` | Embedding server URL. Blank defers to `OLLAMA_URL` ENV. |
| `embedding_model` | `""` | Model name. Blank defers to `EMBEDDING_MODEL` ENV. |
| `embedding_provider` | `""` | `ollama` or `openai_compatible`. Blank defers to `EMBEDDING_PROVIDER` ENV. |
| `embedding_dims` | `0` | Expected vector size. `0` defers to `EMBEDDING_DIMS` ENV or default `768`. |
| `embedding_backfill_schedule_cron` | from `recurring.yml` | Read-only display of `EmbeddingScheduledBackfillJob` schedule. |
| `enable_scheduled_embedding_backfill` | `false` | When `true`, daily backfill job runs for records missing embeddings. |

Resolution order for runtime embedding config: **AppSettings → ENV → defaults** (`EmbeddingConfig`). Saving the Embeddings tab calls `EmbeddingService.reset_instance!`.

See [operator embeddings guide](operator/embeddings.md).

## Summaries

| Setting | Default | Effect |
|---|---|---|
| `enable_llm_summarization` | `false` | When `true`, `summarize` attempts LLM synthesis after building deterministic evidence. When `false`, only deterministic extractive output is returned. |
| `summary_url` | `""` | Text-generation server URL. Blank defers to `SUMMARY_URL`, then `OLLAMA_URL` ENV. |
| `summary_model` | `""` | Interchangeable model name (e.g. `qwen3:8b`). Blank defers to `SUMMARY_MODEL` ENV or default. |
| `summary_provider` | `""` | `ollama` or `openai_compatible`. Blank defers to `SUMMARY_PROVIDER` ENV or `ollama`. |
| `summary_timeout` | `0` | HTTP timeout in seconds. `0` defers to `SUMMARY_TIMEOUT` ENV or default `30`. |
| `summary_max_tokens` | `0` | Maximum generated output tokens. `0` defers to `SUMMARY_MAX_TOKENS` ENV or default `256`. |
| `summary_observations_per_entity` | `3` | Maximum observations selected per entity before capping. `0` disables the cap. |

Resolution order for runtime summarization config: **AppSettings → ENV → defaults** (`SummarizationConfig`). Saving the Summaries tab calls `SummaryGenerationClient.reset_instance!`.

The embedding model and summary model are independent. Retrieval continues to use `EmbeddingConfig`; summarization uses `SummarizationConfig`.

See [summarization guide](summarization.md).

## Imports

| Setting | Default | Effect |
|---|---|---|
| `import_observation_duplicate_max_distance` | `0.35` | Maximum semantic distance for treating imported observation text as an existing fact. Range `0.20` (strict) to `0.50` (broad). |

## Project Scans

| Setting | Default | Effect |
|---|---|---|
| `project_scan_subfolders` | `Projects` | Comma- or newline-separated folders, relative to the scan root, that may be scanned (e.g. `Projects, work/clients`). Read uncached on every scan request and at job start, so a change applies at once in every process. Blank = the whole scan root (hidden folders and secret files stay blocked). Replaces `project_scan_roots`, which is ignored and can be cleared from Settings. |

Every scan entry point (dashboard, `POST /api/v1/scan`, MCP `scan_project`, job start) resolves the path through `ScanRootPolicy`: the scan root comes from `GRAPH_MEM_SCAN_ROOTS` (in Docker, the read-only home mount) or natively `Dir.home`; `PROJECT_SCAN_ROOTS` is gone. See [container scan mounts](container_scan_mounts.md) and the [project scan skill](../skills/project-scan/SKILL.md) for the scan workflow.

## MCP Access

On the **Access** tab, with `enable_guest_access` (`true`: lets the read-only guest sign in; no effect until a guest password is set in `GRAPH_MEM_GUEST_PASSWORD` or credentials `guest.password`; when `false`, signed-in guests are signed out on their next request).

Additive parts of the three MCP allowlists (UI-2a). Each adds to its ENV variable, which the tab shows as read-only text and which can't be removed here. Read uncached by `GraphMem::McpAccessLists`; a save applies at once through `OfficialMcp.refresh_access!` (a hosts or origins change also closes open MCP sessions). Validated on save (any refused entry: `422`, nothing saved) and audited per changed key. Not secrets. See [MCP access control](mcp_access_control.md#adding-entries-at-runtime-settings--access).

| Setting | Default | Effect |
|---|---|---|
| `mcp_extra_allowed_ips` | `""` | Addresses or CIDR ranges appended to the effective `GRAPH_MEM_MCP_ALLOWED_IPS` list (the defaults when unset). `any`/`all`/`*` and a `/0` refused; public ranges only with `GRAPH_MEM_MCP_TOKEN`, and inactive while it is unset. Ignored when ENV allows any IP. |
| `mcp_extra_allowed_hosts` | `""` | Host names, IPv4 or IPv6 addresses, with an optional `:port`, added to `GRAPH_MEM_MCP_ALLOWED_HOSTS`. Loopback names are always accepted and not stored. |
| `mcp_extra_allowed_origins` | `""` | Exact `http(s)://host[:port]` origins added to `GRAPH_MEM_MCP_ALLOWED_ORIGINS`: accepted by the transport and granted CORS on `/mcp`. |

## Retention

Both settings are on the **Telemetry & retention** tab.

| Setting | Default | Effect |
|---|---|---|
| `compaction_review_row_retention_days` | `30` | Range 0-365. `MaintenanceReportRowCleanupJob` (daily, 5:15 AM GMT in production) deletes approved, dismissed and ignored review rows older than this; active rows are kept. `0` uses the default (30). |
| `tool_invocation_retention_days` | `90` | See [operator tool telemetry](operator/telemetry.md#retention-and-pruning). |

## Mission Control Jobs

- **URL:** `/system/queue` (System › Queue; `/operator/jobs` redirects until §6.D-6)
- **Auth:** same operator session (sign in at `/operator/login`)
- **Purpose:** inspect Solid Queue jobs, recurring tasks, and failures
