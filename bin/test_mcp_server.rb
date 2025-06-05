#!/usr/bin/env ruby

require 'json'
require 'open3'

def send_mcp_request(method, params = {})
  request = {
    jsonrpc: "2.0",
    id: rand(1000),
    method: method,
    params: params
  }

  puts "Sending: #{request.to_json}"
  request.to_json + "\n"
end

def test_mcp_server
  puts "Testing MCP Server..."

  # Start the server
  stdin, stdout, stderr, wait_thr = Open3.popen3("bundle exec ruby bin/mcp_stdio_runner.rb")

  begin
    # Wait a moment for server to start
    sleep 2

    # Test 1: Initialize
    puts "\n=== Test 1: Initialize ==="
    init_request = send_mcp_request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {
        tools: {}
      },
      clientInfo: {
        name: "test-client",
        version: "1.0.0"
      }
    })

    stdin.write(init_request)
    stdin.flush

    # Read response
    response = stdout.gets
    puts "Response: #{response}"

    # Test 2: Call get_current_time tool with correct name
    puts "\n=== Test 2: Call mcp_get_current_time_tool ==="
    call_tool_request = send_mcp_request("tools/call", {
      name: "mcp_get_current_time_tool",
      arguments: {}
    })

    stdin.write(call_tool_request)
    stdin.flush

    response = stdout.gets
    puts "Response: #{response}"

    # Test 3: Call version tool
    puts "\n=== Test 3: Call mcp_version_tool ==="
    version_request = send_mcp_request("tools/call", {
      name: "mcp_version_tool",
      arguments: {}
    })

    stdin.write(version_request)
    stdin.flush

    response = stdout.gets
    puts "Response: #{response}"

    puts "\n=== Tests completed ==="

  rescue => e
    puts "Error during testing: #{e.message}"
    puts e.backtrace
  ensure
    # Clean up
    stdin.close
    Process.kill("TERM", wait_thr.pid) rescue nil
    wait_thr.join
  end
end

if __FILE__ == $0
  test_mcp_server
end
