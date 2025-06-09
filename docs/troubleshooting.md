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
     - HTTP/JSON-RPC: `http://localhost:3000/mcp/messages`
     - SSE: `http://localhost:3003/mcp/sse`

3. **CORS Issues (Browser Clients Only)**
   - Check browser console for CORS errors
   - Configure CORS in `config/initializers/fast_mcp.rb` to include your client domain
   - Add the following headers to your requests:
     ```
     Access-Control-Allow-Origin: *
     Content-Type: application/json
     ```

4. **Firewall Blocking Connections**
   - Check if your firewall is blocking the port
   - Allow connections to the relevant ports (3000 or 3003)

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
       "method": "VersionTool",
       "params": {},
       "id": 1
     }
     ```

2. **Unknown Method**
   - Check the method name matches an existing tool
   - Tool names are case-sensitive
   - Use the full tool name (e.g., `CreateEntityTool` not `CreateEntity`)

3. **Invalid Parameters**
   - Ensure all required parameters are provided
   - Check parameter types match what the tool expects
   - Refer to the [MCP Tools Documentation](mcp_tools.md) for parameter requirements

4. **Entity Not Found**
   - Error code `-32002` indicates a requested resource wasn't found
   - Verify entity IDs exist in the database
   - Use `SearchEntitiesTool` to find valid entity IDs

5. **Operation Failed**
   - Error code `-32003` indicates an operation failed
   - Check the error message for specific details
   - Verify the database is accessible and not corrupted

### Problem: Cascade MCP Client Not Discovering Tools

**Symptoms:**
- Tools not appearing in the Windsurf UI
- "Method not found" errors when calling tools

**Solutions:**

1. **Refresh Cascade's Tool List**
   - Cascade requires a manual UI refresh to discover server changes
   - Ask the user to click the refresh tools button in the Windsurf UI

2. **Check Server Configuration**
   - Verify tools are properly registered in `config/initializers/fast_mcp.rb`
   - Ensure the `tool_name` method is correctly implemented in each tool

3. **Server Log Analysis**
   - Check the server logs for registration errors
   - Look for JSON-RPC parsing errors or exceptions

## Database Issues

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

### Problem: Monkey-Patch Related Issues

**Symptoms:**
- Errors in `FastMcp::Server#handle_tools_call`
- Incorrect response formatting

**Solutions:**

1. **Check Patch Application**
   - Ensure `config/initializers/zzz_fast_mcp_patches.rb` is loaded after all other initializers
   - Verify the patch matches the installed gem version

2. **Response Format**
   - Ensure the response format matches what Cascade expects:
     ```ruby
     {
       jsonrpc: "2.0",
       id: id,
       result: {
         content: [
           {
             type: "json",
             json: actual_tool_data.to_json
           }
         ]
       }
     }
     ```

3. **Debug Logging**
   - Add logging around the monkey-patch
   - Compare raw response with expected format

## Tool-Specific Issues

### Problem: Entity Creation Fails

**Symptoms:**
- Error when calling `CreateEntityTool`
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
- Error when calling `CreateRelationTool`
- Relation not saved in database

**Solutions:**

1. **Entity Existence**
   - Verify both source and target entities exist
   - Check entity IDs with `GetEntityTool`

2. **Duplicate Relations**
   - Check if the relation already exists
   - Use `FindRelationsTool` to verify existing relations

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
   - Ensure you're using Ruby 3.4.1+
   - Install with `rvm install 3.4.1` or `rbenv install 3.4.1`

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
   - Log incoming and outgoing MCP messages:
     ```ruby
     # In config/initializers/fast_mcp.rb
     FastMcp.logger.level = Logger::DEBUG
     ```

### Use Interactive Debugging

1. **Rails Console**
   - Test operations interactively:
     ```ruby
     entity = MemoryEntity.create(name: "Test", entity_type: "Debug")
     tool = CreateObservationTool.new
     tool.call(entity_id: entity.id, text_content: "Test observation")
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