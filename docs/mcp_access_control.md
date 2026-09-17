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
| `GRAPH_MEM_MCP_ALLOWED_IPS` | loopback + RFC1918 | Comma-separated addresses or CIDR ranges. `any` (also `all`, `*`) lifts the restriction entirely — **only honoured when a token is set**. |

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
credentials.

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
values are never persisted. See Phase 0 of
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
