# Migrating a Rails app from fast-mcp to the official `mcp` gem

**Draft v0.1** (2026-10-25). Written against fast-mcp 1.8.0 and the official MCP Ruby SDK (`mcp` gem) **1.8.1**.
It is finalised (v1.0) once a full migration has been done with it. Every claim about the gem says
"verify against your pinned version": the gem moves quickly, and this guide is a starting point, not a spec.

The guide is for any Rails app serving MCP with fast-mcp that wants to move to the official SDK
without a big-bang rewrite. Boxes marked **Example (graph_mem)** show how one open-source app
([graph_mem](https://github.com/steveoro/graph_mem)) does it; the names in them are that app's, the
data is synthetic.

The route in one paragraph: keep your tool classes as they are, generate gem tool classes from them
through a thin adapter, serve both engines side by side behind an ENV switch, prove each phase with
wire-level interop tests, then remove fast-mcp.

---

## 1. Inventory

Fill in this table before writing any code and keep it current in the migration PRs.

| Item | How to find it | Count / notes |
|---|---|---|
| Tool classes | `rg -l "< (FastMcp::Tool\|ApplicationTool)" app` | |
| … with `arguments do` | `rg -l "arguments do" app/tools` | |
| … with a hand-written JSON Schema | `rg -n "def (self\.)?input_schema_to_json" app/tools` (only the **class** method reaches `tools/list`) | |
| Tools callable but not advertised (aliases) | your registry / any `tools/list` patch | |
| Resources and resource templates | `rg -l "< (FastMcp::Resource\|ApplicationResource)" app` | |
| Prompts and their arguments | `rg -l "< (FastMcp::Prompt\|ApplicationPrompt)" app` | |
| Patches / monkey-patches on fast-mcp | `rg -n "FastMcp::Server\.(prepend\|class_eval)\|module FastMcp" lib config` | |
| Transports in use | legacy HTTP+SSE (`/sse`, `/messages`), stdio, any custom Streamable HTTP | |
| Auth | bearer token, IP allowlist, OAuth | |
| Endpoints / profiles that filter tools | `filter_tools`, `filter_prompts`, several mount paths | |
| Per-request context headers | e.g. a client-id header read by tools | |
| Telemetry hooks | where a tool call is recorded | |
| Error classes tools raise, and how they reach the client | `rg -n "raise .*Error" app/tools` | |
| Where logs go | stdout is a hazard on stdio | |
| Capabilities advertised vs notifications actually sent | `initialize` result vs `rg -n "notify_"` | |
| `instructions` | | |
| fast-mcp pin and source | `Gemfile.lock` | |
| Files referencing `FastMcp` | `rg -l FastMcp --type ruby app lib config bin` and `… spec` | code: / specs: |

> **Example (graph_mem, at 64e16bb):** 40 tool classes (34 with `arguments do`, 4 with a hand-written
> schema, 18 hidden aliases), 4 resource templates, 3 prompts, three HTTP profiles (`/mcp`,
> `/mcp/readonly`, `/mcp/maintenance`) plus stdio and legacy `/mcp/sse`, a static bearer token and an IP
> allowlist, an `X-MCP-Client` context header, per-call telemetry, a JSON error envelope for tool
> errors, and `FastMcp` in 46 code files and 35 spec files.

**Checklist:** ☐ table filled ☐ hidden/alias tools listed ☐ every transport and endpoint listed
☐ capabilities you advertise but never send noted (fix them first: §7).

## 2. The adapter pattern

Don't rewrite the tools. Add one engine-neutral boundary and leave tool bodies untouched until the
old engine is gone.

- **Tool wrapper.** For each existing tool class, generate an `MCP::Tool` subclass at boot: same
  name, description, input/output schema and annotations; its `call(server_context:, **args)`
  instantiates the existing tool and runs it the way fast-mcp did (argument normalisation,
  validation, telemetry, result formatting). The gem accepts any object that responds to `#to_h` as
  a `tools/call` result, so the wrapper can return exactly the hash fast-mcp sent.
- **Schema bridge.** During the migration, reuse fast-mcp's JSON Schema output
  (`input_schema_to_json`, `output_schema_to_json`). Afterwards, see §3 (schemas).
- **Error mapping.** Rescue every exception in the wrapper and return an `isError` result in the
  shape your clients already know. Left alone, the gem turns an uncaught exception into a JSON-RPC
  `-32603` error.
- **Server factory.** Build one `MCP::Server` per endpoint/profile from the same registry.
- **Context and telemetry bridges.** Per-request data (client id, profile, session) reaches the
  wrapper through `server_context` (§4). Telemetry stays where it is (inside the existing tool call),
  so it is recorded once per call on either engine.
- **Engine switch.** An ENV variable read once at boot (`fast_mcp` | `official`), defaulting to the
  old engine; the new engine is refused in production until the transport phase (§5).

> **Example (graph_mem):** the wrapper is about 70 lines and wraps all 40 tool classes unchanged; the
> only tool-side change is that the base class reads the current profile from a thread-local the
> wrapper sets. A pilot spec sent the same `tools/list` and `tools/call` requests to both engines:
> identical results (including `structuredContent`, `_meta` and the error envelope) apart from the
> differences listed in §3.

**Checklist:** ☐ wrapper generates gem classes from existing ones ☐ errors become `isError` results
☐ one server per profile ☐ engine switch refuses the new engine in production.

## 3. Mapping fast-mcp to the gem

Verify every row against your pinned gem's source.

| fast-mcp | `mcp` gem (1.8.1) | Notes |
|---|---|---|
| `tool_name`, `description` | `tool_name`, `description` class methods | Names: 1–128 chars of `[A-Za-z0-9_.-]`. |
| `arguments do … end` (dry-schema) | `input_schema` (JSON Schema hash or `InputSchema`) | Feed it fast-mcp's `input_schema_to_json`. The gem validates the schema against JSON Schema 2020-12 at class load: a schema that fast-mcp accepted can fail here. |
| `tools/list` `inputSchema` | adds `"$schema": "https://json-schema.org/draft/2020-12/schema"` | A wire difference: compare schemas without that key, and record it. |
| `annotations(read_only_hint: …)` | `annotations(read_only_hint: …)` | Same keys; the gem emits camelCase and fills unset hints with its defaults. |
| `output_schema` | `output_schema` | Also validated at load. |
| `call(**args)` returning a String/Hash | `self.call(**args, server_context:)` returning an object with `#to_h` | Arguments arrive with symbol keys at every nesting level. |
| `InvalidArgumentsError` → `isError` result | missing `required` keys → `isError` text "Missing required arguments: …" **before** your code runs; schema violations likewise when `validate_tool_call_arguments` is on | If your tools accept aliases for required keys (camelCase, names for ids), give the wrapper an `InputSchema` subclass whose `missing_required_arguments` returns `[]`, and set `validate_tool_call_arguments: false`, so your own validation decides and produces your error shape. |
| uncaught exception → error result | uncaught exception → JSON-RPC `-32603` "Internal error calling tool X" | Rescue in the wrapper (§2). |
| unknown tool → `-32602` "Tool not found: x" | `-32602` "Invalid params", `data: "Tool not found: x"` | Same code, different message. |
| callable-but-hidden tools (filtered in a `tools/list` patch) | no hook: `tools/list` lists every registered tool | Remove the aliases, or keep them registered and override listing in an in-repo `MCP::Server` subclass (internal API: pin it with a spec). |
| `filter_tools` / `filter_prompts` per request | one `MCP::Server` per profile | A session then belongs to one endpoint (§4). |
| `FastMcp::Resource` (static/templated) | `MCP::Resource`, `MCP::ResourceTemplate` + `resources_read_handler` | Not covered by the pilot; map in the resources phase. |
| `FastMcp::Prompt` | `MCP::Prompt` (`template(args, server_context:)`) | Per-profile prompt lists follow from one server per profile. |
| `instructions` | `instructions:` | Per server, so per profile. |
| capabilities | `capabilities:` | The gem's default advertises `listChanged: true` and `logging`; pass your own hash if you don't send those notifications. |

**Schemas after the old engine is gone.** Three choices:
1. Plain JSON Schema hashes per tool, validated by the gem (simplest; works only if your tools take
   exactly the advertised argument names).
2. A small in-repo converter from your existing DSL to JSON Schema (fast-mcp is MIT-licensed, so its
   converter can be vendored with attribution).
3. Freeze each tool's generated schema into a committed hash and keep your own runtime validation.

> **Example (graph_mem):** tools accept compatibility aliases (`entityType`, entity names for ids) and
> normalise them before validating, so the gem's own argument checks are off and the wrapper uses the
> lenient `InputSchema`. All 40 tool classes' schemas, including the 4 hand-written ones, pass the
> gem's 2020-12 validation.

**Checklist:** ☐ schemas load on the gem ☐ `$schema` difference recorded ☐ missing-argument behaviour
pinned by a spec ☐ alias/hidden tools decided ☐ capabilities passed explicitly.

## 4. Transports and auth

**Both gems loaded at once.** fast-mcp ships `lib/mcp/{tool,server,prompt,resource,version}.rb`, the same
relative paths as the `mcp` gem. The gem defines `MCP::Tool`, `MCP::Server`, … through load-path
autoloads (`autoload :Tool, "mcp/tool"`), which Ruby resolves to fast-mcp's already loaded files, so
`MCP::Tool` is never defined. Until fast-mcp is removed, require those five files from the gem's own
directory right after `require "mcp"`:

```ruby
require "mcp"
lib = File.join(Gem.loaded_specs.fetch("mcp").full_gem_path, "lib")
%w[version tool prompt resource server].each { |f| require File.join(lib, "mcp", f) }
```

Re-check the list of shared paths on every gem upgrade.

**Streamable HTTP.** Two shapes:
- **Mount the gem's `StreamableHTTPTransport`** (one per profile) behind your Rack middleware. You get
  the gem's session handling, body cap (`max_request_bytes`, plus a 64 KiB `initialize` cap), session
  cap (`max_sessions`), Origin/Host checks and, later, the 2026-07-28 lifecycle. Its answers to edge
  cases (status codes, error codes, whether the error carries the request `id`) differ from fast-mcp's
  in places: list them with your interop suite (§6) and decide each one.
- **Keep your own transport** and hand parsed messages to `MCP::Server#handle(hash, session:, auth_info:)`.
  You keep your exact wire behaviour but take on the newer protocol revisions yourself.

Things to configure on the gem's transport:
- `enable_json_response: true` if your clients got JSON (not SSE) answers to POSTs before.
- `allowed_hosts:` — DNS-rebinding protection accepts only loopback `Host` headers by default. An app
  reached on a LAN address must list its hosts, or turn the check off when an IP allowlist in front
  already covers it.
- `max_sessions:` and `session_idle_timeout:` to match your old limits.

**Per-request context.** Handlers don't see request headers. The only per-request value the transport
forwards (to `server_context[:auth_info]`, also when the tool runs on the SSE body's thread) is
`env["mcp.auth_info"]`. The transport treats it as an `MCP::Server::OAuth::AccessToken`: it reads
`issuer`, `subject` and `client_id` to bind a session to its caller. To carry your own context, put
an `AccessToken` there in Rack middleware with your context in `claims`. Leave `client_id` and
`subject` nil unless you *want* sessions bound to that identity.

**Auth.** Keep static bearer tokens and IP allowlists as Rack middleware in front of the transport.
Use the gem's `token_verifier:` only if you adopt OAuth.

**stdio.** The gem's `StdioTransport` reads `$stdin` and writes `$stdout`. If your runner points
`$stdout` at stderr to keep stray `puts` off the protocol stream (recommended), subclass the transport
and override the public `send_response` to write to the saved pipe. Note that a line over
`max_line_bytes` ends the session (fast-mcp answered `-32600` and kept serving). Boot must have no side
effects: some clients start the server twice to probe it.

**Legacy HTTP+SSE** (2024-11-05) has no gem transport. Keep it on fast-mcp until fast-mcp goes, then
remove it, or drop it earlier.

> **Example (graph_mem):** a pilot over the gem's transport, with the client id carried in an
> `AccessToken`'s claims, recorded the right client in telemetry in both JSON and SSE response modes.
> Mounting the gem's transport per profile means a session started on `/mcp` is unknown on
> `/mcp/maintenance` (fast-mcp shared sessions across paths).

**Checklist:** ☐ load shim in place ☐ transport shape chosen ☐ `allowed_hosts` set ☐ JSON vs SSE answers
chosen ☐ context carried via `auth_info` ☐ auth middleware in front ☐ stdio writes only JSON-RPC.

## 5. Engine-switch rollout

One release per phase. Rollback is flipping the ENV variable (until the last phase) or reverting.

1. Adapter + 2–3 pilot tools; new engine in dev/test only.
2. All tools, with parity specs (same `tools/list` entry and `tools/call` result on both engines).
3. Resources and prompts.
4. Transports and auth; the default flips to the new engine; the old one stays selectable for one
   release.
5. New protocol features through the gem.
6. Remove the old engine.

Because the tool wrapper is generic, phase 2 is mostly parity specs, not tool code.

**Checklist:** ☐ each phase is one release ☐ rollback tested by flipping the ENV ☐ production refuses
the new engine before phase 4.

## 6. Acceptance gate: wire-level interop tests

Record an engine-agnostic suite **before phase 1** and run it against both engines from then on. It
replays synthetic JSON-RPC sessions over stdio and HTTP and checks status codes, headers and bodies,
never library classes:
- `initialize` for each protocol version you support, and an unknown one;
- `tools/list`; `tools/call` on success and on error;
- resources and prompts;
- malformed and non-object bodies, batches, null and missing ids;
- an oversized body; an unknown session; a protocol-header mismatch.

Compare normalised answers against a reference server (the official reference servers are fine) and
between the two engines. Official clients (TS SDK, Ruby SDK) must connect in both their auto and legacy
negotiation modes. A phase merges only when both engines are green, or a row is listed as "not ported
yet". Every difference is either fixed in the adapter or recorded with the owner's OK.

> **Example (graph_mem):** `spec/fixtures/mcp/handshakes/` (16 stdio, 27 HTTP cases),
> `spec/requests/mcp_protocol_compat_spec.rb` in the normal suite, and `script/mcp_compat/compare.rb`
> against running servers, with a column for a plain `mcp` 1.8.1 server. That column is a preview of
> the edge cases the gem answers differently (see graph_mem's `docs/protocol_compat.md`).

**Checklist:** ☐ suite recorded before phase 1 ☐ both engines in CI ☐ client matrix green ☐ each
difference fixed or signed off.

## 7. Pitfalls

- **stdout on stdio.** Any `puts` or logger on stdout corrupts the stream.
- **Two gems, one `lib/mcp/`.** See §4: `MCP::Tool` silently stays undefined.
- **Schema drift.** Nullable vs optional, `minLength`/`maxLength`, `required`, `additionalProperties`,
  and the gem's 2020-12 validation of your schemas at load time.
- **Error shapes.** `isError` results vs JSON-RPC errors; whether the `id` member is present on errors.
- **Required-argument checks before your code runs** (§3).
- **Capabilities advertised but never delivered.** The gem's defaults advertise `listChanged` and
  `logging`.
- **Hidden tools.** The gem lists every registered tool.
- **Sessions.** Stateful vs stateless, idle timeout, session cap; one transport per endpoint means
  sessions don't cross endpoints.
- **Host checks.** DNS-rebinding protection rejects non-loopback hosts by default.
- **Per-profile prompts.** Easy with one server per profile.
- **Probing clients** start a stdio server twice: no side effects at boot.
- **Autoloading generated classes.** Build wrapper classes at boot from loaded tool classes; eager-load
  in CI.
- **Telemetry counted twice** if both engines record the same call.
- **Shared server objects across threads.** Keep per-request data out of the server object.
- **Legacy SSE clients** have nowhere to go on the gem.
- **The gem pin.** Edge-case answers change between releases; pin an exact version and upgrade
  deliberately.
- **CHANGELOG history** stays untouched when you remove the old engine.

## 8. Measured effort (example, graph_mem)

The pilot (three tools: a no-argument one, a search, a batch write with a hand-written schema) took one
adapter of about 160 lines and a parity spec of about 90. Every other tool class then wrapped with no
further code. The real work is elsewhere: the transport phase (session, host and edge-case decisions,
stdio) and the parity specs per tool. Effort figures per phase are added here as the phases land.
