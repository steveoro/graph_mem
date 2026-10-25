# MCP protocol compatibility

## Summary

graph_mem 1.54.x speaks MCP 2024-11-05 through 2025-11-25 over Streamable HTTP and stdio. A
supported `initialize` version is echoed; anything else (2026-07-28, a future date, garbage) gets
2025-11-25. 2026-07-28 clients fall back automatically: their `server/discover` probe gets a
JSON-RPC error, and the client then runs `initialize` (2025-11-25). `MCP_PROTOCOL_NEGOTIATION=legacy`
on the client skips the probe. Native 2026-07-28 support comes with the migration to the official
`mcp` gem (MG-5). The legacy HTTP+SSE endpoint (`/mcp/sse`) is still served, but nothing below
covers it.

## How 2026-07-28 clients fall back

What the TS client 2.3.1 does with the answer to its `server/discover` probe:

- Any JSON-RPC error (including `-32601`, `-32600`, `-32001`, `-32020`, `-32021`) → legacy
  fallback (`initialize`).
- `-32022` → corrective retry if `data.supported` lists a mutual modern version, otherwise legacy.
- A result that fails the discover schema → legacy.
- HTTP 4xx (except 401/403) → the body is parsed and the rules above apply.
- HTTP 401/403 or ≥ 500 → hard error, **no** fallback.
- On stdio, a closed pipe or a timeout → legacy. In stdio `auto` mode the probe runs on a
  disposable sibling process spawned from the same command; the real process is started afterwards.
- The SDK default is `legacy` (no probe); Claude Code chose `auto`.

## Client matrix

`script/mcp_compat/clients.sh` at 1.54.1 (2026-10-24): 12 of 12 OK, all on 2025-11-25 in the
legacy era.

| Client | Mode | Transport | OK | Protocol | Timing note |
| --- | --- | --- | --- | --- | --- |
| TS client 2.3.1 | auto | stdio | OK | 2025-11-25 | about 1.2 s longer than `legacy` (the `server/discover` probe runs in a sibling process) |
| TS client 2.3.1 | auto | HTTP | OK | 2025-11-25 | |
| TS client 2.3.1 | legacy | stdio | OK | 2025-11-25 | |
| TS client 2.3.1 | legacy | HTTP | OK | 2025-11-25 | |
| Ruby SDK 1.8.0 | auto | stdio | OK | 2025-11-25 | `auto` costs nothing extra |
| Ruby SDK 1.8.0 | auto | HTTP | OK | 2025-11-25 | `auto` costs nothing extra |
| Ruby SDK 1.8.0 | legacy | stdio | OK | 2025-11-25 | |
| Ruby SDK 1.8.0 | legacy | HTTP | OK | 2025-11-25 | |
| Ruby SDK 1.8.1 | auto | stdio | OK | 2025-11-25 | `auto` costs nothing extra |
| Ruby SDK 1.8.1 | auto | HTTP | OK | 2025-11-25 | `auto` costs nothing extra |
| Ruby SDK 1.8.1 | legacy | stdio | OK | 2025-11-25 | |
| Ruby SDK 1.8.1 | legacy | HTTP | OK | 2025-11-25 | |

## Claude Code

Steve's run of `docs/plans/claude-mcp-client-check.md` (PR-3 step 5), 2026-10-25: Claude Code
2.1.310 against graph_mem 1.54.1 (`bin/mcp` over HTTP with a bearer token, and the stdio runner).
No protocol or connection failure in either run. The misses were four server-side gaps, all addressed
in 1.54.2 (#115), and expectations the checklist got wrong, since corrected in it.

| Check | Default negotiation | `MCP_PROTOCOL_NEGOTIATION=legacy` | Notes |
| --- | --- | --- | --- |
| `claude mcp list`: 4 ✔, gm-badtoken ✘ 401 | OK (Part A, run once) | n/a | |
| Negotiated protocol, HTTP (from the log) | not recorded | not recorded | |
| Negotiated protocol, stdio (from the log) | not recorded | not recorded | |
| N1 curl wrong token → 401 + WWW-Authenticate | OK | n/a | |
| N2 stdio stdout `json=2 noise=0` | OK | n/a | |
| N3 `id: null` → 400 -32600; id-less → 202; neither wrote `McpCheck NullId` | OK | n/a | Step 5 found no `McpCheck NullId` in either run |
| N4 invalid UTF-8 key → 400 -32700 | OK | n/a | No `id` member |
| N5 capabilities: subscribe/listChanged false, prompts listChanged false; `instructions` present (1.54.x+) | OK | n/a | |
| B 1–13 gm-http (count PASS / 13) | 12 / 13 | 12 / 13 | Step 12: Claude Code doesn't list resource templates; reads need a percent-encoded name and `include_relations=true` (checklist corrected) |
| B 14–16 gm-ro | 3 / 3 | 3 / 3 | |
| B 17–23 gm-maint (incl. scan refusals 19–22) | 3 / 7 | 3 / 7 | 19–21: refused correctly but without a machine-readable code; 23: `scan_project_status` answered "not found" until a worker started the scan. Both fixed in 1.54.2 |
| B 24 gm-stdio | PASS | PASS | Errors came back as plain `Error:` text instead of the JSON envelope; fixed in 1.54.2 |
| B 25 gm-badtoken | PASS | PASS | `AUTH_HEADER_REJECTED`, HTTP 401 |
| B 26 cleanup, no McpCheck left | FAIL | PARTIAL | An empty Project couldn't be deleted over MCP; finished from the operator UI. 1.54.2 allows it on the maintenance profile |
| First stdio connect time (rough, seconds) | not recorded | not recorded | |
| Anything odd (stderr in the Claude Code UI, timeouts, warnings) | none | none | `search` reports 2 entities in scope with a project context and 19 without one: expected (project scope vs the shared global scope) |

## Handshake comparison

`script/mcp_compat/compare.rb`, 2026-10-24: graph_mem 1.54.1, reference servers 2.0.0 with SDK
2.3.1, Ruby SDK 1.8.1. Outlines show `[status, id, result or error code]` (HTTP) or the replies as
`[id, result or error code]` (stdio); the cases are in `spec/fixtures/mcp/handshakes/`. The reference
is Memory on stdio and Everything on HTTP. The Ruby SDK column is informational (input for MG-0): it
has no expectations and never changes the verdict.

### stdio

| Case | graph_mem | Memory 2.0.0 | Ruby SDK 1.8.1 | Verdict |
| --- | --- | --- | --- | --- |
| initialize 2025-03-26 is echoed | `[[1, "result"]]` | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize 2025-11-25 is echoed, with serverInfo | `[[1, "result"]]` | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize capabilities: no subscribe or listChanged; instructions present | `[[1, "result"]]` | n/a (server-specific) | `[[1, "result"]]` | graph_mem only |
| initialize 2026-07-28 gets 2025-11-25 | `[[1, "result"]]` | `[[1, "result"]]` | `[[1, "result"]]` | same |
| initialize "9" gets 2025-11-25 | `[[1, "result"]]` | `[[1, "result"]]` | `[[1, "result"]]` | same |
| server/discover with a 2026-07-28 envelope | `[[7, -32601]]` | `[[7, "result"]]` | `[[7, "result"]]` | documented divergence |
| server/discover claiming 2027-01-01 | `[[7, -32601]]` | `[[7, -32022]]` | `[[7, "result"]]` | documented divergence |
| server/discover with an envelope missing clientCapabilities | `[[7, -32601]]` | `[[7, -32602]]` | `[[7, "result"]]` | documented divergence |
| tools/list with a 2026-07-28 envelope and no initialize is served | `[[2, "result"]]` | `[[2, "result"]]` | `[[2, "result"]]` | same |
| discover, then initialize 2025-11-25, then tools/list (the auto-mode fallback path) | `[[1, -32601], [2, "result"], [3, "result"]]` | `[[1, "result"], [2, "result"], [3, "result"]]` | `[[1, "result"], [2, -32601], [3, -32602]]` | documented divergence |
| malformed lines: parse error, batch, missing jsonrpc, primitive | `[[nil, -32700], [nil, -32600], [3, -32600], [nil, -32600]]` | `[]` | `[[nil, -32700], [2, "result"], [3, -32600], [nil, -32600]]` | documented divergence |
| an unknown notification gets no reply | `[[9, "result"]]` | `[[9, "result"]]` | `[[9, "result"]]` | same |
| tools/call with "id": null is refused, not run | `[[1, "result"], [nil, -32600], [5, "result"]]` | `[[1, "result"], [5, "result"]]` | `[[1, "result"], [nil, -32600], [5, "result"]]` | documented divergence |
| tools/call without an id is a notification: no reply, not run | `[[1, "result"], [5, "result"]]` | `[[1, "result"], [5, "result"]]` | `[[1, "result"], [5, "result"]]` | same |
| resources/subscribe is not offered | `[[1, "result"], [4, -32601]]` | n/a (server-specific) | `[[1, "result"], [4, -32601]]` | graph_mem only |
| an invalid UTF-8 object key, then a ping | `[[nil, -32700], [2, "result"]]` | `[[1, "result"], [2, "result"]]` | `[[nil, -32700], [2, "result"]]` | documented divergence |

On the auto-mode fallback path the Ruby SDK 1.8.1 refuses the legacy `initialize` that follows a
`server/discover` (`-32601`, then `-32602` for `tools/list`), while Memory falls back in the same
process. This matters for MG-5. The TS client isn't affected, because on stdio it probes in a
sibling process.

### Streamable HTTP

| Case | graph_mem | Everything 2.0.0 | Ruby SDK 1.8.1 | Verdict |
| --- | --- | --- | --- | --- |
| server/discover with a 2026-07-28 envelope and headers, no session | `[400, 11, -32600]` | `[200, 11, "result"]` | `[200, 11, "result"]` | documented divergence |
| 2026-07-28 header without the envelope | `[400, 12, -32600]` | `[400, 12, -32602]` | `[400, 12, -32602]` | documented divergence |
| MCP-Protocol-Version header disagrees with the envelope | `[400, 13, -32600]` | `[400, 13, -32020]` | `[400, 13, -32020]` | documented divergence |
| a future protocol revision (2027-01-01) in header and envelope | `[400, 14, -32600]` | `[400, 14, -32022]` | `[400, 14, -32022]` | documented divergence |
| initialize sent with a 2026-07-28 header | `[200, 20, "result"]` | `[400, 20, -32020]` | `[200, 20, "result"]` | documented divergence |
| initialize 2026-07-28 gets 2025-11-25 | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-11-25 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-06-18 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2025-03-26 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize 2024-11-05 is echoed | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize "9" gets 2025-11-25 | `[200, 21, "result"]` | `[200, 21, "result"]` | `[200, 21, "result"]` | same |
| initialize capabilities: no subscribe or listChanged; instructions present | `[200, 22, "result"]` | n/a (server-specific) | `[200, 22, "result"]` | graph_mem only |
| in a session, no MCP-Protocol-Version header | `[200, 30, "result"]` | `[200, 30, "result"]` | `[200, 30, "result"]` | same |
| in a session, MCP-Protocol-Version 1999-01-01 | `[400, 31, -32000]` | `[400, nil, -32000]` | `[400, 31, -32022]` | documented divergence |
| in a session, MCP-Protocol-Version 2026-07-28 | `[400, 32, -32000]` | `[400, nil, -32000]` | `[200, 32, "result"]` | documented divergence |
| in a session, tools/list | `[200, 33, "result"]` | `[200, 33, "result"]` | `[200, 33, "result"]` | same |
| resources/subscribe is not offered | `[200, 34, -32601]` | n/a (server-specific) | `[200, 34, -32601]` | graph_mem only |
| tools/call with "id": null is refused, not run | `[400, nil, -32600]` | `[400, nil, -32700]` | `[200, nil, -32600]` | documented divergence |
| tools/call without an id is a notification: 202, not run | `[202, nil, nil]` | `[202, nil, nil]` | `[202, nil, nil]` | same |
| an invalid UTF-8 object key | `[400, nil, -32700]` | `[200, 35, "result"]` | `[400, nil, -32700]` | documented divergence |
| a JSON array (batch) body | `[400, nil, -32600]` | `[200, 36, "result"]` | `[400, nil, -32600]` | documented divergence |
| a message without the jsonrpc member | `[400, 37, -32600]` | `[400, nil, -32700]` | `[200, 37, -32600]` | documented divergence |
| a parse error | `[400, nil, -32700]` | `[400, nil, -32700]` | `[400, nil, -32700]` | same |
| a body over 4 MiB | `[413, nil, -32600]` | `[413, nil, -32000]` | `[413, nil, -32600]` | documented divergence |
| a second GET stream on one session | `[409, nil, -32000]` | `[409, nil, -32000]` | `[409, nil, -32600]` | same |
| an unknown session | `[404, 40, -32001]` | `[404, 40, -32001]` | `[404, nil, -32600]` | same |
| a request other than initialize, with no session | `[400, 41, -32600]` | `[400, nil, -32000]` | `[400, nil, -32600]` | documented divergence |

## Known divergences

Each bullet is one `divergence` text from the fixture files, with the cases it covers and the
plan step that changes it (`changes_in`) when set.

### stdio

- graph_mem has no 2026-07-28 era yet: any JSON-RPC error to the probe makes 2026-07-28 clients
  fall back to initialize. — *server/discover with a 2026-07-28 envelope* (changes in MG-5)
- Fallback-safe error code: both are JSON-RPC errors to the probe, so clients fall back to
  initialize. — *server/discover claiming 2027-01-01*, *server/discover with an envelope missing
  clientCapabilities* (changes in MG-5)
- graph_mem refuses the probe (no 2026-07-28 era yet); initialize and tools/list then succeed on
  both. — *discover, then initialize 2025-11-25, then tools/list (the auto-mode fallback path)*
  (changes in MG-5)
- graph_mem answers malformed lines with a JSON-RPC error; the TS SDK drops them silently
  (onerror). Both keep serving. — *malformed lines: parse error, batch, missing jsonrpc, primitive*
- Neither runs it: graph_mem answers -32600 (like the Ruby SDK 1.8.1); the TS SDK drops the line
  silently. — *tools/call with "id": null is refused, not run*
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.8.1); Node decodes the byte as
  U+FFFD and answers the ping. Both keep serving. — *an invalid UTF-8 object key, then a ping*
- Server-specific: Memory implements resource subscriptions and list-changed notifications;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
- Server-specific: Memory implements resource subscriptions; graph_mem advertises subscribe:
  false. — *resources/subscribe is not offered*

### Streamable HTTP

- graph_mem has no 2026-07-28 era yet: a 4xx JSON-RPC error to the probe makes 2026-07-28 clients
  fall back to initialize. — *server/discover with a 2026-07-28 envelope and headers, no session*
  (changes in MG-5)
- Fallback-safe error code: both are 4xx JSON-RPC errors with the id, so clients fall back to
  initialize. — *2026-07-28 header without the envelope*, *MCP-Protocol-Version header disagrees
  with the envelope*, *a future protocol revision (2027-01-01) in header and envelope* (changes in
  MG-5)
- graph_mem is deliberately lenient: the header is ignored on initialize, which is what a
  falling-back client needs. — *initialize sent with a 2026-07-28 header*
- Same status and code; graph_mem echoes the request id (PR-2 §2.19), the TS SDK sends id: null.
  — *in a session, MCP-Protocol-Version 1999-01-01*, *in a session, MCP-Protocol-Version
  2026-07-28*
- Neither runs it; the TS SDK reports the schema failure as -32700, graph_mem (like the Ruby SDK
  1.8.1) as -32600. — *tools/call with "id": null is refused, not run*
- graph_mem refuses invalid UTF-8 with -32700 (like the Ruby SDK 1.8.1); Node decodes the byte as
  U+FFFD and answers the ping. — *an invalid UTF-8 object key*
- graph_mem refuses batches (removed in 2025-06-18, and an array body was a high bug before
  1.54.0); the TS SDK still accepts them on the 2025 transport. — *a JSON array (batch) body*
- Both refuse it with 400; graph_mem uses -32600 and echoes the id, the TS SDK reports -32700. —
  *a message without the jsonrpc member*
- Same status and the same 4 MiB cap; the JSON-RPC error code differs. — *a body over 4 MiB*
- Both refuse it with 400; graph_mem uses -32600 and echoes the id, the TS SDK reports -32000
  "Server not initialized". — *a request other than initialize, with no session*
- Server-specific: Everything implements subscriptions, list-changed notifications and logging;
  graph_mem doesn't. — *initialize capabilities: no subscribe or listChanged; instructions present*
- Server-specific: Everything implements resource subscriptions; graph_mem advertises subscribe:
  false. — *resources/subscribe is not offered*

## Re-running

- Harness, setup and the `compare.rb` / `clients.sh` commands: [`script/mcp_compat/README.md`](../script/mcp_compat/README.md).
- In the normal suite: [`spec/requests/mcp_protocol_compat_spec.rb`](../spec/requests/mcp_protocol_compat_spec.rb) asserts graph_mem's answers (no Node needed).

## Next

Native 2026-07-28 and the migration to the official `mcp` gem: [`docs/plans/mcp-update-plan.md`](plans/mcp-update-plan.md) §MG (MG-0).
