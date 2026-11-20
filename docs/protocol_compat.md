# MCP protocol compatibility

## Summary

Since 1.55.0 graph_mem is served by the official MCP Ruby SDK (`mcp` gem, pinned to 1.10.0) over
Streamable HTTP and stdio. It speaks MCP 2024-11-05 through 2025-11-25 through the `initialize`
handshake, and 2026-07-28 natively: `server/discover` and the stateless per-request lifecycle. A
supported `initialize` version is echoed; anything else (2026-07-28, a future date, garbage) gets
2025-11-25. A 2026-07-28 client in `auto` mode gets an answer to its `server/discover` probe and
stays on 2026-07-28; `MCP_PROTOCOL_NEGOTIATION=legacy` on the client skips the probe and runs
`initialize` (2025-11-25). The legacy HTTP+SSE endpoint (`/mcp/sse`) was removed in 1.55.0.

Edge cases (unsupported `MCP-Protocol-Version` values, `"id": null`, a missing `jsonrpc` member,
unknown or missing sessions, a second GET stream, malformed stdio lines) are answered as the SDK
answers them. 16 cases changed in 1.55.0; the tables below show the current answers.

Failed tool calls (`isError: true`) carry one JSON object as their text: `error`, `category`,
`retriable`, `next_move`, `message`, `tool`, and since 1.54.2 an optional `code` for the exact
reason (e.g. `outside_filter`, `project_has_members`). stdio returns the same object as HTTP.
Details: [`docs/mcp_tools.md`](mcp_tools.md) (Error Handling).

Since 1.87.0 graph_mem also declares the MCP Apps extension; see [MCP Apps](#mcp-apps) below. Since 1.91.0 it
can serve its skills through the Skills extension, off by default; see [Skills over MCP](#skills-over-mcp).

Moving another Rails app from fast-mcp to the `mcp` gem:
[`docs/guides/migrating-fast-mcp-to-mcp-gem.md`](guides/migrating-fast-mcp-to-mcp-gem.md).

## Client matrix

`script/mcp_compat/clients.sh` at 1.87.0 (2026-11-17, `mcp` 1.10.0, Node 24.11.1, Ruby 3.4.12): 12 of
12 OK, and `/mcp` lists 12 tools on every row. Every `auto` row negotiates 2026-07-28, every `legacy`
row 2025-11-25. The Ruby SDK 1.9.0 and 1.10.0 clients keep the tool `title` and see one on all 12
tools. Re-run at 1.91.0 (2026-11-18) with Skills over MCP off: the same 12 of 12.

| Client | Mode | Transport | OK | Protocol | Timing note |
| --- | --- | --- | --- | --- | --- |
| TS client 2.4.0 | auto | stdio | OK | 2026-07-28 | about 1.1 s longer than `legacy` (the `server/discover` probe runs in a sibling process) |
| TS client 2.4.0 | auto | HTTP | OK | 2026-07-28 | |
| TS client 2.4.0 | legacy | stdio | OK | 2025-11-25 | |
| TS client 2.4.0 | legacy | HTTP | OK | 2025-11-25 | |
| Ruby SDK 1.9.0 | auto | stdio | OK | 2026-07-28 | `auto` costs nothing extra; titles on 12 of 12 tools |
| Ruby SDK 1.9.0 | auto | HTTP | OK | 2026-07-28 | titles on 12 of 12 tools |
| Ruby SDK 1.9.0 | legacy | stdio | OK | 2025-11-25 | titles on 12 of 12 tools |
| Ruby SDK 1.9.0 | legacy | HTTP | OK | 2025-11-25 | titles on 12 of 12 tools |
| Ruby SDK 1.10.0 | auto | stdio | OK | 2026-07-28 | `auto` costs nothing extra; titles on 12 of 12 tools |
| Ruby SDK 1.10.0 | auto | HTTP | OK | 2026-07-28 | titles on 12 of 12 tools |
| Ruby SDK 1.10.0 | legacy | stdio | OK | 2025-11-25 | titles on 12 of 12 tools |
| Ruby SDK 1.10.0 | legacy | HTTP | OK | 2025-11-25 | titles on 12 of 12 tools |

## Claude Code

`script/mcp_compat/claude_client_check.rb` (the automated
[`docs/plans/done/claude-mcp-client-check.md`](plans/done/claude-mcp-client-check.md)), 2026-10-25: Claude
Code 2.1.310 against graph_mem 1.55.0, over HTTP (default, readonly and maintenance profiles, and a
wrong bearer token) and stdio. All checks pass in both modes. Claude Code negotiates 2026-07-28 over
HTTP and stdio by default, and 2025-11-25 with `MCP_PROTOCOL_NEGOTIATION=legacy`.

The first, manual run (graph_mem 1.54.1, the same Claude Code version) had no protocol or connection
failure either. It found four server-side gaps, all fixed in 1.54.2: scan refusals without a
machine-readable `code`, `scan_project_status` answering "not found" until a worker started the scan,
plain `Error:` text instead of the JSON envelope on stdio, and no way to delete an empty Project over
MCP.

## Handshake comparison

`script/mcp_compat/compare.rb`, 2026-11-17: graph_mem 1.87.0 (`mcp` 1.10.0), reference servers Memory
2.1.1 and Everything 2.3.0 with SDK 2.4.0 (the MCP servers release v2.4.0), on Node 24.11.1 and Ruby
3.4.12. 0 failed expectations, 0 unexpected differences; every case recorded at 1.86.1 answers the same
on both sides, and 1.87.0 adds "initialize declares the MCP Apps extension" (graph_mem only: the
reference servers declare no extensions). Re-run at 1.91.0 (2026-11-18) with Skills over MCP off: 0 failed,
0 unexpected over the same 53 cases (20 stdio, 33 HTTP). Outlines show
`[status, id, result or error code]` (HTTP) or the replies as `[id, result or error code]` (stdio);
the cases are in `spec/fixtures/mcp/handshakes/`. The reference is Memory on stdio and Everything on
HTTP. `compare.rb`'s informational Ruby SDK target (`rsdk_server.rb`, a one-tool server on `mcp`
1.10.0) answers every case exactly as graph_mem does, so it has no column of its own.

### stdio

20 cases: 8 same, 9 documented divergences, 3 graph_mem only.

| Case | graph_mem | Memory 2.1.1 | Verdict |
| --- | --- | --- | --- |
| initialize 2025-03-26 is echoed | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize 2025-11-25 is echoed, with serverInfo | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize capabilities: no subscribe or listChanged; instructions present | `[[1, "result"]]` | n/a (server-specific) | graph_mem only |
| initialize declares the MCP Apps extension | `[[1, "result"]]` | n/a (server-specific) | graph_mem only |
| initialize 2026-07-28 gets 2025-11-25 | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize "9" gets 2025-11-25 | `[[1, "result"]]` | `[[1, "result"]]` | same |
| server/discover with a 2026-07-28 envelope | `[[7, "result"]]` | `[[7, "result"]]` | same |
| server/discover claiming 2027-01-01 | `[[7, "result"]]` | `[[7, -32022]]` | documented divergence |
| server/discover with an envelope missing clientCapabilities | `[[7, "result"]]` | `[[7, -32602]]` | documented divergence |
| tools/list with a 2026-07-28 envelope and no initialize is served | `[[2, "result"]]` | `[[2, "result"]]` | same |
| discover, then initialize 2025-11-25, then tools/list (the auto-mode fallback path) | `[[1, "result"], [2, -32601], [3, -32602]]` | `[[1, "result"], [2, "result"], [3, "result"]]` | documented divergence |
| malformed lines: parse error, batch, missing jsonrpc, primitive | `[[nil, -32700], [2, "result"], [3, -32600], [nil, -32600]]` | `[]` | documented divergence |
| an unknown notification gets no reply | `[[9, "result"]]` | `[[9, "result"]]` | same |
| tools/call with "id": null is refused, not run | `[[1, "result"], [nil, -32600], [5, "result"]]` | `[[1, "result"], [5, "result"]]` | documented divergence |
| tools/call without an id is a notification: no reply, not run | `[[1, "result"], [5, "result"]]` | `[[1, "result"], [5, "result"]]` | same |
| resources/subscribe is not offered | `[[1, "result"], [4, -32601]]` | n/a (server-specific) | graph_mem only |
| an invalid UTF-8 object key, then a ping | `[[nil, -32700], [2, "result"]]` | `[[1, "result"], [2, "result"]]` | documented divergence |
| tools/call with an invalid UTF-8 tool name, then a ping | `[[1, "result"], [42, -32603], [5, "result"]]` | `[[1, "result"], [42, -32602], [5, "result"]]` | documented divergence |
| a method name that is not valid UTF-8, then a ping | `[[1, "result"], [43, -32600], [6, "result"]]` | `[[43, -32601], [1, "result"], [6, "result"]]` | documented divergence |
| tools/list with a non-object _meta, then a ping | `[[1, "result"], [2, -32602], [3, "result"]]` | `[[1, "result"], [3, "result"]]` | documented divergence |

### Streamable HTTP

33 cases: 14 same, 16 documented divergences, 3 graph_mem only.

| Case | graph_mem | Everything 2.3.0 | Verdict |
| --- | --- | --- | --- |
| server/discover with a 2026-07-28 envelope and headers, no session | `[200, 11, "result"]` | `[200, 11, "result"]` | same |
| 2026-07-28 header without the envelope | `[400, 12, -32602]` | `[400, 12, -32602]` | same |
| MCP-Protocol-Version header disagrees with the envelope | `[400, 13, -32020]` | `[400, 13, -32020]` | same |
| a future protocol revision (2027-01-01) in header and envelope | `[400, 14, -32022]` | `[400, 14, -32022]` | same |
| initialize sent with a 2026-07-28 header | `[200, 20, "result"]` | `[400, 20, -32020]` | documented divergence |
| initialize 2026-07-28 gets 2025-11-25 | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-11-25 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-06-18 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-03-26 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2024-11-05 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize "9" gets 2025-11-25 | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize capabilities: no subscribe or listChanged; instructions present | `[200, 22, "result"]` | n/a (server-specific) | graph_mem only |
| initialize declares the MCP Apps extension | `[200, 23, "result"]` | n/a (server-specific) | graph_mem only |
| in a session, no MCP-Protocol-Version header | `[200, 30, "result"]` | `[200, 30, "result"]` | same |
| in a session, MCP-Protocol-Version 1999-01-01 | `[400, 31, -32022]` | `[400, nil, -32000]` | documented divergence |
| in a session, MCP-Protocol-Version 2026-07-28 | `[200, 32, "result"]` | `[400, nil, -32000]` | documented divergence |
| in a session, tools/list | `[200, 33, "result"]` | `[200, 33, "result"]` | same |
| resources/subscribe is not offered | `[200, 34, -32601]` | n/a (server-specific) | graph_mem only |
| tools/call with "id": null is refused, not run | `[200, nil, -32600]` | `[400, nil, -32700]` | documented divergence |
| tools/call without an id is a notification: 202, not run | `[202, nil, nil]` | `[202, nil, nil]` | same |
| an invalid UTF-8 object key | `[400, nil, -32700]` | `[200, 35, "result"]` | documented divergence |
| tools/call with an invalid UTF-8 tool name | `[200, 42, -32603]` | `[200, 42, -32602]` | documented divergence |
| a method name that is not valid UTF-8 | `[200, 46, -32600]` | `[200, 46, -32601]` | documented divergence |
| a JSON array (batch) body | `[400, nil, -32600]` | `[200, 36, "result"]` | documented divergence |
| a message without the jsonrpc member | `[200, 37, -32600]` | `[400, nil, -32700]` | documented divergence |
| a parse error | `[400, nil, -32700]` | `[400, nil, -32700]` | same |
| a body over 4 MiB | `[413, nil, -32600]` | `[413, nil, -32000]` | documented divergence |
| a second GET stream on one session | `[409, nil, -32600]` | `[409, nil, -32000]` | documented divergence |
| an unknown session | `[404, nil, -32600]` | `[404, 40, -32001]` | documented divergence |
| a request other than initialize, with no session | `[400, nil, -32600]` | `[400, nil, -32000]` | documented divergence |
| an initialize from a foreign Origin | `[403, nil, -32600]` | `[403, nil, -32000]` | documented divergence |
| an initialize from another localhost port | `[403, nil, -32600]` | `[200, 44, "result"]` | documented divergence |
| tools/list with a non-object _meta | `[200, 45, -32602]` | `[400, nil, -32700]` | documented divergence |

Browser origins: graph_mem accepts same-origin requests and the exact origins in
`GRAPH_MEM_MCP_ALLOWED_ORIGINS`, and grants CORS on `/mcp` to that same list. It answers every
preflight 200 (rack-cors) and leaves out the CORS headers for an unlisted origin, where Everything
answers 403; the browser blocks the request either way. Everything 2.3.0 and later listen only on
127.0.0.1 by default (2.0.x did not); the harness runs every server on loopback.

## Known divergences

Each bullet is one `divergence` text from the fixture files, with the cases it covers.

### stdio

- graph_mem (the official SDK) answers discover with its supported versions whatever the envelope
  claims; Memory answers -32022. Either way the client then picks a version both support. —
  *server/discover claiming 2027-01-01*
- graph_mem (the official SDK) answers discover without clientCapabilities in the envelope; Memory
  refuses it with -32602. — *server/discover with an envelope missing clientCapabilities*
- After server/discover, graph_mem (the official SDK) keeps the process in the 2026-07-28 era and
  refuses the legacy initialize and the tools/list after it; Memory falls back in-process. The TS
  client isn't affected: in auto mode it probes in a sibling process. — *discover, then initialize
  2025-11-25, then tools/list (the auto-mode fallback path)*
- graph_mem (the official SDK) answers malformed lines with JSON-RPC errors and serves a
  one-element batch; the TS SDK drops them silently. Both keep serving. — *malformed lines: parse
  error, batch, missing jsonrpc, primitive*
- Neither runs it: graph_mem answers -32600 (like the Ruby SDK 1.9.0 and 1.10.0); the TS SDK drops
  the line silently. — *tools/call with "id": null is refused, not run*
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.9.0 and 1.10.0); Node decodes the
  byte as U+FFFD and answers the ping. Both keep serving. — *an invalid UTF-8 object key, then a
  ping*
- graph_mem can't echo the invalid name back and answers -32603 with the id (Ruby SDK 1.8.2,
  1.9.0 and 1.10.0, #629); Node decodes the byte as U+FFFD and answers -32602 "Tool synth-� not
  found". Both keep serving. — *tools/call with an invalid UTF-8 tool name, then a ping*
- graph_mem refuses the method as an invalid request, -32600 with the id (Ruby SDK 1.10.0, #672);
  Node decodes the byte as U+FFFD and answers -32601 Method not found. Both keep serving. — *a method
  name that is not valid UTF-8, then a ping*
- graph_mem refuses a non-object _meta with -32602 and the id (Ruby SDK 1.9.0, #651); Memory's
  transport fails to parse the message (a ZodError on stderr) and sends no reply. Both keep
  serving. — *tools/list with a non-object _meta, then a ping*
- Server-specific: Memory implements resource subscriptions and list-changed notifications;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
- Server-specific: graph_mem declares the MCP Apps extension (io.modelcontextprotocol/ui, 1.87.0;
  off with the mcp_apps_enabled setting) and serves its ui:// view; Memory declares no extensions. —
  *initialize declares the MCP Apps extension*
- Server-specific: Memory implements resource subscriptions; graph_mem advertises subscribe:
  false. — *resources/subscribe is not offered*

### Streamable HTTP

- graph_mem is deliberately lenient: the header is ignored on initialize, which is what a
  falling-back client needs. — *initialize sent with a 2026-07-28 header*
- Same status; graph_mem (the official SDK) answers an unsupported MCP-Protocol-Version with -32022
  listing the supported versions and echoes the id, the TS SDK with -32000 and id: null. — *in a
  session, MCP-Protocol-Version 1999-01-01*
- graph_mem (the official SDK) serves a request whose MCP-Protocol-Version names the newer revision
  on a 2025 session; the TS SDK refuses it with 400 -32000. — *in a session, MCP-Protocol-Version
  2026-07-28*
- Neither runs it; graph_mem (the official SDK) answers -32600 with HTTP 200, the TS SDK -32700
  with 400. — *tools/call with "id": null is refused, not run*
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.9.0 and 1.10.0); Node decodes the
  byte as U+FFFD and answers the ping. — *an invalid UTF-8 object key*
- graph_mem can't echo the invalid name back and answers -32603 with the id (Ruby SDK 1.8.2,
  1.9.0 and 1.10.0, #629); Node decodes the byte as U+FFFD and answers -32602 "Tool synth-� not
  found". — *tools/call with an invalid UTF-8 tool name*
- graph_mem refuses the method as an invalid request, -32600 with the id (Ruby SDK 1.10.0, #672);
  Node decodes the byte as U+FFFD and answers -32601 Method not found. — *a method name that is not
  valid UTF-8*
- graph_mem refuses a non-object _meta with -32602 and the id, HTTP 200 (Ruby SDK 1.9.0, #651);
  Everything's transport can't parse the message and answers HTTP 400 -32700 "Parse error: Invalid
  JSON-RPC message" with id null. — *tools/list with a non-object _meta*
- graph_mem refuses batches (removed in 2025-06-18, and an array body was a high bug before
  1.54.0); the TS SDK still accepts them on the 2025 transport. — *a JSON array (batch) body*
- Both refuse it; graph_mem (the official SDK) answers -32600 with HTTP 200 and echoes the id, the
  TS SDK -32700 with 400. — *a message without the jsonrpc member*
- Same status and the same 4 MiB cap; the JSON-RPC error code differs. — *a body over 4 MiB*
- Same status; graph_mem (the official SDK) uses -32600, the TS SDK -32000. — *a second GET stream
  on one session*
- Same status; graph_mem (the official SDK) uses -32600 without the id, the TS SDK -32001 with the
  id. Clients start a new session on 404 either way. — *an unknown session*
- Both refuse it with 400 and no id; graph_mem (the official SDK) uses -32600, the TS SDK -32000
  "Server not initialized". — *a request other than initialize, with no session*
- Same status; graph_mem (the official SDK) uses -32600 without the id, Everything 2.3.0 -32000
  "Invalid Origin". — *an initialize from a foreign Origin*
- Everything 2.3.0 accepts any localhost origin; graph_mem accepts only same-origin and
  GRAPH_MEM_MCP_ALLOWED_ORIGINS (exact scheme://host:port). — *an initialize from another localhost
  port*
- Server-specific: Everything implements subscriptions, list-changed notifications and logging;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
- Server-specific: graph_mem declares the MCP Apps extension (io.modelcontextprotocol/ui, 1.87.0;
  off with the mcp_apps_enabled setting) and serves its ui:// view; Everything declares no
  extensions. — *initialize declares the MCP Apps extension*
- Server-specific: Everything implements resource subscriptions; graph_mem advertises subscribe:
  false. — *resources/subscribe is not offered*

## MCP Apps

Since 1.87.0 (`docs/plans/done/mcp-apps-plan.md`, step A) graph_mem serves the MCP Apps extension
(SEP-1865, stable 2026-01-26), unless Settings › Feature flags › **MCP Apps views**
(`mcp_apps_enabled`, default on) is off:

- `initialize` declares `capabilities.extensions["io.modelcontextprotocol/ui"]`
  (`mimeTypes: ["text/html;profile=mcp-app"]`), for every client.
- `resources/list` lists `ui://graph-mem/graph` on all three profiles (it was empty before);
  `resources/read` serves it as `text/html;profile=mcp-app` with `_meta.ui.prefersBorder` on the
  content item and no `csp`, so the host's restrictive default CSP applies (everything is inlined; the
  view makes no network request of its own).
- `tools/list` adds `_meta.ui.resourceUri` to `traverse_graph` and `find_shortest_path` only (nested
  form only, no `visibility`). `tools/list` can't vary per client in the gem, so every client gets it; a
  client without the extension treats them as plain tools.
- `tools/call` results are unchanged for every tool and client; `resources/templates/list` too.

Turned off, the wire is exactly the 1.86.2 one: no extension, no `ui://` resource, no `_meta.ui`.
Saving the setting rebuilds the HTTP servers (open MCP sessions close); a stdio runner picks it up
when restarted.

### The view (Graph mode 1.88.0, Search mode 1.89.0)

In 1.87.0 the view was a stub. 1.88.0 draws the graph (Graph mode), and 1.89.0 adds Search mode (usage in
[mcp_tools.md](mcp_tools.md#mcp-apps-interactive-view); for users, the
[MCP Apps views guide](guides/mcp-apps-views.md)). In both releases only the `resources/read` text changed:
capabilities, `tools/list`, `resources/list`, `resources/templates/list` and every `tools/call` result
are the 1.87.0 ones (the snapshots and handshake files are unchanged).

- **One document, about 480 KB:** the HTML shell from `lib/graph_mem/mcp_apps/view/` with one inline
  module script holding the vendored Cytoscape 3.31.4 (`vendor/javascript/`), Explore's
  `cytoscape_config.js` and the view scripts, built once per process by
  `GraphMem::McpApps::ViewBuilder`. No CDN, no `csp` domains, no network request: it runs under the
  host's default CSP.
- **Bridge** (JSON-RPC 2.0 over `postMessage`, no SDK): `ui/initialize` (protocol `2026-01-26`), then
  `ui/notifications/initialized`; it takes `tool-input`, `tool-result`, `tool-cancelled`,
  `host-context-changed`, `ui/resource-teardown` and `ping`, and sends `tools/call`,
  `ui/request-display-mode` (fullscreen, only when `hostContext.availableDisplayModes` lists it),
  `ui/notifications/size-changed` and `ui/update-model-context`. Only messages from the host frame
  count; an unknown request gets `-32601`, other unknown messages are ignored.
- **Theming:** `hostContext.styles.variables` (standard CSS variables) and `theme`, with fallbacks;
  fonts from `--font-sans` or the system (the default CSP blocks embedded fonts).
- **Search mode** (1.89.0): `search` in summary mode only, with a query, since catalog mode refuses
  `project_id` and `entity_types`. Its pager is previous / next, because summary pages report no total. The
  view has no `<form>`: the sandbox has no `allow-forms`, which blocks a submission before its event fires.

**Hosts (manual checks):**

| Host | Build | Renders the view | View-initiated calls | Notes |
|---|---|---|---|---|
| Cursor | 3.23.23 (1.87.0 stub) | yes, once per chat | no consent prompt; results stay out of the model's context | needs a global `mcp.json` entry |
| Cursor | 3.23.23 (1.88.0 Graph mode) | yes: every `traverse_graph` mode, both `find_shortest_path` outcomes, the ~464 KB document | no consent prompt; panel, expand, path, "Show this project" and both subset buttons work | follows light and dark; no `fullscreen` mode offered (button hidden); `ui/update-model-context` not passed to the model |
| Cursor | 3.23.23 (1.89.0 Search mode) | yes: Graph mode as in 1.88.0, and the mode switch in a view that got no new result | no consent prompt; query, every filter kind, previous / next (next off on a short page), a hit's details, "Show as graph" and a `search` error in the status line work | follows light and dark; `ui/update-model-context` still not passed to the model |
| Devin Desktop | 3.13.4 (1.87.0 stub) | no | — | plain tool results |
| Claude | — | deferred | — | no supported client at hand |

## Skills over MCP

Since 1.91.0 (`docs/plans/done/auto-adoption-plan.md`, PR B) graph_mem can serve the repo's `skills/` through the
Skills extension (SEP-2640, `io.modelcontextprotocol/skills`) when Settings › Feature flags › **Skills over MCP**
(`mcp_skills_enabled`, **default off**) is on:

- `initialize` declares `capabilities.extensions["io.modelcontextprotocol/skills"]` (`{}`: no `directoryRead`),
  next to the MCP Apps entry when that is on too.
- `skills/list` and `skills/get` answer with each skill's `skill://<name>/SKILL.md` URI, its frontmatter and its
  files with sizes and `sha256:` digests. `graph-mem-mcp-toolset` (with its three `references/` files) is
  served on all three profiles; `project-scan` on `/mcp` and `/mcp/maintenance` only (it needs write tools).
- `resources/list` adds each served `SKILL.md` (`text/markdown`); `resources/read` serves every listed file
  byte for byte, and answers `-32602` "Skill file not found" for a `skill://` URI under a served skill that
  names none of its files (another unknown URI is `-32602` "Resource not found", as before).
- Tools, prompts, resource templates, the instructions and every `tools/call` result are unchanged; tool counts
  stay 12 / 9 / 22.

Turned off, the wire is exactly the 1.90.0 one: no extension, `skills/list` is `-32601`, and a `skill://` read
is `-32602` "Resource not found". The skills are read from disk when a server is built, so an edited skill is
served after the next rebuild or restart (the gem refuses a file changed since then with `-32603`). A file
under `skills/` the gem refuses (a stray editor file, a hard link, a skill breaking the rules) is logged as
`[McpSkills] skills not served`, and that server is built without the extension; the tools are unaffected. Saving the
setting rebuilds the HTTP servers (open MCP sessions close); a stdio runner picks it up when restarted. The
`AccessGate` covers `skills/*` like every `/mcp` method.

Hosts (2026-11-18). No host we use consumes the extension yet: Claude, Claude Code and Cursor have no Skills
entry on the [extension client matrix](https://modelcontextprotocol.io/extensions/client-matrix) and aren't
named in the ext-skills [implementations list](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md),
where MCP Inspector is listed as partial (CLI skill verification since 2.6.0).

| Client | Version | Toggle on | Result |
|---|---|---|---|
| MCP Inspector CLI (`--method skills/list --verify --require-digests`) | 2.16.0 | `/mcp`, `/mcp/readonly`, `/mcp/maintenance` | every skill and file verified, no conformance or frontmatter error: 2 skills and 5 files, 1 and 4 on readonly; `skills/get` and a `references/` read match the files |
| Claude Code | 2.1.327 | `/mcp` | connects and lists its 12 tools as before; doesn't consume skills over MCP (not supported) |
| Cursor | 3.23.23 | on and off | connects, and the tool list is the same either way; doesn't consume skills over MCP (not supported) |

## Re-running

- Harness, setup and the `compare.rb` / `clients.sh` commands: [`script/mcp_compat/README.md`](../script/mcp_compat/README.md).
- In the normal suite: [`spec/requests/mcp_protocol_compat_spec.rb`](../spec/requests/mcp_protocol_compat_spec.rb) asserts graph_mem's answers (no Node needed).
