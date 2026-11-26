# Troubleshooting Guide

This guide addresses common issues you might encounter when working with GraphMem and provides solutions and workarounds.

## MCP Communication Issues

### Problem: MCP Client Cannot Connect to GraphMem Server

**Symptoms:**
- Connection refused errors
- Timeout when attempting to connect
- "Server not found" errors

**Possible Causes and Solutions:**

1. **Server Not Running**
   - Check if the GraphMem server is running
   - Start the server with `bin/rails server` or `bin/mcp`

2. **Wrong Connection URL**
   - Verify you're using the correct protocol, host, and port
   - Default URLs are:
     - Streamable HTTP (2024-11-05 … 2026-07-28): `http://localhost:3000/mcp` (also `/mcp/readonly`
       and `/mcp/maintenance`)
     - The legacy HTTP+SSE endpoints (`/mcp/sse`, `/mcp/messages`) were removed in 1.55.0 and answer `404`

3. **`403` on Every Request (Host or Origin Check)**
   - The MCP endpoint's DNS-rebinding protection accepts only `localhost`, `127.0.0.1` and `::1`
     in the `Host` header by default. A client reaching the server by another address or name
     (another machine on the LAN, a container name) gets `403`: add that host to
     `GRAPH_MEM_MCP_ALLOWED_HOSTS` (any port, or `host:port`) or in System › Access.
   - A browser-based client whose `Origin` is not the server's own gets `403` too: add its exact
     `scheme://host:port` to `GRAPH_MEM_MCP_ALLOWED_ORIGINS`. Non-browser clients send no `Origin`.
   - A browser client blocked by CORS (the console reports a missing `Access-Control-Allow-Origin`
     on `/mcp`) needs the same: its exact origin in `GRAPH_MEM_MCP_ALLOWED_ORIGINS`. Nothing else
     grants `/mcp` CORS.
   - `403` with `Remote IP not allowed` is the IP allowlist instead (`GRAPH_MEM_MCP_ALLOWED_IPS`).
     Both the connecting address and the one derived from `X-Forwarded-For` must be listed, so
     behind a reverse proxy, list the proxy's own address too (e.g. `172.16.0.0/12` in Docker).
     All three are described in [mcp_access_control.md](mcp_access_control.md).

4. **`-32600 Forbidden: Invalid Host header` from another machine on the LAN**
   - Cause: the `Host` the client uses in its URL (the server's LAN address or name, e.g.
     `http://192.168.1.10:3030/mcp`) isn't a loopback name and isn't listed, so the DNS-rebinding
     check refuses it.
   - Fixes, in order: start the stack with `bin/up`, which lists the host's name, `<name>.local` and
     LAN address; or add the name or address in System › Access (applies at once, no
     restart); or set `GRAPH_MEM_MCP_ALLOWED_HOSTS` in `.env`.
   - Follow-up symptom: after setting `GRAPH_MEM_MCP_ALLOWED_IPS` to a subnet, `localhost` stops
     working. A custom IP list replaces the defaults: include `127.0.0.0/8,::1` (and
     `172.16.0.0/12` in Docker), or remove the line and let `bin/up` build the list.

5. **Firewall Blocking Connections**
   - Check if your firewall is blocking the port
   - Allow connections to the relevant ports (3000 or 3030)

### Problem: MCP Requests Return Errors

**Symptoms:**
- JSON-RPC error responses
- HTTP 400/500 errors

**Possible Causes and Solutions:**

1. **Invalid JSON-RPC Format**
   - Ensure your requests follow the JSON-RPC 2.0 specification
   - Include required fields: `jsonrpc`, `method`, `params`, `id`
   - Example:
     ```json
     {
       "jsonrpc": "2.0",
       "method": "tools/list",
       "params": {},
       "id": 1
     }
     ```

2. **Unknown Tool**
   - `tools/call` with an unknown name answers `-32602` (`data`: `Tool not found: <name>`)
   - Tool names are case-sensitive snake_case (`graph_write`, not `GraphWriteTool`); the 18 aliases
     removed in 1.55.0 (`create_entity`, `search_entities`, …) are unknown now
   - The tool must also be in the profile you connected to (`/mcp`, `/mcp/readonly` or `/mcp/maintenance`)

3. **Invalid Parameters**
   - Ensure all required parameters are provided
   - Check parameter types match what the tool expects
   - Refer to the [MCP Tools Documentation](mcp_tools.md) for parameter requirements

4. **Entity Not Found**
   - The tool returns an `isError` result whose JSON envelope has `category: "not_found"`
   - Verify entity IDs exist in the database
   - Use `search` to find valid entity IDs

5. **Operation Failed**
   - The envelope has `category: "system_error"` (or `validation` for a refusal you can correct);
     read `message`, `code` and `next_move` ([mcp_tools.md](mcp_tools.md), Error Handling)
   - Verify the database is accessible and not corrupted

### Problem: HTTP 413, 503, 409 or 400 from `/mcp`

These come from the transport's request checks, before any tool runs
(limits in [mcp_access_control.md](mcp_access_control.md#request-limits-and-protocol-checks)):

- **413** — the body is over `GRAPH_MEM_MCP_MAX_REQUEST_BYTES` (4 MiB). Split the batch, or raise
  the limit.
- **503 "Too many sessions"** — `GRAPH_MEM_MCP_MAX_SESSIONS` (256, per profile path) sessions are
  open. A new `initialize` first reaps expired sessions; live ones are never evicted. Wait for idle
  sessions to expire (30 minutes), raise the limit, or find the client holding that many sessions.
- **404 "Session not found" on a session that worked before** — the server restarted, the session
  expired, or it was opened on another profile path. Start a new session.
- **409** — a second `GET` stream on the same session. Close the first one, or start a new session.
- **400 "Unsupported protocol version"** — the `MCP-Protocol-Version` header names a version the
  server doesn't support. Send the version `initialize` returned.
- **400 `-32600`** — the body is not a single JSON-RPC 2.0 object (an array, a missing `jsonrpc`,
  or `"id": null`).

### Problem: A stdio client reports a parse error or a non-JSON line

The runner writes JSON-RPC only to stdout and logs to stderr. If a client still sees log text on
stdout, check that it launches `bin/mcp_stdio_runner.rb` itself, not `bin/rails` or a wrapper
script that prints to stdout before starting it.

### Problem: Cascade MCP Client Not Discovering Tools

**Symptoms:**
- Tools not appearing in the Windsurf UI
- "Method not found" errors when calling tools

**Solutions:**

1. **Refresh Cascade's Tool List**
   - Cascade requires a manual UI refresh to discover server changes
   - Ask the user to click the refresh tools button in the Windsurf UI

2. **Check Server Configuration**
   - Verify the tool is in the profile you connected to (`/mcp`, `/mcp/readonly` or
     `/mcp/maintenance`); a tool outside it answers `Tool not found`
   - Ensure the `tool_name` method is correctly implemented in each tool

3. **Server Log Analysis**
   - Check the server logs for registration errors
   - Look for JSON-RPC parsing errors or exceptions

## Project Scan Issues

### Problem: A scan says "Partial"

A scan is partial when a part failed or a file wasn't sent (over 50 KB, past the 200 KB input cap or past `project_scan_max_chunks`). It still created and updated what it saw, but it marked nothing missing and queued no delete. The scan page's "Partial extraction" card and `scan_project_status`'s `details.extraction` list the failed parts and the left-out files.

- Parts failed with "answer cut" or "prompt cut" or "prompt rejected": the parts are too big for the model. Lower `project_scan_bytes_per_token` or raise `summary_num_ctx` (and check the model's real window). Very dense text (CJK docs, minified files) can stop a scan after about 3 calls.
- Parts failed with `provider_unavailable`: the model server is down or slow; two in a row stop the scan. Check `summary_url` and `summary_timeout` (each part waits at least 120 s).
- Files left out: narrow the scan with `file_globs`, or raise `project_scan_max_chunks`. Files over 50 KB are never sent.

### Problem: A scan falls back: "LLM response was not valid JSON"

Every part failed to give a JSON object with an `architecture` array, so the scan used the deterministic fallback. Check that `summary_model` follows JSON instructions (scans send `format: "json"`), raise `project_scan_chunk_output_tokens` if answers are cut, and raise `summary_num_ctx` to the model's real window. "summary_num_ctx (N) leaves no room for project files" means the window minus the answer budget and the prompt (about 1,000 tokens) leaves under 1,024 tokens for files. The message names the exact minimum for your settings: at the default `project_scan_chunk_output_tokens` (2048) that is about 4,150 (8192 is the default); on a smaller window, lower `project_scan_chunk_output_tokens` instead.

## Import and Embedding Issues

### Problem: An import matched facts exactly only

This is the headless JSON import (`graphify:import`, `rails_ast:import`), the only import that still embeds before its lock. An SQL import never embeds in the import itself: its follow-up compares afterwards ([The SQL import's near-duplicate check "couldn't run"](#problem-the-sql-imports-near-duplicate-check-couldnt-run)).

**Symptoms:**
- The log of an import that completed has one line (1.93.3):

  ```
  ImportExecutionStrategy: Semantic observation de-duplication matched 2 fact(s) exactly only: 2 whose text was not embedded before the import
  ```

- An imported fact that is worded differently from one the entity already had was added next to it instead of being skipped as a duplicate.

**Cause:** the import's semantic de-duplication compares an incoming fact's embedding with the entity's existing facts (`import_observation_duplicate_max_distance`, see [app_settings_reference.md](app_settings_reference.md#imports)). The lock an import holds is never held across an embedding call, so the import embeds the texts it will need before it takes the lock, and under the lock only looks those vectors up. The list of texts is read before the lock without holding it, so an entity or a fact that appeared or changed between that read and the lock (another writer, or the embedding backfill stamping the entity's facts) can need a vector the import didn't compute. Such a fact is matched on its exact text only, never embedded under the lock, and the line counts them.

**Solutions:**

1. The facts the line counts were added as new observations. If an entity now holds a fact twice in different words, retire one with Find & supersede or by hand. Running the same import again won't help: the facts now exist, so it matches them exactly and skips them.
2. This line never comes from the embedding service being down. Then the import fails before it takes the lock, writing nothing, with "Semantic observation de-duplication unavailable: Embedding service is unavailable: …" (the web import has no such refusal any more: Projects › Imports takes graph_mem-sql scripts only, which import without the embedding service and report what the near-duplicate check could not compare). Bring the service back (see [operator/embeddings.md](operator/embeddings.md): check the URL and model on the Embeddings page and that the service answers) and run the import again. A database without vector columns fails the import with "Semantic observation de-duplication unavailable" too.

### Problem: An SQL import was refused

**Symptoms:** a graph_mem-sql script ([data_exchange.md](data_exchange.md)) does not import. Where the message shows tells you which check said no, and in every case below **nothing was written**.

| Where | Message starts with | Who refused |
|---|---|---|
| Projects › Imports upload form, or `graph_mem:import_sql` | "This file was refused before anything ran: …" (the rake task prints "import refused, nothing was written: …" with the same reason) | the validator, before any SQL ran |
| Projects › Imports upload form, or the preview's Execute | "The import was refused and nothing was written: graph_mem-sql: …" (Execute: "The import did not run and nothing was written: …") | a guard of the script, inside the dry run or the real run |
| the same pages | "The graph is busy (an import or maintenance holds the membership lock). Nothing was written; try again in a minute." | the membership lock, held by another import, backfill, move or merge |
| `graph_mem:import_sql` | "import refused, nothing was written: …" followed by a MariaDB message, with no `graph_mem-sql:` prefix | the database, for a value the validator's grammar passes |

**Reading the validator's reasons** (the file itself is wrong):

- "the file is N bytes, over the 50 MB limit" or "the script is over the 50 MB limit": split the export (export fewer roots) or use `NESTED=0`.
- "not a graph_mem-sql script (no '-- graph_mem-sql v<N>' first line)": a different file, or one that an editor, mail client or download changed at the top.
- "graph_mem-sql v2 is not known to this graph_mem (it reads v1)": the source machine runs a newer graph_mem than this one. Upgrade the target machine, or export again from an older one.
- "the body does not match its sha256 (the file was changed or cut)": the file was edited, truncated or re-encoded in transit. Copy it again (binary mode) and compare sizes.
- "the script has CR characters (its line endings were changed to CRLF)" or "is not valid UTF-8": a transfer or editor changed it. Export again.
- "the fixed part of the script differs from graph_mem-sql v1 here (edited, or its sql_mode line changed)": the file was edited by hand, or it was exported by a graph_mem whose template for that version differs. Exports are not meant to be edited; export again.
- "line N of the data part: expected …, found …" (a comment, an unknown table, a column list, a non-literal value): the data part holds something the exporter never writes. Export again.
- "the header …" lines: a damaged header.

**Reading a guard's message** (the file is well formed, the data or this database says no; each names the field and the row where it can):

- "this database is at schema X, older than the schema of the script (Y); upgrade graph_mem here first": run the newer graph_mem's migrations on the target machine (a plain upgrade), then import.
- "graph_mem-sql v1 supports schemas up to X, this database is at schema Y; upgrade graph_mem on the source machine and export again": the target machine is newer than the format's `max_schema`. See [format and schema versions](data_exchange.md#format-and-schema-versions).
- `"<name>" is a Project on one side and not on the other; rename one of them first`: an entity of that name exists here as a non-Project (or the other way round). Rename one side.
- `memory_entities.name is blank (staged entity N)`, `memory_observations.tags is not an array of strings (staged observation N on "<entity>")`, `confidence 1.5 is not between 0 and 1` and the like: the source graph holds a value this app's models would refuse. Fix it on the source machine and export again.
- ".updated_at … is more than a day ahead of the clock here": the source machine's clock was ahead (or a row was written with a future date). Fix the row or the clock; the script would otherwise win every newer-wins comparison until that date.
- `"<name>" would have two part_of parents`, `"<name>" would be part_of itself (a part_of cycle)` or `the project of "<name>" would not match its part_of parent`: the target's `part_of` tree conflicts with the script's in a way the merge can't settle. Look at that entity's parent on both machines, fix one, and run again; see also [membership drift](#problem-membership-drift-an-entity-is-in-the-wrong-project).
- "the membership lock stayed busy for 60 s": only from a [hand run](data_exchange.md#hand-runs); the app says "The graph is busy" instead. Wait for the other write to end and run again.

**A MariaDB message.** A number the grammar passes but MariaDB rejects (for example `1e999`) fails its statement and rolls the run back. `graph_mem:import_sql` prints the database's message without a backtrace, and the Imports page shows it as "The import was refused and nothing was written" with the same message. Such a value doesn't come from a graph_mem export: the file was edited or written by another tool.

**Solutions:**

1. Fix the cause named in the message, then run the same import again. A refused run leaves no audit row and no operation row, and a dry run never does.
2. For the busy lock, wait for the other write (System › Background jobs shows what runs) and retry.
3. Take a backup before the import that finally runs (System › Backups); an SQL import has no one-click undo.

### Problem: The SQL import's near-duplicate check "couldn't run"

**Symptoms:** the import report's **After the import** card says "The near-duplicate check could not run for N new observations (<reason>): reworded duplicates among them were not proposed for review.", or, on an install without vector columns, "The near-duplicate check needs vector columns, which this install doesn't have: …".

**Cause:** the follow-up job proposes a `delete_observation` review row for a new fact that is within `import_observation_duplicate_max_distance` of an active fact the entity already had ([settings](app_settings_reference.md#imports)). It reads the stored embeddings and never embeds, so a new fact that has no embedding yet can't be compared. The reason in the message says why there is none:

- "the embedding service is down": the follow-up's backfill could not reach it, so the new rows stayed unembedded;
- "they are not embedded yet": the backfill gave up on its lock (another backfill held it through every retry) or didn't reach those rows;
- the vector-columns hint: this install keeps no vectors, so the check can't run at all (a standing limit).

The import itself is complete: the facts are in, only the review rows for reworded duplicates are missing. Entity-merge review rows are not affected.

**Solutions:**

1. Restore the embedding service (System › Health, [embeddings guide](operator/embeddings.md)) and run the backfill (Embeddings › **Backfill missing**, or `bin/rails embeddings:backfill`).
2. The check does not run again by itself. Reworded duplicates left among the new facts are found by compaction review, or by Find & supersede on the entity.

### Problem: The log says "deferred embedding of … failed"

**Symptoms:**
- The log has `EmbeddingService: deferred embedding of MemoryEntity#42 failed: <message>` (or `MemoryObservation#…`).
- A just-written entity or fact is missing from vector search.

**Cause:** inside the membership lock a write's embedding is deferred until the outermost lock block exits (1.93.3, see [architecture](architecture.md#project-membership-1931-1932-1933)). That call ran after the lock was released, and the embedding service failed. The write itself is committed and unaffected; the row has no embedding stamp, as with an inline embedding that failed.

**Solutions:**
1. Restore the embedding service, then run `bin/rails embeddings:backfill` or click **Backfill missing** on the Embeddings page. The daily backfill picks the row up too.
2. A row that was rolled back is simply skipped; no line is logged for it.

## Database Issues

### Problem: `db:schema:dump` warns "dump came from a DB without the embedding indexes/triggers"

**Symptoms:**
- `bin/rails db:schema:dump` prints a `StructureDumpGuard` warning and restores the previous `structure.sql` (or aborts when the degraded dump carries new migrations).

**Cause:** the source database has the `VECTOR` indexes but lacks the insert triggers (or vice versa) — typically because `AddEmbeddingInsertTriggers` ran while the embedding columns were still nullable, e.g. a different migrate order or a schema loaded before the triggers existed.

**Solutions:**

1. **Repair via the idempotent task:** `bin/rails embeddings:add_indexes` is safe to re-run — it skips pieces already in place, reinstalls missing/drifted insert triggers, and exits non-zero with `WARNINGS:` if drift remains that it cannot safely repair.
2. **When it reports drift on an indexed column** (unexpected default or `vector(n)` dimensions): the ALTER would have to rebuild the vector index, so repair explicitly — `bin/rails embeddings:drop_indexes` then `embeddings:add_indexes` (plus `embeddings:regenerate` first if the embedding model/dimensions actually changed).
3. **Re-dump:** `bin/rails db:schema:dump` — the warning should be gone and the dump is canonical again.

### Problem: Membership drift (an entity is in the wrong project)

**Symptoms:**
- An entity shows up in a project's search or scope although nothing in that project's `part_of` tree leads to it, or an entity under a project's tree is still global or in another project.
- A name is refused as taken in a project, and the entity holding it has no path to that project.
- An entity has two `part_of` parents.

**Cause:** an entity's project (`memory_entities.project_id`) is derived from its single `part_of` parent chain. A writer that changed a `part_of` edge, or deleted an entity with `part_of` children, without syncing the children left the stamp behind. Releases before 1.93.1 had such writers (entity delete, merge, the operator's relation repair, scans and imports). Releases before 1.93.2 still had the scan validation's wrong-root delete, the scanner's and the guided scan's own `part_of` edges, the dream-state orphan and merge phases, the integrity sweep's dangling-edge delete and the rake tasks `data:merge_entity`, `data:migrate_json`, `data:append_json` and `tools:create_relation`.

**Solutions:**

1. **See it first, with the dry run:** `bin/rails graph_mem:backfill_project_ids[dry_run]` writes nothing and prints the drift it found:

   ```
   project_id backfill (DRY RUN)
     Alpha Service (#4): 12 members
     unrooted (stays NULL): 3
     conflicts: 0
     drift before the run: wrong_project=0 stamped_without_path=2 path_without_stamp=1 reached_by_two_roots=0 several_parents=0
     stamps without a path: 1 top(s) attached to the stamped project's root, 1 stamp(s) cleared (would be)
     (no rows written)
   ```

   `wrong_project`, `stamped_without_path` and `path_without_stamp` are stamps the run repairs. `reached_by_two_roots` and `several_parents` are edges it only reports: fix them by hand (Explore, or **Repair relation duplicates** on System › Background jobs for an extra parent). From the console, `ProjectIdBackfill.drift` returns the same counts with the entity ids.
2. **Repair it:** `bin/rails graph_mem:backfill_project_ids` takes the membership lock and does it in one transaction. A stamp whose `part_of` chain is stamped consistently (every entity up the chain carries the same project, and the top has no parent) is repaired toward the stamp: the top gets one `part_of` to that project's root. Any other stamp with no path is cleared. The new edges are one change set, `maintenance.membership_repair`, in System › Activity; undoing it deletes them and the trees go global. A second run changes nothing.
3. **On upgrade to 1.93.1:** the migration `RepairMemoryEntityProjectIds` runs this repair once at `db:prepare`, and prints and logs `membership drift before: ...` and `membership drift after: ...` (the five counts above). It never fails the deploy over a refused repair. On a name collision, a membership lock that stays busy, or a `part_of` edge the repair would add being refused, it logs "project_id repair skipped, data unchanged" with the reason and the hint, and completes (the repair is one transaction, so nothing changed). A collision means a name is already taken where a stamp would land (for example, an entity that would become global has the name of a global one): merge or rename one of them (the hint names the entities), then run `bin/rails graph_mem:backfill_project_ids`. A busy lock: wait for the running job (an import, a scan or a merge) and run the task again. A refused edge (the reason names the rule, such as a second parent or a cycle) means the graph changed after the repair planned the edge: run the task again. Any other error fails the migration as usual. Run the dry run before upgrading to see what the migration will do. Its `down` does nothing: the repair recomputed `project_id` and added the edges above, and those are one `maintenance.membership_repair` change set that System › Activity can undo.
4. **Messages from the writers (1.93.2):**
   - A scan's errors read `Project scope conflict for <name>: cannot move … ; kept under <project>`: the model said the entity is `part_of` something in another project, but its name (or a member's) is already taken there. The scan kept it under the scanned project (the model's edge was deleted and replaced by a containment edge to the root). Rename or merge one of the two if the model was right, then rescan.
   - A scan's errors read `Project scope not synced for N part_of edge(s): … run bin/rails graph_mem:backfill_project_ids`: the membership lock stayed busy (an import, a backfill or a merge held it) or the write failed, so the scan left the stamps it wrote. Run the task once the other job is done.
   - A scan validation error reads `Failed to delete relation N: cannot move …`: the validator wanted to remove a `part_of` to another project's root, but the child's name is taken in the project it would go back to, so the edge stays. Rename one of the two entities, then rescan.
   - `data:merge_entity` prints `Error: … Nothing was merged.` when the two entities have different types, either is a Project root, or a name would collide where a child or the target moves. Rename or retype one of them first. Since 1.93.2 the merge is an undoable change set (System › Activity).
   - `data:migrate_json` or `data:append_json` aborts with `project_id backfill aborted and rolled back: …` and the conflict hint: the backfill's stamps rolled back, the rows the file added stay. Fix the name the hint names, then run `bin/rails graph_mem:backfill_project_ids`; don't append the file again.
   - A dream-state run that logs `waits for the membership lock` isn't failing: the lock stayed busy, and the job tries the same batch again a minute later.
   - After a dream-state auto-merge, the survivor may be missing from vector search for a while: it is re-embedded by the embedding backfill the compactor enqueues (a Solid Queue job). If it is slow to start, run `bin/rails embeddings:backfill` or click **Backfill missing** on the Embeddings page.

### Problem: Database Connection Errors

**Symptoms:**
- ActiveRecord::ConnectionNotEstablished errors
- "Could not connect to MySQL server" errors

**Solutions:**

1. **Check Database Configuration**
   - Verify settings in `config/database.yml`
   - Ensure MariaDB is running: `systemctl status mariadb`

2. **Database Credentials**
   - Verify username and password in `config/database.yml`
   - Check user permissions in MariaDB

3. **Database Existence**
   - Ensure databases exist: `bin/rails db:create`
   - Run migrations: `bin/rails db:migrate`

### Problem: Docker app restarts in a loop with "The `cable` database is not configured"

**Symptoms:** `docker compose logs app` shows
``The `cable` database is not configured for the `production` environment. (ActiveRecord::AdapterNotSpecified)``,
listing only `production` as available, and the entrypoint prints
`No config for queue/cache/cable in current environment — skipping.`

**Cause:** `config/database.yml` is git-ignored, so a fresh clone doesn't have it. The image is built
without it and Rails builds a single database from `DATABASE_URL`, with no cache, queue or cable
database.

**Fix:**

```bash
cp config/database.example.yml config/database.yml
docker compose down && bin/up --build
```

### Problem: Docker app fails with "Access denied for user 'root'@'172.30.42.1'"

The address is the compose bridge gateway (`GRAPH_MEM_DOCKER_SUBNET`, default `172.30.42.0/24`), not
your LAN: the `app` container uses the host network and reaches MariaDB through the published
`DB_PORT`. The rejection is about the password.

MariaDB applies `MARIADB_ROOT_PASSWORD` only when it initializes an empty `graph_mem_db` volume. If
`DB_PASSWORD` in `.env` changed since then (for example, `.env` copied from another machine), the app
sends the new password and the DB still expects the old one. Either restore the old `DB_PASSWORD`, or
log in with it and change root's password to the new one:

```bash
docker compose exec db mariadb -uroot -p'<old>' \
  -e "ALTER USER 'root'@'%' IDENTIFIED BY '<new>'; ALTER USER 'root'@'localhost' IDENTIFIED BY '<new>';"
```

### Problem: `docker compose up` fails with "Pool overlaps with other one on this address space"

Another Docker network, or a LAN/VPN interface, already uses `GRAPH_MEM_DOCKER_SUBNET`. Pick a free
`/24` inside `172.16.0.0/12` (so the MCP allowlist defaults still cover it), set it in `.env`, then
`docker compose down && bin/up`. `ip -4 -br addr` and `docker network ls` show what is taken.

To keep *every* Docker network out of home-LAN ranges, also set the daemon pool in
`/etc/docker/daemon.json` and restart Docker:

```json
{ "default-address-pools": [ { "base": "172.30.0.0/16", "size": 24 } ] }
```

### Problem: Slow Database Queries

**Symptoms:**
- High response times for entity or relation operations
- Server timeouts on complex graph operations

**Solutions:**

1. **Check Indices**
   - Ensure indices exist on frequently queried columns
   - Add indices if needed:
     ```ruby
     add_index :memory_entities, :name
     add_index :memory_relations, :relation_type
     ```

2. **Optimize Query Patterns**
   - Use pagination for large result sets
   - Limit graph traversal depth
   - Use eager loading to avoid N+1 queries

3. **Database Maintenance**
   - Run `ANALYZE TABLE` on key tables
   - Check for and remove unused indices

## Runtime Errors

### Problem: Memory Consumption Issues

**Symptoms:**
- Server running out of memory
- Ruby process being killed

**Solutions:**

1. **Limit Response Sizes**
   - Enforce pagination on all list operations
   - Limit graph traversal depth
   - Use streaming responses for large datasets

2. **Monitor Memory Usage**
   - Use tools like `top` or Ruby's `get_process_mem` gem
   - Add memory monitoring to your application

3. **Optimize JSON Generation**
   - Use partial serialization for large objects
   - Avoid including unnecessary data in responses

## Tool-Specific Issues

### Problem: Entity Creation Fails

**Symptoms:**
- Error from `graph_write` with a `create_entity` operation
- Entity not saved in database

**Solutions:**

1. **Validation Errors**
   - Check for validation errors in the response
   - Ensure `name` and `entity_type` are provided
   - Names must be unique

2. **Database Constraints**
   - Check for unique constraint violations
   - Verify foreign key constraints are satisfied

### Problem: Relation Creation Fails

**Symptoms:**
- Error from `graph_write` with a `create_relation` operation
- Relation not saved in database

**Solutions:**

1. **Entity Existence**
   - Verify both source and target entities exist
   - Check entity IDs with `get_entities`

2. **Duplicate Relations**
   - Check if the relation already exists
   - Use `traverse_graph` to verify existing relations

## API versus MCP Issues

### Problem: Inconsistent Behavior Between API and MCP

**Symptoms:**
- Different results when using API vs. MCP for similar operations
- Features available in one interface but not the other

**Solutions:**

1. **Feature Parity**
   - Check if the feature is implemented in both interfaces
   - Some advanced features may only be available in one interface

2. **Serialization Differences**
   - Compare JSON structure between API and MCP responses
   - MCP may have additional formatting for client compatibility

## Development Environment Issues

### Problem: Environment Setup Failures

**Symptoms:**
- Errors during bundle install
- Missing dependencies

**Solutions:**

1. **Ruby Version**
   - Ensure you're using Ruby 3.4.13+
   - Install with `rvm install 3.4.13` or `rbenv install 3.4.13`
   - After upgrading from an earlier Ruby (1.93.2 moved to 3.4.13), create the gemset for the new Ruby and install the gems in it: `rvm use ruby-3.4.13@graph_mem --create && bundle install`. A gemset belongs to one Ruby, so the old one isn't reused. See [Step 2 of the Development Guide](development.md#step-2-install-dependencies).
   - `Bundler::GemNotFound` naming most of the lockfile means the shell is on the wrong Ruby or gemset, not that the bundle is broken: select the gemset (`rvm use ruby-3.4.13@graph_mem`), check `ruby -v`, and run the command again. In a script or agent shell, do it in the same command as the one you run, since RVM's per-directory switch only exists in an interactive shell.

2. **Bundle Install Errors**
   - Check for native extension errors
   - Install required system libraries:
     ```bash
     sudo apt-get install libmariadb-dev  # For Ubuntu/Debian
     sudo yum install mariadb-devel       # For CentOS/RHEL
     ```

3. **Database Setup**
   - Follow the steps in the [Development Guide](development.md)
   - Verify MariaDB is installed and running

## Performance Optimization

### Problem: Slow Performance with Large Graphs

**Symptoms:**
- Long response times for graph traversal
- Timeouts on complex queries

**Solutions:**

1. **Limit Query Scope**
   - Use filtering to reduce result sets
   - Implement pagination for all list operations
   - Limit graph traversal depth to 2-3 levels

2. **Database Optimization**
   - Add indices on commonly used fields
   - Consider denormalizing critical paths
   - Use connection pooling

3. **Caching**
   - Implement caching for frequently accessed entities
   - Use Rails cache for expensive operations:
     ```ruby
     Rails.cache.fetch("entity/#{id}", expires_in: 10.minutes) do
       MemoryEntity.find(id).as_json
     end
     ```

## Logging and Debugging

### Enable Detailed Logging

For troubleshooting complex issues:

1. **Set Log Level**
   - In `config/environments/development.rb`:
     ```ruby
     config.log_level = :debug
     ```

2. **Log Specific Components**
   - Add targeted logging in problematic areas:
     ```ruby
     Rails.logger.debug "Processing entity: #{entity.inspect}"
     ```

3. **MCP Request Logging**
   - Over HTTP the requests are in the Rails log like any other request; tool errors and
     gem-side failures are reported through `Rails.error`.
   - Over stdio every log goes to stderr (stdout carries JSON-RPC only): read it from the
     client's MCP log view, or redirect stderr when running `bin/mcp_stdio_runner.rb` by hand.

### Use Interactive Debugging

1. **Rails Console**
   - Test operations interactively:
     ```ruby
     entity = MemoryEntity.create(name: "Test", entity_type: "Debug")
     tool = GraphWriteTool.new
     tool.call_with_schema_validation!(observations: [ { entity_id: entity.id, text_content: "Test observation" } ])
     ```

2. **Database Inspection**
   - Connect directly to the database:
     ```bash
     mysql -u username -p graph_mem_development
     ```
   - Inspect tables:
     ```sql
     SELECT * FROM memory_entities LIMIT 10;
     ```

## Getting Additional Help

If you can't resolve an issue using this guide:

1. **Check Logs**
   - Review `log/development.log` for detailed error information
   - Look for exception backtraces and error messages

2. **Database Schema**
   - Check `db/schema.rb` for the current database structure
   - Verify your models match the schema

3. **Create an Issue**
   - Submit a detailed bug report including:
     - Steps to reproduce
     - Expected vs. actual behavior
     - Error messages and stack traces
     - Environment details (Ruby version, Rails version, OS)

4. **Contact Support**
   - For dedicated support, email: support@example.com
   - Include all relevant information from step 3