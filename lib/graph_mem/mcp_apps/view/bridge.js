// MCP Apps bridge (graph_mem 1.88.0): JSON-RPC 2.0 with the host over postMessage, no SDK.
// Rules (as in 1.87.0's stub):
// - only messages from window.parent, and only JSON-RPC 2.0 objects;
// - a reply is taken only for a pending request id; a request or notification only for a method
//   registered with bridge.on; an unknown request gets -32601, anything else is dropped;
// - page text goes through textContent only (in the view code).
// Every tool call goes through bridge.callTool, the only "tools/call" request in the view.

const PROTOCOL_VERSION = "2026-01-26";
const REQUEST_TIMEOUT_MS = 60000;

const bridge = (() => {
  const pending = new Map();
  const handlers = Object.create(null);
  let nextId = 1;
  let toolCallsInFlight = 0;

  function post(message) {
    // The view doesn't know the host's origin; the host routes the message to this frame.
    window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*");
  }

  function request(method, params) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, REQUEST_TIMEOUT_MS);
      pending.set(id, { resolve, reject, timer });
      post({ id, method, params });
    });
  }

  const notify = (method, params) => post({ method, params });

  // Registers the handler of a host request or notification; a request's answer is the
  // handler's return value (or {}).
  function on(method, handler) {
    handlers[method] = handler;
  }

  function settle(message) {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    if (message.error) waiter.reject(message.error);
    else waiter.resolve(message.result);
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window.parent) return;
    const message = event.data;
    if (!message || typeof message !== "object" || message.jsonrpc !== "2.0") return;

    if ("id" in message && !("method" in message)) {
      settle(message);
      return;
    }

    if (typeof message.method !== "string") return;
    if (!Object.hasOwn(handlers, message.method)) {
      // A request (it has an id) gets an answer, as JSON-RPC 2.0 requires; a notification is dropped.
      if ("id" in message) post({ id: message.id, error: { code: -32601, message: "Method not found" } });
      return;
    }
    let answer;
    try {
      answer = handlers[message.method](message.params || {});
    } catch (error) {
      console.warn("graph_mem view: handler failed", message.method, error);
    }
    if ("id" in message) post({ id: message.id, result: answer ?? {} });
  });

  // The tool's structured result; graph_mem mirrors it as JSON text when a host drops it.
  function structured(result) {
    if (result && result.structuredContent && typeof result.structuredContent === "object") return result.structuredContent;
    const text = result && Array.isArray(result.content) && result.content[0] && result.content[0].text;
    try {
      return typeof text === "string" ? JSON.parse(text) : null;
    } catch (_error) {
      return null;
    }
  }

  // Calls a graph_mem tool through the host and resolves to its structured result.
  // Rejects with an Error whose message is the tool's ToolError message when the call failed.
  async function callTool(name, args) {
    toolCallsInFlight += 1;
    try {
      const result = await request("tools/call", { name, arguments: args });
      const data = structured(result);
      if (!result || result.isError) {
        throw new Error((data && typeof data.message === "string" && data.message) || `${name} failed`);
      }
      return data || {};
    } finally {
      toolCallsInFlight -= 1;
    }
  }

  return {
    request,
    notify,
    on,
    callTool,
    structured,
    busy: () => toolCallsInFlight > 0
  };
})();
