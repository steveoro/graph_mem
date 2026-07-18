# App Settings Reference

GraphMem stores operator-tunable runtime settings in the primary MariaDB `settings` table via [`rails-settings-cached`](https://github.com/huacnlee/rails-settings-cached) and the `AppSettings` model.

## Operator UI

- **URL:** `/operator/settings`
- **Auth:** session login at `/operator/login` (`OPERATOR_USERNAME` / `OPERATOR_PASSWORD`, or `credentials.operator.username` / `credentials.operator.password`)
- **Tabs:** Feature Flags, Database Backup, Embeddings, Summaries

## Feature Flags

| Setting | Default | Effect |
|---|---|---|
| `enable_dream_state_compactor` | `true` | When `false`, `DreamStateCompactionJob` and manual compaction start are skipped. |
| `enable_garbage_collector` | `true` | When `false`, `GarbageCollectionJob` and manual GC runs are skipped. |

Boolean flags consumed by background workers use direct database reads so Solid Queue processes see UI changes without restart.

## Database Backup

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

## Mission Control Jobs

- **URL:** `/operator/jobs`
- **Auth:** same operator session (sign in at `/operator/login`)
- **Purpose:** inspect Solid Queue jobs, recurring tasks, and failures
