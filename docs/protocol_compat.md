# MCP protocol compatibility

## Summary

Since 1.55.0 graph_mem is served by the official MCP Ruby SDK (`mcp` gem, pinned to 1.8.1) over
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

Moving another Rails app from fast-mcp to the `mcp` gem:
[`docs/guides/migrating-fast-mcp-to-mcp-gem.md`](guides/migrating-fast-mcp-to-mcp-gem.md).

## Client matrix

`script/mcp_compat/clients.sh` at 1.55.1 (2026-10-25): 12 of 12 OK. Every `auto` row negotiates
2026-07-28, every `legacy` row 2025-11-25.

| Client | Mode | Transport | OK | Protocol | Timing note |
| --- | --- | --- | --- | --- | --- |
| TS client 2.3.1 | auto | stdio | OK | 2026-07-28 | about 1.3 s longer than `legacy` (the `server/discover` probe runs in a sibling process) |
| TS client 2.3.1 | auto | HTTP | OK | 2026-07-28 | |
| TS client 2.3.1 | legacy | stdio | OK | 2025-11-25 | |
| TS client 2.3.1 | legacy | HTTP | OK | 2025-11-25 | |
| Ruby SDK 1.8.0 | auto | stdio | OK | 2026-07-28 | `auto` costs nothing extra |
| Ruby SDK 1.8.0 | auto | HTTP | OK | 2026-07-28 | |
| Ruby SDK 1.8.0 | legacy | stdio | OK | 2025-11-25 | |
| Ruby SDK 1.8.0 | legacy | HTTP | OK | 2025-11-25 | |
| Ruby SDK 1.8.1 | auto | stdio | OK | 2026-07-28 | `auto` costs nothing extra |
| Ruby SDK 1.8.1 | auto | HTTP | OK | 2026-07-28 | |
| Ruby SDK 1.8.1 | legacy | stdio | OK | 2025-11-25 | |
| Ruby SDK 1.8.1 | legacy | HTTP | OK | 2025-11-25 | |

## Claude Code

`script/mcp_compat/claude_client_check.rb` (the automated
[`docs/plans/claude-mcp-client-check.md`](plans/claude-mcp-client-check.md)), 2026-10-25: Claude
Code 2.1.310 against graph_mem 1.55.0, over HTTP (default, readonly and maintenance profiles, and a
wrong bearer token) and stdio. All checks pass in both modes. Claude Code negotiates 2026-07-28 over
HTTP and stdio by default, and 2025-11-25 with `MCP_PROTOCOL_NEGOTIATION=legacy`.

The first, manual run (graph_mem 1.54.1, the same Claude Code version) had no protocol or connection
failure either. It found four server-side gaps, all fixed in 1.54.2: scan refusals without a
machine-readable `code`, `scan_project_status` answering "not found" until a worker started the scan,
plain `Error:` text instead of the JSON envelope on stdio, and no way to delete an empty Project over
MCP.

## Handshake comparison

`script/mcp_compat/compare.rb`, 2026-10-25: graph_mem 1.55.1, reference servers 2.0.0 with SDK
2.3.1, on Node 22. 0 failed expectations, 0 unexpected differences. Outlines show
`[status, id, result or error code]` (HTTP) or the replies as `[id, result or error code]` (stdio);
the cases are in `spec/fixtures/mcp/handshakes/`. The reference is Memory on stdio and Everything on
HTTP. `compare.rb`'s informational Ruby SDK target (`rsdk_server.rb`, a one-tool server on `mcp`
1.8.1) now answers every case exactly as graph_mem does, so it has no column of its own.

### stdio

16 cases: 8 same, 6 documented divergences, 2 graph_mem only.

| Case | graph_mem | Memory 2.0.0 | Verdict |
| --- | --- | --- | --- |
| initialize 2025-03-26 is echoed | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize 2025-11-25 is echoed, with serverInfo | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize capabilities: no subscribe or listChanged; instructions present | `[[1, "result"]]` | n/a (server-specific) | graph_mem only |
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

### Streamable HTTP

27 cases: 14 same, 11 documented divergences, 2 graph_mem only.

| Case | graph_mem | Everything 2.0.0 | Verdict |
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
| in a session, no MCP-Protocol-Version header | `[200, 30, "result"]` | `[200, 30, "result"]` | same |
| in a session, MCP-Protocol-Version 1999-01-01 | `[400, 31, -32022]` | `[400, nil, -32000]` | documented divergence |
| in a session, MCP-Protocol-Version 2026-07-28 | `[200, 32, "result"]` | `[400, nil, -32000]` | documented divergence |
| in a session, tools/list | `[200, 33, "result"]` | `[200, 33, "result"]` | same |
| resources/subscribe is not offered | `[200, 34, -32601]` | n/a (server-specific) | graph_mem only |
| tools/call with "id": null is refused, not run | `[200, nil, -32600]` | `[400, nil, -32700]` | documented divergence |
| tools/call without an id is a notification: 202, not run | `[202, nil, nil]` | `[202, nil, nil]` | same |
| an invalid UTF-8 object key | `[400, nil, -32700]` | `[200, 35, "result"]` | documented divergence |
| a JSON array (batch) body | `[400, nil, -32600]` | `[200, 36, "result"]` | documented divergence |
| a message without the jsonrpc member | `[200, 37, -32600]` | `[400, nil, -32700]` | documented divergence |
| a parse error | `[400, nil, -32700]` | `[400, nil, -32700]` | same |
| a body over 4 MiB | `[413, nil, -32600]` | `[413, nil, -32000]` | documented divergence |
| a second GET stream on one session | `[409, nil, -32600]` | `[409, nil, -32000]` | documented divergence |
| an unknown session | `[404, nil, -32600]` | `[404, 40, -32001]` | documented divergence |
| a request other than initialize, with no session | `[400, nil, -32600]` | `[400, nil, -32000]` | documented divergence |

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
- Neither runs it: graph_mem answers -32600 (like the Ruby SDK 1.8.1); the TS SDK drops the line
  silently. — *tools/call with "id": null is refused, not run*
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.8.1); Node decodes the byte as
  U+FFFD and answers the ping. Both keep serving. — *an invalid UTF-8 object key, then a ping*
- Server-specific: Memory implements resource subscriptions and list-changed notifications;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
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
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.8.1); Node decodes the byte as
  U+FFFD and answers the ping. — *an invalid UTF-8 object key*
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
- Server-specific: Everything implements subscriptions, list-changed notifications and logging;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
- Server-specific: Everything implements resource subscriptions; graph_mem advertises subscribe:
  false. — *resources/subscribe is not offered*

## Re-running

- Harness, setup and the `compare.rb` / `clients.sh` commands: [`script/mcp_compat/README.md`](../script/mcp_compat/README.md).
- In the normal suite: [`spec/requests/mcp_protocol_compat_spec.rb`](../spec/requests/mcp_protocol_compat_spec.rb) asserts graph_mem's answers (no Node needed).
