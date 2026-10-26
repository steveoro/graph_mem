# Migrating a Rails app from fast-mcp to the official `mcp` gem

For a Rails app that serves MCP with [fast-mcp](https://github.com/yjacquin/fast-mcp) and wants to
move to the official MCP Ruby SDK ([`mcp` gem](https://github.com/modelcontextprotocol/ruby-sdk)).
It was written from a finished migration: fast-mcp 1.8.0 to `mcp` **1.8.1**. The gem moves quickly,
so check every row marked "1.8.1" against the version you pin.

Boxes marked **Example (graph_mem)** show how [graph_mem](https://github.com/steveoro/graph_mem)
did it (releases 1.55.0 and 1.55.1). The names in them are graph_mem's, and the data is synthetic.

**The route.** Two releases, with no engine switch and no period where both engines serve traffic:

1. **Swap the engine.** Every MCP request is served by the gem. Your tool, prompt and resource
   classes stay as they are, still on fast-mcp's base classes, and a thin adapter generates gem
   classes from them. Take the gem's defaults wherever the two differ, unless that's a security
   problem. Breaking removals (hidden alias tools, the legacy HTTP+SSE endpoint) belong here too.
2. **Delete fast-mcp.** Give the base classes their own schema DSL (vendored, or replaced), and
   delete fast-mcp, its patches and your old transport code. Nothing changes on the wire.

Rollback is a revert, or redeploying the previous release. The adapter needs no per-tool code, so
there is no tool-by-tool parity phase.

---

## 1. Inventory

Fill this in before writing code, and keep it in the first PR's description.

| Item | How to find it | Count / notes |
|---|---|---|
| Tool classes | `rg -l "< (FastMcp::Tool\|ApplicationTool)" app` | |
| … with `arguments do` | `rg -l "arguments do" app/tools` | |
| … with a hand-written JSON Schema | `rg -n "def (self\.)?input_schema_to_json" app/tools` (only the **class** method reaches `tools/list`) | |
| Tools callable but not advertised (aliases) | your registry, or any `tools/list` patch | |
| Resources and resource templates | `rg -l "< (FastMcp::Resource\|ApplicationResource)" app` | |
| Prompts and their arguments | `rg -l "< (FastMcp::Prompt\|ApplicationPrompt)" app` | |
| Patches on fast-mcp | `rg -n "FastMcp::Server\.(prepend\|class_eval)\|module FastMcp" lib config` | |
| Transports in use | legacy HTTP+SSE (`/sse`, `/messages`), stdio, a custom Streamable HTTP transport | |
| Endpoints or profiles that filter tools | `filter_tools`, `filter_prompts`, several mount paths | |
| Auth | bearer token, IP allowlist, OAuth | |
| Per-request context | headers a tool reads (a client id, the endpoint) | |
| Telemetry | where a tool call is recorded | |
| Errors tools raise, and how they reach the client | `rg -n "raise .*Error" app/tools` | |
| Where logs go | stdout is a hazard on stdio | |
| Capabilities advertised vs notifications actually sent | the `initialize` result vs `rg -n "notify_"` | |
| `instructions` | | |
| fast-mcp pin and source | `Gemfile.lock` | |
| Files referencing fast-mcp | `rg -l "FastMcp\|fast_mcp\|fast-mcp" app lib config bin` and `spec` | code: / specs: |

> **Example (graph_mem, at 1.54.3):** 40 tool classes (22 advertised, 18 hidden aliases), 4 resource
> templates, 3 prompts; three HTTP profiles (`/mcp`, `/mcp/readonly`, `/mcp/maintenance`), stdio and
> the legacy `/mcp/sse`; a custom Streamable HTTP transport (about 1,000 lines) and a patch on the
> fork's server; a static bearer token and an IP allowlist; an `X-MCP-Client` context header;
> per-call telemetry; a JSON error envelope for tool errors.

**Checklist:**
- [ ] table filled in
- [ ] hidden or alias tools listed, and their fate decided (§2)
- [ ] every transport and endpoint listed
- [ ] capabilities you advertise but never send noted (you'll pass explicit ones, §3)

## 2. Decisions

Copy this table into the plan and fill in the last column. Each row is a place where fast-mcp (or
your own code around it) and the gem behave differently. The default answer is "take the gem's
behaviour"; keep your own only where it matters to a client or to security.

| # | Topic | fast-mcp 1.8.0 / your app | `mcp` 1.8.1 | Your decision |
|---|---|---|---|---|
| D1 | Session cap reached | whatever your transport did | reaps expired sessions, then answers **503** to a new `initialize` | |
| D2 | Session cap value | yours | `max_sessions:` (default 10 000) | |
| D3 | Idle sessions | yours | `session_idle_timeout:` (default 1800 s) | |
| D4 | Allowed browser origins | fast-mcp's allowlist (patterns) | `allowed_origins:`, exact `scheme://host:port`; same-origin and `Origin`-less requests pass | |
| D5 | CORS headers | `rack-cors`, or the transport's own | none | |
| D6 | DNS-rebinding protection | an `Origin` check in the transport | `Host` **and** `Origin` checks, on by default; `allowed_hosts:` | **Keep it on.** List your LAN names in `allowed_hosts:` |
| D7 | Body cap | yours | `max_request_bytes:` (+ a 64 KiB cap on `initialize`); stdio `max_line_bytes:` (a longer line ends the session) | |
| D8 | Errors | tool errors → your error result; others logged | `exception_reporter` in two places: the server's `Configuration` (handler failures, the `-32603` path) and the global `MCP.configure` (every transport failure: stdio frames, HTTP requests, the session reaper) | set both |
| D9 | Argument validation | dry-schema in `call_with_schema_validation!` | `validate_tool_call_arguments` (an `MCP::Configuration` option) and a `required` check before the tool runs | |
| D10 | Wire edge cases | fast-mcp's or your transport's answers | the gem's answers | |
| D11 | Hidden alias tools | callable but filtered out of `tools/list` | `tools/list` lists every registered tool | |
| D12 | Legacy HTTP+SSE (2024-11-05) | `/sse` + `/messages` | no transport | |
| D13 | MCP 2026-07-28 (`server/discover`, per-request lifecycle) | not supported | served next to `initialize` | |
| D14 | Gem pin | | | `gem "mcp", "<exact>"`, one PR per upgrade |

> **Example (graph_mem):** D1 accept the 503; D2 keep `GRAPH_MEM_MCP_MAX_SESSIONS` (256) and pass it to each profile's
> transport (so the cap is per endpoint: three profiles allow up to 3 × 256 sessions);
> D3 gem default (same 30 minutes); D4 a new `GRAPH_MEM_MCP_ALLOWED_ORIGINS`, empty by default; D5
> `rack-cors` left as it was; D6 kept on, with a new `GRAPH_MEM_MCP_ALLOWED_HOSTS`; D7 keep the 4 MiB
> setting for HTTP and stdio, accept the 64 KiB `initialize` cap; D8 the wrapper keeps the error
> envelope, and both `exception_reporter`s call `Rails.error.report`; D9 one shared configuration with
> `validate_tool_call_arguments: false` and a lenient input schema (§3); D10 accept all 16 changed
> cases; D11 remove the 18 aliases (breaking); D12 remove `/mcp/sse` (breaking); D13 comes free with
> the swap; D14 `gem "mcp", "1.8.1"`.

## 3. The pattern

Four small pieces, none of them per tool:

1. a **tool wrapper** that generates an `MCP::Tool` subclass from each of your tool classes (and the
   same for prompts and resource templates);
2. a **server factory** that builds one `MCP::Server` per endpoint or profile;
3. **Rack middleware** for auth and per-request context, then the gem's Streamable HTTP transport;
4. a **stdio runner** on the gem's stdio transport.

### Tool wrapper

Generate the gem class at boot from the loaded tool class, with the same name, description,
schemas and annotations. Its `call` runs your tool exactly as fast-mcp did, and returns the same
result hash: the gem accepts any object that responds to `#to_h` as a `tools/call` result.

```ruby
module ToolWrapper
  # Your tools validate (and accept aliases for required keys) themselves: skip the gem's check.
  class LenientInputSchema < MCP::Tool::InputSchema
    def missing_required_arguments(_arguments) = []
  end

  Result = Data.define(:payload) { def to_h = payload }

  def self.build(tool_class)
    Class.new(MCP::Tool) do
      tool_name tool_class.tool_name
      description tool_class.description
      input_schema LenientInputSchema.new(tool_class.input_schema_to_json)
      define_singleton_method(:call) do |server_context: nil, **args|
        # fast-mcp's call_with_schema_validation! returns [result, _meta]
        result, meta = tool_class.new.call_with_schema_validation!(**args)
        Result.new({ content: [ { type: "text", text: JSON.generate(result) } ], _meta: meta, isError: false })
      rescue StandardError => e
        Result.new({ content: [ { type: "text", text: e.message } ], isError: true })
      end
    end
  end
end
```

Add `output_schema` and `annotations` the same way when your tools have them, and turn errors into
whatever shape your clients already parse. Without the `rescue`, the gem answers an exception with
a JSON-RPC `-32603` error instead of an `isError` result.

> **Example (graph_mem):** `lib/graph_mem/official_mcp/tool_wrapper.rb` (88 lines) wraps all 22 tool
> classes with no per-tool code. It keeps graph_mem's result shape (text, `structuredContent` when
> the tool has an output schema, `_meta` with `version` and `next_move`) and the `ToolError` JSON
> envelope with its `code`. `PromptWrapper` (31 lines) and `ResourceCatalog` (31 lines, the resource
> templates plus a `resources_read_handler` that maps a URI to its resource class) do the same for
> prompts and resources.

### One server per profile

fast-mcp filters tools and prompts per request (`filter_tools`, `filter_prompts`). The gem has no
such hook: build one server per endpoint instead, from the same registry, and share one
configuration.

```ruby
CONFIG = MCP::Configuration.new(validate_tool_call_arguments: false,
                                exception_reporter: ->(e, ctx) { Rails.error.report(e, handled: true, context: ctx.to_h) })
MCP.configure { |config| config.exception_reporter = CONFIG.exception_reporter } # transport failures use the global one

def self.server_for(profile)
  MCP::Server.new(
    name: "my-app", version: MyApp::VERSION,
    instructions: Instructions.for(profile),
    capabilities: { tools: { listChanged: false }, prompts: { listChanged: false },
                    resources: { subscribe: false, listChanged: false } },
    tools: Registry.tools_for(profile).map { |klass| ToolWrapper.build(klass) },
    prompts: Registry.prompts_for(profile).map { |klass| PromptWrapper.build(klass) },
    configuration: CONFIG
  )
end
```

Pass `capabilities:` explicitly: the gem's default advertises `listChanged` for tools, prompts and
resources, and `logging`, which a server that never sends those notifications shouldn't claim.

> **Example (graph_mem):** `ServerFactory.for(profile)` (40 lines) builds the `default` (12 tools),
> `readonly` (9) and `maintenance` (22) servers. `persist` is left off readonly because the prompt
> declares its profiles.

### Middleware and the HTTP transport

```ruby
# config/initializers/mcp.rb
Rails.application.config.middleware.use(AccessGate)     # token, IP allowlist: before anything else
Rails.application.config.middleware.use(RequestContext) # per-request context into env["mcp.auth_info"]
Rails.application.config.middleware.use(Router)         # path → that profile's transport, other /mcp/* → 404

# one transport per profile, built on first use
MCP::Server::Transports::StreamableHTTPTransport.new(
  server_for(profile),
  enable_json_response: true,                  # JSON answers to POSTs, as most fast-mcp setups sent
  max_sessions: Integer(ENV.fetch("MY_APP_MCP_MAX_SESSIONS", 256)), # per transport, so per endpoint; validate the env at boot
  max_request_bytes: 4 * 1024 * 1024,
  allowed_hosts: ENV.fetch("MY_APP_MCP_ALLOWED_HOSTS", "").split(",").map(&:strip).reject(&:empty?),
  allowed_origins: ENV.fetch("MY_APP_MCP_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
)
```

The transport is a Rack app: the router calls `transport.call(env)`. Transports built on first use
read the environment on the first request, so a malformed value would fail that request instead of
the boot: build the options once in an `after_initialize` block to fail early.

Every limit applies per transport. With one transport per endpoint, `max_sessions:` caps each
endpoint separately, and a client refused on one endpoint can still open a session on another.

**Per-request context.** Tool handlers don't see request headers. The only per-request value the
transport forwards to them is `env["mcp.auth_info"]`, as `server_context[:auth_info]` (also when
the tool runs on the SSE body's thread). The transport reads `issuer`, `subject` and `client_id`
from it to bind a session to its caller, so it must be an `MCP::Server::OAuth::AccessToken`. Put
your context in its `claims`, and leave `client_id` and `subject` nil unless you want sessions bound
to that identity:

```ruby
class RequestContext
  Context = Data.define(:client_id, :profile)

  def initialize(app) = @app = app

  def call(env)
    if (profile = Router.profile_for(env["PATH_INFO"]))
      context = Context.new(client_id: env["HTTP_X_MY_CLIENT"], profile: profile)
      env["mcp.auth_info"] = MCP::Server::OAuth::AccessToken.new(token: "my_app", claims: { my_app: context })
    end
    @app.call(env)
  end
end
```

The wrapper reads it back (`server_context[:auth_info].claims[:my_app]`) and hands it to the tool:
as headers for the tool's constructor, or in thread-locals set around the call.

**Auth.** Keep a static bearer token or an IP allowlist as Rack middleware in front of the
transport. The gem's `token_verifier:` is for OAuth.

> **Example (graph_mem):** `config/initializers/mcp.rb` sets the global reporter and checks the
> `GRAPH_MEM_MCP_*` numbers in `after_initialize`. `AccessGate` (37 lines) wraps the existing `McpAccessPolicy`;
> `RequestContext` (58 lines) carries `X-MCP-Client`, the profile and the `Mcp-Session-Id`, and sets
> the two thread-locals the tool base class reads; `Router` (41 lines) maps the three paths;
> `Transports` (50 lines) builds the transports from `GRAPH_MEM_MCP_*` settings. The only change in
> the tool base class was reading the profile from that thread-local instead of fast-mcp's
> `server.current_request`.

### stdio

The gem's `StdioTransport` reads `$stdin` and writes `$stdout`. Keep stray output off the protocol
stream: before Rails loads, save the real stdout and point `STDOUT` and `$stdout` at stderr. Then
subclass the transport and override its public `send_response` to write to the saved pipe:

```ruby
mcp_out = STDOUT.dup
STDOUT.reopen(STDERR)
$stdout = $stderr
require_relative "../config/environment"

class PipeStdioTransport < MCP::Server::Transports::StdioTransport
  def initialize(server, output:, **options)
    super(server, **options)
    @output = output
  end

  def send_response(message)
    @output.puts(message.is_a?(String) ? message : JSON.generate(message))
    @output.flush
  end
end

PipeStdioTransport.new(server_for(profile), output: mcp_out, max_line_bytes: 4 * 1024 * 1024).open
```

> **Example (graph_mem):** `bin/mcp_stdio_runner.rb` and `OfficialMcp::StdioTransport` (23 lines).
> The profile comes from `GRAPH_MEM_MCP_PROFILE`.

**Checklist:**
- [ ] the wrapper generates gem classes from the existing ones, with no per-tool code
- [ ] every tool error becomes an `isError` result in your shape
- [ ] one server per profile, with explicit `capabilities:`
- [ ] auth middleware in front, context through `env["mcp.auth_info"]`
- [ ] `allowed_hosts` covers every name clients use
- [ ] stdio writes only JSON-RPC to stdout

## 4. Mapping (checked against `mcp` 1.8.1)

| fast-mcp 1.8.0 | `mcp` 1.8.1 | Notes |
|---|---|---|
| `tool_name`, `description` | `tool_name`, `description` class methods | Tool names: 1–128 characters. |
| `arguments do … end` (dry-schema) | `input_schema` (a JSON Schema hash or an `InputSchema`) | Feed it the class's `input_schema_to_json`. The gem validates every schema against JSON Schema 2020-12 when the class is built: a schema fast-mcp accepted can fail here. |
| `inputSchema` in `tools/list` | adds `"$schema": "https://json-schema.org/draft/2020-12/schema"` | A wire difference; compare schemas without that key. |
| `annotations(read_only_hint: …)` | `annotations(read_only_hint: …)` | Same keys. The gem emits them in camelCase and fills unset hints with its defaults (`destructiveHint: true`, `openWorldHint: true`, …), so set all four. |
| `output_schema` | `output_schema` | Also validated when the class is built. |
| `#call(**args)` returning a String or Hash | `self.call(server_context:, **args)` returning an object with `#to_h` | Arguments arrive with symbol keys at every nesting level. |
| `InvalidArgumentsError` → an error result | a missing `required` key → `isError` text `Missing required arguments: …` **before** your code runs; schema violations likewise when `validate_tool_call_arguments` is on | Use the lenient `InputSchema` (§3) and `validate_tool_call_arguments: false` if your tools accept aliases for required keys. |
| an uncaught exception → an error result | JSON-RPC `-32603` `Internal error`, `data: "Internal error calling tool X"` | Rescue in the wrapper. |
| an unknown tool → `-32602` | `-32602` `Invalid params`, `data: "Tool not found: x"` | Same code; the message moved to `data`. |
| callable-but-hidden tools (a `tools/list` patch) | no hook: `tools/list` lists every registered tool | Remove them, or keep them advertised. |
| `filter_tools` / `filter_prompts` per request | one `MCP::Server` per profile | A session belongs to the endpoint that created it. |
| `FastMcp::Resource` (static or templated) | `MCP::Resource`, `MCP::ResourceTemplate` + `server.resources_read_handler { \|params\| … }` | The handler gets `params[:uri]` and returns the `contents` array. |
| `FastMcp::Prompt` | `MCP::Prompt` with `template(args, server_context:)` | Return an object whose `#to_h` is `{ description:, messages: }`. |
| `instructions` | `instructions:` | Per server, so per profile. |
| capabilities | `capabilities:` | Default: `listChanged` everywhere and `logging`. |
| `FastMcp::Transports::RackTransport` (HTTP+SSE) | none | Remove the endpoint. |
| `FastMcp::Transports::StdioTransport` | `MCP::Server::Transports::StdioTransport` | A line over `max_line_bytes` ends the session. |
| your Streamable HTTP transport | `MCP::Server::Transports::StreamableHTTPTransport` | Sessions, JSON or SSE answers, body and session caps, `MCP-Protocol-Version` check, DNS-rebinding protection, 2026-07-28. |

## 5. Pitfalls

- **Both gems loaded at once.** Until fast-mcp is gone, both gems are in the bundle, and fast-mcp
  ships `lib/mcp/{version,tool,prompt,resource,server}.rb`, the same relative paths as the `mcp`
  gem. The gem defines `MCP::Tool`, `MCP::Server`, … through load-path autoloads
  (`autoload :Tool, "mcp/tool"`), which resolve to fast-mcp's files, so `MCP::Tool` is silently
  never defined. Require those five from the gem's own directory right after `require "mcp"`, and
  delete the shim with fast-mcp:

  ```ruby
  require "mcp"
  lib = File.join(Gem.loaded_specs.fetch("mcp").full_gem_path, "lib")
  %w[version tool prompt resource server].each { |file| require File.join(lib, "mcp", file) }
  ```

- **Context through an `AccessToken`.** Anything else in `env["mcp.auth_info"]` breaks the
  transport's session binding, and nothing else reaches the handler (§3).
- **stdout on stdio.** One `puts`, or a logger on stdout, corrupts the stream; strict clients such
  as the Ruby SDK fail on any non-JSON line. Point `$stdout` at stderr before Rails loads (§3), and
  keep boot free of side effects: clients that probe `server/discover` in a separate process start
  the server twice.
- **Keep DNS-rebinding protection on.** Never pass `dns_rebinding_protection: false`: it also drops
  the `Origin` check, and an IP allowlist can't stop rebinding (the browser's requests come from an
  allowed address). List the names clients use in `allowed_hosts:` instead. Clients on other
  machines reaching the server by an address that isn't listed get `403`: say so in the upgrade
  notes.
- **Required-argument checks before your code runs** (§4).
- **Capabilities advertised but never delivered.** Pass your own `capabilities:`.
- **Hidden tools.** The gem lists every registered tool.
- **Sessions don't cross endpoints**, the session cap is per endpoint, and at the cap a new client
  gets `503` until sessions expire.
- **Two exception reporters.** The server's `Configuration` reports handler failures; transport
  failures go to the global `MCP.configure` one, a no-op unless you set it (§3).
- **Schema drift.** The gem's 2020-12 validation, the added `$schema` key, annotation defaults.
- **Autoloading.** Build the wrapper classes at boot from loaded tool classes; eager-load in
  development, or new tool files won't be served.
- **Shared server objects across threads.** Keep per-request data out of the server objects.
- **The gem pin.** Edge-case answers change between releases: pin an exact version and upgrade in
  its own PR, with the gate below.

## 6. Release 1 gate: the engine swap

Record a wire-level suite **before** the swap, on the old engine. It replays synthetic JSON-RPC over
stdio and HTTP and checks status codes, headers and bodies, never library classes:

- `initialize` for each protocol version you support, an unknown one, and `server/discover`;
- `tools/list`; `tools/call` on success, on a tool error and on invalid arguments;
- resources and prompts;
- malformed and non-object bodies, batches, null and missing ids;
- an oversized body, an unknown session, a `MCP-Protocol-Version` mismatch.

Run it against a plain one-tool server on the gem too: those answers preview every edge case that
changes (D10). Then the swap merges when:

- [ ] the full suite, the linter and the security scanner are green;
- [ ] **the existing tool, service, prompt and resource specs pass with no edits** (apart from
      removed aliases): they are the behaviour check;
- [ ] the wire suite's changes match the plain gem server's answers row for row;
- [ ] the official clients (the TS SDK and the Ruby SDK) connect in `auto` and `legacy` negotiation
      over stdio and HTTP, and `auto` negotiates 2026-07-28;
- [ ] new specs cover profile gating (counts per endpoint; a write tool refused on a read-only
      endpoint, with nothing written), auth (401 with `WWW-Authenticate`, 403 for a foreign IP,
      `Host` or `Origin`), the context header reaching your telemetry, the error result for an
      invalid-argument call, and the session cap's 503;
- [ ] a stdio spec checks that stdout carries only JSON-RPC, that errors come back in your shape,
      and that an over-long line ends the session without writing anything else;
- [ ] `rg -n "FastMcp|fast_mcp|fast-mcp"` finds nothing in the adapter, the initializer or the new specs.

Stop and rethink if a tool needs per-tool code in the wrapper, or the gem needs a monkey-patch or a
fork.

> **Example (graph_mem):** the cases are in `spec/fixtures/mcp/handshakes/` (16 stdio, 27 HTTP),
> replayed in the normal suite by `spec/requests/mcp_protocol_compat_spec.rb` and against running
> servers by `script/mcp_compat/compare.rb`, which also covers the reference servers and a plain
> `mcp` 1.8.1 server. `script/mcp_compat/clients.sh` is the client matrix. The results are in
> [`docs/protocol_compat.md`](../protocol_compat.md).

## 7. Release 2: removing fast-mcp

1. **Snapshot first.** On release 1, before changing anything, record `tools/list`, `prompts/list`
   and `resources/templates/list` for every profile as fixtures, and add a spec that compares them
   (sort each list by name: listing order follows class-load order).
2. **The schema DSL.** The base classes still use fast-mcp's `arguments do … end`. Choose one:
   - **vendor it**: fast-mcp is MIT-licensed, so its dry-schema extensions, the JSON Schema
     processor and the tool, prompt and resource class APIs can be copied in with the licence text
     and attribution (a `NOTICE` file naming the source and version), under your own namespace;
   - **freeze it**: commit each tool's generated schema as a hash, and keep your own runtime
     validation;
   - **plain JSON Schema** per tool, validated by the gem (only if your tools take exactly the
     advertised argument names).

   Add `dry-schema` (and `addressable`, for resource URI templates) as direct dependencies if you
   keep the DSL.
3. **Base classes** stop inheriting from fast-mcp classes.
4. **Error class:** replace `FastMcp::Tool::InvalidArgumentsError` with your own, everywhere
   (app and specs). It is mechanical.
5. **Delete:**
   - [ ] the `fast-mcp` gem and its pin, from the Gemfile and the lockfile;
   - [ ] the load shim (§5), now a plain `require "mcp"`;
   - [ ] patches on fast-mcp, and their specs;
   - [ ] your old transport code and its specs;
   - [ ] fast-mcp's initializer, error formatter and server options;
   - [ ] registration specs written for fast-mcp.

**Gate:**
- [ ] `rg -n "FastMcp|fast_mcp|fast-mcp" app lib config bin spec Gemfile Gemfile.lock` finds nothing
      (exclude fixtures that mention it as data, and the attribution files);
- [ ] the snapshot spec shows every list byte-identical to release 1;
- [ ] the full suite and release 1's gate specs are green;
- [ ] older CHANGELOG entries are untouched.

Stop and rethink if the vendored converter changes any `inputSchema`, or a tool depends on fast-mcp
behaviour beyond the schema DSL and the error class.

> **Example (graph_mem):** the DSL was vendored into `lib/graph_mem/mcp_schema/` (about 520 lines,
> MIT, with `LICENSE` and a root `NOTICE.md`); `GraphMem::InvalidArgumentsError` replaced the error
> class in about 40 files; about 1,100 lines of transport, patch and option code were deleted. The
> snapshot spec is `spec/mcp/tools_list_snapshot_spec.rb`.

## 8. Afterwards

- [ ] Docs: the stack line, the transport and endpoint list (no legacy SSE), the exception mapping,
      `allowed_hosts` for remote clients, and the protocol compatibility results.
- [ ] Upgrade notes: the breaking removals, the `Host` check, the session cap's 503.
- [ ] Re-run the wire suite and the client matrix on every gem upgrade.
