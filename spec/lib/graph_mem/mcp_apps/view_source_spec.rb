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

  it "has view sources to check" do
    expect(sources.map { |path| path.basename.to_s }).to include("graph.html")
  end

  sources.each do |path|
    relative = path.relative_path_from(Rails.root).to_s

    forbidden.each do |label, pattern|
      it "has no #{label} in #{relative}" do
        expect(path.read.lines.each_with_index.filter_map { |line, i| "#{i + 1}: #{line.strip}" if line.match?(pattern) }).to be_empty
      end
    end
  end

  describe "graph.html" do
    let(:html) { Rails.root.join("lib/graph_mem/mcp_apps/view/graph.html").read }

    it "is a valid HTML5 document" do
      expect(html).to start_with("<!doctype html>")
      expect(Nokogiri::HTML5.parse(html, max_errors: 10).errors).to be_empty
    end

    it "accepts messages only from the host frame and only JSON-RPC 2.0" do
      expect(html).to include("event.source !== window.parent", 'message.jsonrpc !== "2.0"')
    end

    it "runs the ui/initialize handshake with the stable protocol and answers ui/resource-teardown" do
      expect(html).to include('"2026-01-26"', '"ui/initialize"', '"ui/notifications/initialized"',
                              'availableDisplayModes: ["inline", "fullscreen"]', '"ui/resource-teardown"')
    end

    it "answers a host request it doesn't handle with -32601 (JSON-RPC 2.0)" do
      expect(html).to include("code: -32601")
    end

    it "calls only read tools graph_mem's views may call" do
      called = html.scan(%r{"tools/call",\s*\{\s*name:\s*"([a-z_]+)"}).flatten.uniq
      expect(called).not_to be_empty
      expect(called).to all(be_in(GraphMem::McpApps::Views::VIEWS.first[:calls]))
    end
  end
end
