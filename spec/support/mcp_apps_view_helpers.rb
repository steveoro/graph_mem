# frozen_string_literal: true

# MCP Apps view system specs (Graph mode 1.88.0, Search mode 1.89.0), tagged `:mcp_apps_view`.
# No route serves the view: open_view writes a stub-host page to a temp file and loads the built
# document into a sandboxed iframe under the host's default CSP. The stub host plays the
# postMessage protocol: it answers ui/initialize with the spec's `host_context` (a `let`), takes
# pushed tool results, and queues the view's own tools/call requests, which the spec answers with
# the real tools on synthetic data (serve_view_calls_until).
module McpAppsViewHelpers
  # The host default when a resource declares no csp (MCP Apps 2026-01-26, plus the draft's object-src).
  HOST_CSP = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " \
             "img-src 'self' data:; media-src 'self' data:; connect-src 'none'; object-src 'none'"

  # @return [Hash] the tools/call result of the readonly profile's tool, JSON round-tripped
  def tool_result(name, arguments) = tool_result_on(:readonly, name, arguments)

  # @param profile [Symbol] :default, :readonly or :maintenance
  # @return [Hash]
  def tool_result_on(profile, name, arguments)
    reply = GraphMem::OfficialMcp::ServerFactory.for(profile, apps_enabled: true).handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
    JSON.parse(JSON.generate(reply)).fetch("result")
  end

  # Loads the stub host with the view and waits for the view's ui/notifications/initialized.
  def open_view
    html = GraphMem::McpApps::Views.provider_for(:readonly).read(GraphMem::McpApps::Views::GRAPH_URI).sole[:text]
    html = html.sub("<head>", %(<head>\n<meta http-equiv="Content-Security-Policy" content="#{HOST_CSP}">))
    dir = Dir.mktmpdir("mcp-apps-view")
    mcp_apps_temp_dirs << dir
    File.write(File.join(dir, "host.html"), host_page(html))
    visit "file://#{dir}/host.html"
    wait_until { page.evaluate_script("window.viewInitialized === true") }
  end

  def mcp_apps_temp_dirs = (@mcp_apps_temp_dirs ||= [])

  def wait_until(timeout: 10)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  end

  def host_page(view_html)
    <<~HTML
      <!doctype html><html><head><meta charset="utf-8"></head><body>
      <iframe id="view" sandbox="allow-scripts" style="width:1000px;height:700px"></iframe>
      <iframe id="other" sandbox="allow-scripts" style="display:none"></iframe>
      <script>
        const frame = document.getElementById("view");
        const log = [];
        const queue = [];
        const send = (message) => frame.contentWindow.postMessage({ jsonrpc: "2.0", ...message }, "*");
        window.addEventListener("message", (event) => {
          if (event.source !== frame.contentWindow) return;
          const m = event.data;
          log.push(m);
          if (m.method === "ui/initialize") send({ id: m.id, result: { protocolVersion: "2026-01-26", hostInfo: { name: "stub-host", version: "0" }, hostCapabilities: {}, hostContext: #{host_context.to_json} } });
          if (m.method === "ui/notifications/initialized") window.viewInitialized = true;
          if (m.method === "tools/call") queue.push({ id: m.id, name: m.params.name, arguments: m.params.arguments });
          if (m.method === "ui/request-display-mode") send({ id: m.id, result: { mode: m.params.mode } });
          if (m.method === "ui/update-model-context") send({ id: m.id, result: {} });
        });
        window.hostTakeCalls = () => queue.splice(0);
        window.hostQueued = () => queue.length;
        window.hostReply = (id, result) => send({ id, result });
        window.hostSend = (message) => send(message);
        window.hostLog = () => JSON.stringify(log);
        // A sibling frame relays messages to the view: their event.source is not the view's parent.
        document.getElementById("other").srcdoc = '<script>addEventListener("message", (e) => parent.frames[0].postMessage(e.data, "*"));<\\/script>';
        window.otherSend = (message) => document.getElementById("other").contentWindow.postMessage({ jsonrpc: "2.0", ...message }, "*");
        frame.srcdoc = #{view_html.to_json};
      </script></body></html>
    HTML
  end

  # Answers the view's tools/call requests with the real tools until the view shows `text`.
  def serve_view_calls_until(text, timeout: 20)
    deadline = Time.current + timeout
    loop do
      page.evaluate_script("window.hostTakeCalls()").each do |call|
        calls_served << call.slice("name", "arguments")
        page.execute_script("window.hostReply(arguments[0], arguments[1])", call["id"], tool_result(call["name"], call["arguments"]))
      end
      return if within_frame("view") { page.has_text?(text, wait: 0) }
      raise "the view never showed #{text.inspect}; it shows: #{within_frame('view') { page.text }}" if Time.current > deadline

      sleep 0.05
    end
  end

  def calls_served = (@calls_served ||= [])

  def push_tool_result(result)
    page.execute_script("window.hostSend(arguments[0])", { method: "ui/notifications/tool-result", params: result })
  end

  def host_log = JSON.parse(page.evaluate_script("window.hostLog()"))

  def console_errors = page.driver.browser.logs.get(:browser).map(&:message).grep_v(/favicon/)
end

RSpec.configure do |config|
  config.include McpAppsViewHelpers, :mcp_apps_view
  config.after(:each, :mcp_apps_view) { mcp_apps_temp_dirs.each { |dir| FileUtils.remove_entry(dir) } }
end
