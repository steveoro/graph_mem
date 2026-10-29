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
     `GRAPH_MEM_MCP_ALLOWED_HOSTS` (any port, or `host:port`) or in Settings › Access.
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
     LAN address; or add the name or address in Settings › Access (applies at once, no
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

## Database Issues

### Problem: `db:schema:dump` warns "dump came from a DB without the embedding indexes/triggers"

**Symptoms:**
- `bin/rails db:schema:dump` prints a `StructureDumpGuard` warning and restores the previous `structure.sql` (or aborts when the degraded dump carries new migrations).

**Cause:** the source database has the `VECTOR` indexes but lacks the insert triggers (or vice versa) — typically because `AddEmbeddingInsertTriggers` ran while the embedding columns were still nullable, e.g. a different migrate order or a schema loaded before the triggers existed.

**Solutions:**

1. **Repair via the idempotent task:** `bin/rails embeddings:add_indexes` is safe to re-run — it skips pieces already in place, reinstalls missing/drifted insert triggers, and exits non-zero with `WARNINGS:` if drift remains that it cannot safely repair.
2. **When it reports drift on an indexed column** (unexpected default or `vector(n)` dimensions): the ALTER would have to rebuild the vector index, so repair explicitly — `bin/rails embeddings:drop_indexes` then `embeddings:add_indexes` (plus `embeddings:regenerate` first if the embedding model/dimensions actually changed).
3. **Re-dump:** `bin/rails db:schema:dump` — the warning should be gone and the dump is canonical again.

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
   - Ensure you're using Ruby 3.4.12+
   - Install with `rvm install 3.4.12` or `rbenv install 3.4.12`

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