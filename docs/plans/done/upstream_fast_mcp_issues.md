# Upstream reports for fast-mcp

Two findings from wiring MCP access control into GraphMem, both against **fast-mcp 1.6.0**.
Repository: <https://github.com/yjacquin/fast_mcp>.

File as two separate issues — the first is a security bug, the second a capability-advertisement
bug. Text below is ready to paste.

---

## Issue 1 (security): `allowed_ips` is silently ignored unless `localhost_only` is true

**Title:** `allowed_ips` is silently ignored unless `localhost_only` is `true`

### Summary

`RackTransport#valid_client_ip?` gates the `allowed_ips` allowlist behind `localhost_only`:

```ruby
# lib/mcp/transports/rack_transport.rb
def valid_client_ip?(request)
  client_ip = request.ip

  # Check if we're in localhost-only mode
  if @localhost_only && !@allowed_ips.include?(client_ip)
    @logger.warn("Blocked connection from non-localhost IP: #{client_ip}")
    return false
  end

  true
end
```

Because the condition is an `&&`, passing `localhost_only: false` disables the IP check entirely
and `allowed_ips` is never consulted. The natural reading of

```ruby
Rails.application.config.middleware.use(
  FastMcp::Transports::RackTransport, server,
  localhost_only: false,                                    # "allow non-localhost clients"
  allowed_ips: ["127.0.0.1", "::1", "192.168.1.50"]         # "...but only these"
)
```

is "restrict to this list", and that is how the option pair reads in the README. What actually
happens is that **every** IP is accepted, with no warning that the allowlist is inert.

The only remaining protection is `validate_origin`, which falls back to `HTTP_REFERER` and then
`request.host` when `Origin` is absent:

```ruby
origin = env["HTTP_ORIGIN"]
origin = env["HTTP_REFERER"] || request.host if origin.nil? || origin.empty?
```

Non-browser MCP clients send neither `Origin` nor `Referer`, so this falls through to
`request.host`, which is whatever hostname the client dialled — an attacker-chosen value that
matches the allowlist whenever the server is reached on an allowed hostname. In practice an MCP
server configured this way is reachable and fully writable by anything that can route to the port.

### Impact

Any deployment that wants LAN access — the documented way to do it is `localhost_only: false` —
ends up with no IP restriction at all while appearing to have one. For an MCP server this means
unauthenticated tool execution, including mutating tools.

### Reproduction

```ruby
transport = FastMcp::Transports::RackTransport.new(
  app, server,
  localhost_only: false,
  allowed_ips: ["127.0.0.1"]
)

env = Rack::MockRequest.env_for("/mcp", method: "POST", "REMOTE_ADDR" => "203.0.113.7",
                                        "HTTP_HOST" => "localhost")
transport.call(env)
# => request is served; expected 403
```

### Suggested fix

Decouple the two options so the allowlist is always authoritative when non-empty, and treat
`localhost_only: true` as a shorthand that populates it:

```ruby
def valid_client_ip?(request)
  return true if @allowed_ips.empty?     # explicitly unrestricted
  return true if ip_allowed?(request.ip)

  @logger.warn("Blocked connection from disallowed IP: #{request.ip}")
  false
end
```

Two refinements worth considering:

1. **Accept CIDR ranges.** `@allowed_ips.include?(client_ip)` is string equality, so a LAN cannot
   be expressed without enumerating every host. `IPAddr` handles both addresses and ranges, and
   needs an `ipv4_mapped?` → `native` normalisation so `::ffff:127.0.0.1` matches `127.0.0.0/8`.
2. **Warn at startup** when `localhost_only: false` is combined with a non-empty `allowed_ips`
   under the current semantics, so existing deployments discover the inert config.

Also worth documenting that `request.ip` derives from `X-Forwarded-For` and is therefore
client-controlled behind a reverse proxy, so IP allowlisting is advisory there.

### Workaround

We now apply our own policy object at a single chokepoint ahead of the transport and pass
`localhost_only: false` deliberately to keep the inner check out of the way. Happy to open a PR
for the fix above if the approach sounds right.

---

## Issue 2 (capabilities): `tools.listChanged` is advertised but never emitted

**Title:** `tools.listChanged` capability is advertised but no notification is ever sent

### Summary

`DEFAULT_CAPABILITIES` advertises `listChanged` for both resources and tools:

```ruby
# lib/mcp/server.rb
DEFAULT_CAPABILITIES = {
  resources: { subscribe: true, listChanged: true },
  tools: { listChanged: true }
}.freeze
```

Resources honour it — `register_resource` and `remove_resource` both call
`notify_resource_list_changed`. Tools do not:

- `register_tool` only writes to `@tools` and logs.
- There is no `notify_tool_list_changed` method anywhere in the gem.
- There is no `remove_tool` counterpart to `remove_resource`.

So a client that trusts the advertised capability and expects
`notifications/tools/list_changed` will never receive one, and will keep serving a stale tool list
after any runtime registration change.

### Impact

This blocks the "dynamic toolsets" pattern — exposing a small core set and letting an agent enable
a group of extra tools on demand — which is valuable for servers with large catalogs, where the
full `tools/list` payload is a significant fixed context cost. Per-request filtering via
`filter_tools` works, but only for a selection fixed at connection time.

### Suggested fix

Either implement the notification and a `remove_tool`, mirroring the resource path:

```ruby
def register_tool(tool)
  @tools[tool.tool_name] = tool
  @logger.debug("Registered tool: #{tool.tool_name}")
  tool.server = self
  notify_tool_list_changed if @transport
  tool
end
```

or drop `listChanged` from the advertised `tools` capability until it is implemented, so clients
are not misled. Happy to contribute the former.
