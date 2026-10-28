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

Both are applied by `GraphMem::McpAccessPolicy` at a single chokepoint,
`GraphMem::OfficialMcp::AccessGate`: a Rack middleware in front of every `/mcp` path, before the
request reaches the official MCP Ruby SDK's Streamable HTTP transport for that profile. On top of
that, the SDK's DNS-rebinding protection checks the `Host` and `Origin` headers (below).

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
| `GRAPH_MEM_MCP_ALLOWED_HOSTS` | empty (`localhost`, `127.0.0.1` and `::1` are always accepted) | Comma-separated `Host` names (any port) or `host:port` values clients use to reach the server, e.g. `192.168.0.10,graphmem.lan`. **Set it when clients on other machines connect**: any other `Host` gets `403`. |
| `GRAPH_MEM_MCP_ALLOWED_ORIGINS` | empty | Comma-separated exact `scheme://host:port` origins accepted from browser-based clients, beyond same-origin requests. Requests without an `Origin` header (non-browser MCP clients) are not affected. The same list is the only one granted CORS on `/mcp`. |

Default ranges: `127.0.0.0/8`, `::1`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
`fc00::/7`, `fe80::/10`.

An explicit allowlist replaces these defaults rather than extending them. Include
`127.0.0.0/8` and `::1` when clients on the server host use `localhost` (and `172.16.0.0/12` in
Docker, where local clients can arrive from a bridge address). `bin/up` builds such a list for you.

### Adding entries at runtime (Settings › MCP access)

The operator's Settings › MCP access tab adds IPs, hosts and origins **on top of** each ENV value,
which is shown as read-only text beside the editable part and can't be removed there. Changes apply
on the next request, without a restart, and each changed list writes an audit row.

- The same validation as ENV, stricter where the UI can refuse: an unparseable entry is refused
  (ENV only warns), and so are `any`, `all`, `*` and a `/0` such as `0.0.0.0/0` or `::/0` (lifting
  the IP restriction stays an ENV decision, made with a token). An IPv4-mapped entry
  (`::ffff:a.b.c.d`) is saved in plain IPv4 form, the form client addresses are compared in.
- A public IP range is accepted only while `GRAPH_MEM_MCP_TOKEN` is set, and saved with a warning.
  It is re-checked every time the policy is built: if the token is later removed, the entry stops
  applying (logged, and shown as inactive) instead of staying silently active.
- Added IPs extend the effective ENV list (the defaults when unset); they have no effect when ENV
  allows any IP. They apply to bearer `/api/v1` requests too.
- **Saving a change to allowed hosts or origins closes every open MCP session** (the transport is
  rebuilt with the new lists); clients get `404 Session not found` and start a new one. Changing only
  the allowed IPs keeps sessions open.
- The lists aren't secrets: they live in the settings table, so backups and exports include them,
  and restoring a backup applies its lists at once. The token never goes there.
- No lockout: the operator pages and `/operator/login` aren't behind any of these lists, and an
  operator session on `/api/v1` isn't IP-checked.
- graph_mem runs one Puma process; with several workers, a change would reach the others only at
  their next restart.

### DNS-rebinding protection (always on)

The SDK's transport refuses a request whose `Host` isn't a loopback name or listed in
`GRAPH_MEM_MCP_ALLOWED_HOSTS`, and a browser request whose `Origin` is neither same-origin nor listed
in `GRAPH_MEM_MCP_ALLOWED_ORIGINS`, with `403`. graph_mem never turns this protection off: it also
covers the `Origin` check, and the IP allowlist can't stop a rebinding attack (the victim's browser
connects from an allowed address).

The active posture is logged once at boot:

```
[McpAccessPolicy] /mcp access: no token (unauthenticated), 7 allowed range(s)
```

A change from Settings › MCP access logs the new posture, e.g.
`[McpAccessPolicy] /mcp access changed by operator:admin: no token (unauthenticated), 8 allowed range(s) (+1 from settings)`.

## Recipes

### Starting with `bin/up`

`bin/up` runs `docker compose up -d` (extra arguments are passed on, e.g. `bin/up --build`) after
detecting the host's LAN address, subnet and host name, and passes them as the defaults:

```console
$ bin/up --print
GRAPH_MEM_MCP_ALLOWED_HOSTS=synth-box,synth-box.local,10.9.8.18 (detected)
GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,172.16.0.0/12,10.9.8.0/24 (detected)
GRAPH_MEM_MCP_ALLOWED_ORIGINS unset (built-in default: never detected; same-origin pages need no entry)
```

- Loopback and the Docker bridge range are always in the IP list. The subnet is used only for a
  private address with a `/16`–`/30` prefix; otherwise the IP list stays unset (built-in defaults).
- Origins are never detected: a browser client's origin is its own `scheme://host:port`.
- A non-empty value in the environment, or a `KEY=value` line in `.env`, wins and is passed through
  unchanged. Leave the lines unset in `.env` to use the detection.
- Detection runs on the host (Linux: `ip`; macOS, best effort: `route`, `ipconfig`, `ifconfig`). If
  it fails, `bin/up` prints one line and starts with today's defaults.

Plain `docker compose up -d` still works and uses the built-in defaults.

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

Every profile uses the same token and network policy. Profiles reduce accidental tool selection;
they do not grant different permissions to different token holders.

A rejected request is explicit about the fix:

```json
{"jsonrpc":"2.0","error":{"code":-32600,
 "message":"Unauthorized: send `Authorization: Bearer <GRAPH_MEM_MCP_TOKEN>`"},"id":null}
```

returned as `401` with `WWW-Authenticate: Bearer realm="graph_mem"`. A `403` means the client's IP
is outside the allowlist, or the `Host` or `Origin` check failed.

CORS preflight (`OPTIONS`) on `/mcp` is answered by `rack-cors` (`config/initializers/cors.rb`)
before the token check, with CORS headers only for an origin in `GRAPH_MEM_MCP_ALLOWED_ORIGINS`, so a
listed browser-based client can send its `Authorization: Bearer` header (no
`Access-Control-Allow-Credentials` is sent, so no cookies). An unlisted origin's preflight gets `200`
without those headers, and the browser blocks the request. `/api` CORS is configured separately.

## Request limits and protocol checks

Every request passes the access policy first; these checks run after it, before the request reaches
a tool.

| Check | Default | Response |
|---|---|---|
| Body size (`GRAPH_MEM_MCP_MAX_REQUEST_BYTES`) | 4 MiB (`4194304`) | `413`, JSON-RPC `-32600`. An `initialize` request is also capped at 64 KiB. On stdio the same value caps each line, and a longer line ends the session. |
| Open Streamable HTTP sessions (`GRAPH_MEM_MCP_MAX_SESSIONS`) | 256 per profile path | At the cap, a new `initialize` first reaps expired sessions, then gets `503`. |
| A second `GET` stream on one session | — | `409`. Each session has at most one server-to-client SSE stream. |
| Unknown or missing `Mcp-Session-Id` | — | `404` for an unknown session, `400` for a missing one on anything but `initialize`. |

Edge cases (unsupported `MCP-Protocol-Version` values, `"id": null`, a missing `jsonrpc` member,
batches) are answered as the official MCP Ruby SDK answers them; `docs/protocol_compat.md` lists
each case. Sessions idle for 30 minutes are reaped, and a session belongs to the profile path that
created it. Clients should end sessions with `DELETE` rather than leave them to expire.

`initialize` negotiates `2024-11-05`, `2025-03-26`, `2025-06-18` or `2025-11-25`, echoing a
supported request and answering `2025-11-25` to anything else. `2026-07-28` clients are served in
that revision's stateless lifecycle (`server/discover`, per-request `_meta`); a client that sets
`MCP_PROTOCOL_NEGOTIATION=legacy` uses the handshake instead.

## stdio

The stdio runner has no network surface: whoever can start it gets the full graph, with no token or
IP check. Launch it only from a client config you control, as a fixed absolute path to
`bin/mcp_stdio_runner.rb` (or a wrapper script with a fixed path), with no user-supplied
arguments. Select the catalog with `GRAPH_MEM_MCP_PROFILE` in the launcher's environment, not on
the command line.

stdout carries JSON-RPC only. Rails and runner logs go to stderr, which most clients show in
their MCP log view.

## HTTP API (`/api/v1`)

The REST API is not anonymous. Every verb on every `/api/v1/*` endpoint requires one of:

1. **An operator browser session** (sign in at `/operator/login`). Cookie-authenticated writes are
   CSRF-protected: send the page's token in `X-CSRF-Token`, as the graph UI does.
2. **The bearer token** (`GRAPH_MEM_MCP_TOKEN`) from an IP allowed by `GRAPH_MEM_MCP_ALLOWED_IPS`.
   A valid bearer token skips the CSRF check. With no session, any `Bearer` header skips it too, and
   the request then gets `401`/`403`; with a session, an invalid `Authorization` header still needs
   the CSRF token.
   The token is normalised exactly as for `/mcp` (whitespace stripped, `Bearer` case-insensitive).

3. **A read-only guest browser session** (UI-1, only when a guest password is configured), for
   these read endpoints only: `GET /api/v1/graph_data`, `memory_entities` (index, show, search),
   `memory_observations` (index, show), `memory_relations` (index, show), `search/subgraph`,
   `graph/traverse` and `graph/shortest_path`. Every other endpoint answers a guest with `403`
   `{"error":"forbidden","role":"guest"}`. A guest session together with a valid bearer token gets
   full access (the token is the owner's machine credential). Guest searches
   (`/search`, `memory_entities/search`, `search/subgraph`, and `memory_entities/:id` when it gets a
   `query`) share a budget of 60 a minute per IP and 300 a minute across all guests (`429` with
   `Retry-After` after that); requests with a valid bearer token aren't throttled. The 300 a minute
   is one budget shared by every guest, so one busy guest can use it up for all of them until the
   minute passes. The read-only entity panel (`/entities/:id/panel`) and `graph_data` (including
   Search's "Show as graph", `?ids=`) don't count.

`/mcp*` never reads browser sessions: an operator or guest cookie grants no MCP access.

With no token configured the bearer path is disabled and only sessions work. There is no
loopback/private-range exemption. Failures return `401` (no or invalid credentials, with
`WWW-Authenticate: Bearer realm="graph_mem"`) or `403` (valid token from a disallowed IP, or a guest
session on an endpoint outside the guest allowlist).
`/csp-reports` is the one unauthenticated endpoint (rate-limited; it only logs reports).

## Limitations

Know what this does **not** give you.

**No per-agent identity.** One shared token; every agent holding it has identical, full read/write
access. `X-MCP-Client` is self-asserted and is a namespacing key, not a credential — an agent can
claim any client id and read another agent's context.

**Client addresses and `X-Forwarded-For`.** Rack and Rails derive the client address from
`X-Forwarded-For` whenever the connecting peer is a private address, and any client can set that
header. So the IP check (on `/mcp` and bearer `/api/v1`) requires **both** the connecting peer
(`REMOTE_ADDR`) and the derived address to be allowed. Without a reverse proxy, which is how
graph_mem runs, both are the client's own address, and a forged header can only get a request
refused. Behind a reverse proxy (Kamal's included), the proxy's own address must be in the list
(the Docker bridge range `172.16.0.0/12` usually is), and the client address it forwards is checked
as well. Configure the proxy to overwrite `X-Forwarded-For`; an IP list is still no substitute for
the token there.

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
access to the whole graph. Since 1.55.0 `McpAccessPolicy` runs in its own middleware
(`GraphMem::OfficialMcp::AccessGate`) in front of every `/mcp` path.
