# Operator embeddings workflow

Use this guide when setting up or maintaining vector search from the GraphMem operator dashboard.

## 1. Configure

1. Sign in at `/operator/login`.
2. Open **System Settings → Embeddings** (`/operator/settings?tab=embeddings`).
3. Set URL, model, provider, and dimensions as needed. Leave fields blank (or dims `0`) to defer to environment variables.
4. Save. The embeddings page shows each value with a source badge (AppSettings / ENV / Default).

## 2. Test connection

On the settings tab or the **Embeddings** page (`/operator/embeddings`), click **Test connection**. Fix URL/model/dimension mismatches before backfilling.

## 3. Backfill missing embeddings

When vector columns exist but records lack embeddings:

1. Open **Embeddings** → **Backfill missing** (or enable scheduled backfill in settings).
2. Monitor **Background Jobs** at `/operator/jobs`.
3. The last job result appears on the embeddings page when complete.

## 4. Add ANN indexes

When coverage is 100% and no NULL embeddings remain:

1. Click **Add ANN indexes** on the embeddings page (or run `bin/rails embeddings:add_indexes`).
2. Confirm the **Vector search ready** indicator turns **Yes**.

## 5. Verify search

Use MCP `search_entities` or the web search UI. Hybrid search uses vectors when indexes are active.

## Changing model or dimensions

After changing model or dims in settings or ENV:

1. Test connection.
2. **Regenerate all** embeddings (destructive to existing vectors; required when dimensions change).
3. Drop and re-add indexes if column definitions must change.

## CLI equivalents

| Operator action | Rake task |
|---|---|
| Test connection | `embeddings:check` |
| Backfill | `embeddings:backfill` |
| Regenerate | `embeddings:regenerate` |
| Add indexes | `embeddings:add_indexes` |
| Drop indexes | `embeddings:drop_indexes` |

All rake tasks use the same `EmbeddingConfig` resolution as the UI.
