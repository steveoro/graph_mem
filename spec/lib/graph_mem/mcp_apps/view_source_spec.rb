# frozen_string_literal: true

require "rails_helper"

# MCP Apps views (1.87.0): the sources under lib/graph_mem/mcp_apps/view/ run in a host's sandboxed
# iframe under a restrictive CSP and talk to the host only over postMessage. This guard catches
# what spec/javascript_sinks_spec.rb doesn't scan: HTML sinks, dynamic code, network calls and
# external URLs, and checks the bridge only accepts messages from the host frame.
RSpec.describe "MCP Apps view sources" do
  sources = Rails.root.glob("lib/graph_mem/mcp_apps/view/**/*").select(&:file?)

  forbidden = {
    "innerHTML" => /innerHTML/, "outerHTML" => /outerHTML/, "insertAdjacentHTML" => /insertAdjacentHTML/,
    "document.write" => /document\.write/, "eval(" => /\beval\s*\(/, "new Function" => /new\s+Function\b/,
    "fetch(" => /\bfetch\s*\(/, "XMLHttpRequest" => /XMLHttpRequest/, "WebSocket" => /WebSocket/,
    "an http(s) URL" => %r{https?:}i
  }

  it "has view sources to check, the shell and every script of each view" do
    names = GraphMem::McpApps::Views::VIEWS.flat_map { |view| [ view[:source], *view[:scripts] ] }
    expect(sources.map { |path| path.basename.to_s }).to match_array(names)
  end

  sources.each do |path|
    relative = path.relative_path_from(Rails.root).to_s

    forbidden.each do |label, pattern|
      it "has no #{label} in #{relative}" do
        expect(path.read.lines.each_with_index.filter_map { |line, i| "#{i + 1}: #{line.strip}" if line.match?(pattern) }).to be_empty
      end
    end
  end

  describe "the graph view" do
    view = GraphMem::McpApps::Views::VIEWS.first
    let(:source) { [ view[:source], *view[:scripts] ].map { |name| Rails.root.join("lib/graph_mem/mcp_apps/view", name).read }.join("\n") }
    let(:document) { GraphMem::McpApps::ViewBuilder.build(shell: view[:source], scripts: view[:scripts]) }

    it "is a valid HTML5 document, as a shell and as built" do
      [ Rails.root.join("lib/graph_mem/mcp_apps/view", view[:source]).read, document ].each do |html|
        expect(html).to start_with("<!doctype html>")
        expect(Nokogiri::HTML5.parse(html, max_errors: 10).errors).to be_empty
      end
    end

    it "accepts messages only from the host frame and only JSON-RPC 2.0" do
      expect(source).to include("event.source !== window.parent", 'message.jsonrpc !== "2.0"')
    end

    it "runs the ui/initialize handshake with the stable protocol and answers ui/resource-teardown" do
      expect(source).to include('"2026-01-26"', '"ui/initialize"', '"ui/notifications/initialized"',
                                'availableDisplayModes: ["inline", "fullscreen"]', '"ui/resource-teardown"')
    end

    it "answers a host request it doesn't handle with -32601 (JSON-RPC 2.0)" do
      expect(source).to include("code: -32601")
    end

    # Every tool call goes through callTool (one "tools/call" request in the bridge), so the tool
    # names are the first argument of callTool or the name of a literal tools/call.
    it "calls only read tools graph_mem's views may call" do
      called = (source.scan(/\bcallTool\(\s*"([a-z_]+)"/) + source.scan(%r{"tools/call",\s*\{\s*name:\s*"([a-z_]+)"})).flatten.uniq
      expect(called).not_to be_empty
      expect(called).to all(be_in(view[:calls]))
    end

    it "names no write tool and no set_context" do
      %w[graph_write graph_edit graph_delete set_context].each { |tool| expect(source).not_to include(tool) }
    end
  end
end
