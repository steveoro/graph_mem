# MCP Access Control

How GraphMem decides who may reach `/mcp`, and how to configure it for a laptop, a LAN, or a
VPN-reachable host.

## Security model

GraphMem stores **one graph for one implicit owner**, shared by a handful of that owner's agents.
There is deliberately no per-user authorization: the shared graph is the point of the tool, and
row-level tenancy would partially destroy it while adding silent-leak risk across search,
traversal, summarization, and dream-state compaction.

So there are exactly two controls:

1. **Network reach** — which client IPs may connect (`GRAPH_MEM_MCP_ALLOWED_IPS`).
2. **A shared bearer token** — one secret, shared by the owner's agents (`GRAPH_MEM_MCP_TOKEN`).

Both are applied by `GraphMem::McpAccessPolicy` at a single chokepoint in
`GraphMem::McpStreamableHttpTransport#handle_mcp_request`, which covers the Streamable HTTP
endpoint **and** the legacy `/mcp/sse` and `/mcp/messages` endpoints.

> If you need two people to have separate memories, run two instances against two databases.
> That is an afternoon of work, gives perfect isolation, and cannot leak. See the reasoning in
> [`mcp_toolset_consolidation.md`](mcp_toolset_consolidation.md).

### The invariant

**An instance can never be both unauthenticated and reachable from a public address.**

With no token configured, the allowlist may only ever *narrow* the loopback and private ranges,
never widen them. An entry such as `0.0.0.0/0` or a public address is dropped with a warning and
the defaults are restored. This holds regardless of what the configuration asks for, so a
copy-pasted config cannot accidentally expose an open graph.

## Configuration

Both variables are optional. The defaults are safe for a laptop or a home/office LAN.

| Variable | Default | Meaning |
|---|---|---|
| `GRAPH_MEM_MCP_TOKEN` | unset | Shared secret. When set, every request must send `Authorization: Bearer <token>`. When unset, no token is required. |
| `GRAPH_MEM_MCP_ALLOWED_IPS` | loopback + private (RFC1918, IPv6 ULA and link-local) | Comma-separated addresses or CIDR ranges. `any` (also `all`, `*`) lifts the restriction entirely — **only honoured when a token is set**. |

Default ranges: `127.0.0.0/8`, `::1`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
`fc00::/7`, `fe80::/10`.

An explicit allowlist replaces these defaults rather than extending them. Include
`127.0.0.0/8` and `::1` when clients on the server host use `localhost`.

The active posture is logged once at boot:

```
[McpAccessPolicy] /mcp access: no token (unauthenticated), 7 allowed range(s)
```

## Recipes

### Laptop only

Nothing to configure. Loopback is allowed; everything else is refused.

To be explicit and exclude the LAN:

```bash
GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1
```

### One host serving a few agents on a trusted LAN

This is the default posture and needs no configuration — any RFC1918 client may connect
unauthenticated. Suitable only when you trust every device on the network.

To add a token anyway (recommended once more than one person is on the LAN):

```bash
GRAPH_MEM_MCP_TOKEN=$(openssl rand -hex 32)
```

To restrict to one subnet:

```bash
GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,192.168.0.0/24
```

### Reachable over VPN, or on a VM

A token is **required** here, because VPN and cloud clients fall outside the private ranges (and
because `request.ip` stops being trustworthy — see [Limitations](#limitations)):

```bash
GRAPH_MEM_MCP_TOKEN=$(openssl rand -hex 32)
GRAPH_MEM_MCP_ALLOWED_IPS=any
```

Prefer narrowing where you can, for example to a VPN subnet:

```bash
GRAPH_MEM_MCP_TOKEN=$(openssl rand -hex 32)
GRAPH_MEM_MCP_ALLOWED_IPS=100.64.0.0/10
```

## Client configuration

For an HTTP MCP server, add the token as a request header. Cursor, Windsurf and Claude Desktop all
support custom headers on a URL-based server:

```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://192.168.0.18:3030/mcp",
      "headers": {
        "Authorization": "Bearer <GRAPH_MEM_MCP_TOKEN>",
        "X-MCP-Client": "cursor-wks-1"
      }
    }
  }
}
```

Keep setting `X-MCP-Client`: it is what isolates each agent's project context (`agent_contexts`),
and it is unrelated to authentication.

Choose the URL for the required tool profile:

- `/mcp` — default context, read, and graph-write tools
- `/mcp/readonly` — context and read tools only
- `/mcp/maintenance` — the full catalog, including maintenance tools
- `/mcp/sse` — legacy transport using the default profile

Every profile uses the same token and network policy. Profiles reduce accidental tool selection;
they do not grant different permissions to different token holders.

A rejected request is explicit about the fix:

```json
{"jsonrpc":"2.0","error":{"code":-32600,
 "message":"Unauthorized: send `Authorization: Bearer <GRAPH_MEM_MCP_TOKEN>`"},"id":null}
```

returned as `401` with `WWW-Authenticate: Bearer realm="graph_mem"`. A `403` means the client's IP
is outside the allowlist, or the `Origin` check failed.

CORS preflight (`OPTIONS`) is answered before the token check, so browser-based clients can send
credentials. `Access-Control-Allow-Origin` reflects the request's `Origin` only when it is allowed
(with `Vary: Origin`), never `*`.

## Request limits and protocol checks

Every request passes the access policy first; these checks run after it, before the request reaches
a tool.

| Check | Default | Response |
|---|---|---|
| Body size (`GRAPH_MEM_MCP_MAX_REQUEST_BYTES`) | 4 MiB (`4194304`) | `413`, JSON-RPC `-32600`. Also applies to the legacy `/mcp/messages`, and to each stdio line (a `-32600` reply; the runner keeps serving). |
| Open Streamable HTTP sessions (`GRAPH_MEM_MCP_MAX_SESSIONS`) | 256 | At the cap, a new `initialize` first reaps expired sessions, then closes the least recently active idle one (no request in flight, no open stream). `503` "Too many sessions" only when every session is busy. |
| A second `GET` stream on one session | — | `409`. Each session has at most one server-to-client SSE stream. |
| `MCP-Protocol-Version` on in-session requests | — | `400` for a version the server doesn't support. Any supported version is accepted, even one other than the negotiated one; a missing header is accepted (pre-2025-06-18 clients). |
| Body shape | — | `400` for a body that isn't a JSON-RPC 2.0 object (arrays included), `"id": null`, or an id that isn't a string or integer; `-32700` for invalid JSON. |
| Unknown `Mcp-Session-Id` | — | `404`, checked before the protocol-version header. |

Error responses carry the request's JSON-RPC `id` whenever it could be read. Sessions idle for 30
minutes are reaped. A client that opens a session per call without sending `DELETE` doesn't lock
others out at the cap: its idle sessions are the first to be evicted. An evicted session gets `404`
on its next request, and the client starts a new one.

`initialize` negotiates `2024-11-05`, `2025-03-26`, `2025-06-18` or `2025-11-25`, echoing a
supported request and answering `2025-11-25` to anything else. `2026-07-28` clients fall back to
the handshake through a failed `server/discover` probe; a client that sets
`MCP_PROTOCOL_NEGOTIATION=legacy` skips the probe.

## stdio

The stdio runner has no network surface: whoever can start it gets the full graph, with no token or
IP check. Launch it only from a client config you control, as a fixed absolute path to
`bin/mcp_stdio_runner.rb` (or a wrapper script with a fixed path), with no user-supplied
arguments. Select the catalog with `GRAPH_MEM_MCP_PROFILE` in the launcher's environment, not on
the command line.

stdout carries JSON-RPC only. Rails, FastMcp and runner logs go to stderr, which most clients
show in their MCP log view.

## HTTP API (`/api/v1`)

The REST API is not anonymous. Every verb on every `/api/v1/*` endpoint requires one of:

1. **An operator browser session** (sign in at `/operator/login`). Cookie-authenticated writes are
   CSRF-protected: send the page's token in `X-CSRF-Token`, as the graph UI does.
2. **The bearer token** (`GRAPH_MEM_MCP_TOKEN`) from an IP allowed by `GRAPH_MEM_MCP_ALLOWED_IPS`.
   A valid bearer token skips the CSRF check. With no session, any `Bearer` header skips it too, and
   the request then gets `401`/`403`; with a session, an invalid `Authorization` header still needs
   the CSRF token.
   The token is normalised exactly as for `/mcp` (whitespace stripped, `Bearer` case-insensitive).

With no token configured the bearer path is disabled and only sessions work. There is no
loopback/private-range exemption. Failures return `401` (no or invalid credentials, with
`WWW-Authenticate: Bearer realm="graph_mem"`) or `403` (valid token from a disallowed IP).
`/csp-reports` is the one unauthenticated endpoint (rate-limited; it only logs reports).

## Limitations

Know what this does **not** give you.

**No per-agent identity.** One shared token; every agent holding it has identical, full read/write
access. `X-MCP-Client` is self-asserted and is a namespacing key, not a credential — an agent can
claim any client id and read another agent's context.

**`request.ip` is spoofable behind a proxy.** Rack derives it from `X-Forwarded-For`, which a
client can set. Once GraphMem sits behind a reverse proxy (Kamal's included), the IP allowlist is
advisory and the token is the real control. Configure the proxy to overwrite `X-Forwarded-For`, or
rely on the token.

**No transport encryption by itself.** The token crosses the network in a header. On a LAN that is
usually acceptable; over a VPN the tunnel protects it; on a public VM put TLS in front.

**No rate limiting or per-user audit.** `ToolTelemetry` records queryable per-call operational
metrics, but `X-MCP-Client` remains self-asserted and is not an authenticated identity. Argument
values are never persisted. Calls rejected by access control before tool dispatch are not included
in these metrics. Signed-in operators can inspect execution telemetry at `/operator/telemetry`;
see [`operator/telemetry.md`](operator/telemetry.md) and Phase 0 of
[`mcp_toolset_consolidation.md`](mcp_toolset_consolidation.md).

## Note on a fixed misconfiguration

Before this policy existed, the transport's IP check read:

```ruby
if @localhost_only && !@allowed_ips.include?(client_ip)
```

and the initializer passed `localhost_only: false` alongside a three-entry `allowed_ips` list.
Because the condition is an `&&`, **the allowlist was never consulted** — the same inert pattern
applied to the inner `FastMcp::Transports::RackTransport`. The only effective guard was `Origin`
validation, which falls back to `request.host` when `Origin` and `Referer` are absent, as they are
for every non-browser MCP client.

The practical effect was that any host able to reach the port had unauthenticated read and write
access to the whole graph. `localhost_only: false` is still passed to the inner legacy transport
on purpose, to keep its string-equality-only check out of the way; `McpAccessPolicy` now governs
both endpoints.
