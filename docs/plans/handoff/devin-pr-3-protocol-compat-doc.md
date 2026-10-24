# Devin handoff — PR-3 step 6: `docs/protocol_compat.md`

Plan: `docs/plans/mcp-update-plan.md` PR-3 §3.1 step 6 (and §0b). Docs only: no code, no specs,
no version bump (PR-3 already bumps to 1.54.1).

- **Branch:** `devin/pr-3-protocol-compat-doc`, off `claude/pr-3-mcp-interop-v2-reference`; open the
  PR **against that branch** (not `main`), so the doc ships in 1.54.1.
- **Files (touch only these):** `docs/protocol_compat.md` (new), `README.md` (one link),
  `CHANGELOG.md` (one line).
- **Sources to copy from, not to reinterpret:** plan §0b; `spec/fixtures/mcp/handshakes/*.json`
  (each case's `name`, `divergence`, `changes_in`); `script/mcp_compat/README.md` ("Expected
  results"); the tables at the end of this file. **Stop and ask** if a source contradicts another,
  or if a sentence would need a judgement call (wording beyond what's here is Steve's call).

## Steps

1. Create `docs/protocol_compat.md` with these sections, in this order:
   1. **Summary** (3–5 sentences): graph_mem 1.54.x speaks MCP 2024-11-05 … 2025-11-25 over
      Streamable HTTP and stdio. 2026-07-28 clients fall back automatically: their `server/discover`
      probe gets a JSON-RPC error, and the client then runs `initialize` (2025-11-25).
      `MCP_PROTOCOL_NEGOTIATION=legacy` on the client skips the probe. Native 2026-07-28 support comes
      with the migration to the official `mcp` gem (MG-5).
   2. **How 2026-07-28 clients fall back**: condense plan §0b's "Client side" paragraph to a short
      bullet list: any JSON-RPC error to the probe → legacy; `-32022` → retry or legacy; HTTP
      401/403 or ≥ 500 → hard error, **no** fallback; stdio `auto` probes in a sibling process.
      Keep the file:line references out (they point into npm bundles).
   3. **Client matrix**: the `clients.sh` results from `script/mcp_compat/README.md` ("Expected
      results") as a table: client × mode × transport → OK, protocol, timing note.
   4. **Claude Code**: a placeholder table with the rows of `docs/plans/claude-mcp-client-check.md`
      §C and the line "Pending Steve's run (PR-3 step 5)." Steve fills it in.
   5. **Handshake comparison**: the two tables below (stdio, HTTP), as they are. Add one sentence
      before them: "Outlines show `[status, id, result or error code]` (HTTP) or the replies as
      `[id, result or error code]` (stdio); the cases are in `spec/fixtures/mcp/handshakes/`."
   6. **Known divergences**: one bullet per distinct `divergence` text in the two fixture files
      (deduplicate identical texts), each with the case names it covers and `changes_in` when set.
   7. **Re-running**: two lines pointing at `script/mcp_compat/README.md` and
      `spec/requests/mcp_protocol_compat_spec.rb`.
   8. **Next**: one line linking the migration plan, `docs/plans/mcp-update-plan.md` §MG (MG-0).
2. `README.md`: in the section that lists the MCP endpoints (around line 36), add
   "Client and protocol compatibility: [`docs/protocol_compat.md`](docs/protocol_compat.md)."
3. `CHANGELOG.md` › `## [1.54.1]` › `### Added`: "`docs/protocol_compat.md`: supported protocol
   versions, how 2026-07-28 clients fall back, the client matrix and the reference comparison."

## Commands

```bash
source "$HOME/.rvm/scripts/rvm" && rvm use ruby-3.4.1@graph_mem && bundle exec rubocop
```

## Done when

- The doc has the eight sections, the tables match the ones below, and every link resolves.
- `git diff --stat claude/pr-3-mcp-interop-v2-reference` shows only the three files.
- PR opened against `claude/pr-3-mcp-interop-v2-reference`; CI green.

## Tables (compare.rb, 2026-10-24: graph_mem 1.54.1, reference servers 2.0.0 with SDK 2.3.1, Ruby SDK 1.8.1)

### stdio
| Case | graph_mem | Memory/Everything 2.0.0 | Ruby SDK 1.8.1 | Verdict |
|---|---|---|---|---|
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

### Streamable HTTP
| Case | graph_mem | Memory/Everything 2.0.0 | Ruby SDK 1.8.1 | Verdict |
|---|---|---|---|---|
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
