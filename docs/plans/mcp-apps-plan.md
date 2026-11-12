# MCP Apps → graph_mem 1.85.0–1.87.0: a graph view and a search view inside the chat

**Status (2026-11-12): PLAN, for Steve's review.** Written from `main` at `30beb6f` (1.84.0). No kickoff yet:
Steve reviews this plan first. File:line references were checked against that commit; if a line has moved, find
the code by the quoted text, and if the code no longer matches the description, **stop and ask Steve** instead of
improvising. Only code and the public spec were read while writing this plan. **No spec was run.**

## Goal

Two MCP Apps views that hosts supporting the extension (Claude, Cursor, VS Code Copilot, …) render next to the
chat, built only on graph_mem's existing tools:

1. **Graph view** (`ui://graph-mem/graph`): the Cytoscape.js graph of any knowledge subset, read-only.
2. **Search view** (`ui://graph-mem/search`): a query box, filters, paged hits, click-through to an entity.

Clients without the extension keep exactly today's behaviour: the same tools, the same text and
`structuredContent`.

## Steve's decisions (2026-11-11)

1. **The MCP tool surface stays as is:** no new tools, no new params, no new output keys.
2. **v1 is browse and search only.** The views never call `graph_write`, `graph_edit` or `graph_delete`. They may
   call `get_context` and `set_context`; `set_context` only to scope or filter what is shown.
3. **Unscoped graph view:** the graph view calls `get_context` first. With a context set it draws that subset;
   with none it shows all root entities, like Explore's default view.
4. **No deprecated alias:** no flat `_meta["ui/resourceUri"]`, only `_meta.ui.resourceUri`.
5. **Two views:** the existing Cytoscape.js graph (any subset) and search.

Design goal (Steve, 2026-11-12): **the resource layer is generic**, not hard-wired to `ui://`, so another kind of
static resource (for example skills, later) can register through the same code. This plan does not plan Skills over
MCP.

## Hard stops (ask Steve before doing any of these)

- **Any change to an MCP tool's params or outputs** (input schema, output schema, new keys in `structuredContent`,
  a changed text result), and any new tool, including an app-only tool (`_meta.ui.visibility: ["app"]`).
- **The default `/mcp` stays at 12 tools or fewer** (`spec/fixtures/mcp/snapshots/default.json`).
- **Any new gem, a gem bump (including `mcp` 1.9.0 → 1.10.0), a migration, or any non-stdlib package** (npm
  packages such as `@modelcontextprotocol/ext-apps`, a JS bundler, a CDN script).
- **Anything that weakens the lockdown or the anonymizer/cloud gate:** the `/mcp` `AccessGate` (IP allowlist and
  optional bearer token), the host bridge lockdown, `Llm::Anonymizer`, `cloud_allowed`. Nothing in this plan needs
  to touch them; if a step seems to, stop.
- **Letting a view call a write tool**, or `set_context` for anything but scoping (decision 2).
- **A new HTTP route or a wider CORS/allowlist** for the views. The views never call graph_mem over HTTP.
- **An exemption in a guard spec** (`spec/inline_scripts_spec.rb`, `spec/javascript_sinks_spec.rb`,
  `spec/outbound_http_guard_spec.rb`).

What the feature *does* add to the wire, by design, is listed under "What changes on the wire". Steve confirms
those additions (open question 1) before step A starts.

## The extension, as of 2026-11-12

Spec: SEP-1865, **Stable (2026-01-26)**,
<https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx>.

- **Negotiation:** extension id `io.modelcontextprotocol/ui`. The client declares
  `capabilities.extensions["io.modelcontextprotocol/ui"] = { mimeTypes: ["text/html;profile=mcp-app"] }`; the
  server declares the same under its capabilities. A client that doesn't declare it gets plain tools.
- **UI resources:** ordinary MCP resources with a `ui://` URI and MIME type `text/html;profile=mcp-app`; the content
  (`text` or base64 `blob`) MUST be a full HTML5 document. Servers MAY leave them out of `resources/list`, since
  hosts find them through tool metadata.
- **Resource `_meta.ui`** (on the listing and/or the `resources/read` content): `csp` (`connectDomains`,
  `resourceDomains`, `frameDomains`, `baseUriDomains`), `permissions` (camera, microphone, geolocation,
  clipboardWrite), `domain`, `prefersBorder`.
- **CSP default when `csp` is omitted:** `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self'
  'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'`. Hosts MUST NOT allow
  undeclared domains. So everything the views need must be inlined, and a view can't `fetch` anything.
- **Tool linkage:** `_meta.ui.resourceUri` on a tool in `tools/list`; optional `_meta.ui.visibility`
  (`["model", "app"]` by default). The flat `_meta["ui/resourceUri"]` is deprecated and goes before GA (decision 4:
  not emitted).
- **When a linked tool is called,** a host that supports the extension renders the linked view and pushes it
  `ui/notifications/tool-input` (the arguments) and `ui/notifications/tool-result` (the full `CallToolResult`,
  `structuredContent` included). **This happens on every call of a linked tool, including the agent's own calls**
  (open question 2).
- **View ↔ host messages** (JSON-RPC over `postMessage`, no SDK needed): `ui/initialize` →
  `ui/notifications/initialized`; `tools/call` and `resources/read` (proxied to the server, possibly after user
  consent); `ui/update-model-context` (overwrites what the view tells the model for later turns);
  `ui/message` (a follow-up into the chat); `ui/open-link`; `ui/request-display-mode` (`inline`, `fullscreen`,
  `pip`); `ui/notifications/size-changed`; `notifications/message` (logs). Host → view:
  `ui/notifications/host-context-changed` (theme, display mode, size), `ui/resource-teardown`,
  `ui/notifications/tool-cancelled`. Theming arrives as standard CSS variables in `hostContext.styles.variables`
  (`--color-background-primary`, `--font-sans`, …), with `light-dark()` values.
- **Graceful degradation:** tools MUST still return a meaningful `content` array. `structuredContent` is meant for
  the view and is not added to the model's context by hosts that follow the spec's guidance.

### Client support

- **Claude (web and Desktop):** listed on the official overview
  (<https://modelcontextprotocol.io/extensions/apps/overview>). Claude's 2026-11-10 update moves interactive
  connectors to a side panel or fullscreen and puts more of the extension (app tools) in public preview; not on
  Claude Mobile. A remote graph_mem still needs the usual reachable MCP endpoint (and a token off loopback); the view
  itself opens no connection.
- **Cursor:** its docs mark "Apps (extension)" as Supported (<https://cursor.com/docs/mcp>), since Cursor 2.6.
  Known issues in the forum: inline widgets stopped mounting for some sessions around 3.9.16 (fixed in 3.12), and
  servers configured in a project's `.cursor/mcp.json` never get their `ui://` resource read, while the same server
  in the global (user-level) `mcp.json` works. Test with a global entry on a current build.
- **Also listed on the overview:** VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam,
  Archestra.AI. Claude Code and other CLIs: assume no rendering; they keep the text result.

## The Ruby `mcp` gem

graph_mem pins `gem "mcp", "1.9.0"` (`Gemfile:36`). The newest release is **1.10.0** (2026-11-11: `Mcp-Param-*`
header validation, OAuth `issuer:`, stdio env and SSE hardening; **nothing for Apps or resources**). No bump is
needed for this train; a bump stays its own "one PR per upgrade" change and is a hard stop.

What **1.9.0 already has** (read at the `v1.9.0` tag):

- `MCP::Apps` (`lib/mcp/apps.rb`, since 0.24.0): `EXTENSION_ID`, `RESOURCE_MIME_TYPE`, `URI_SCHEME`,
  `Apps.capability`, `Apps.ui_resource(uri:, name:, …)` (refuses a non-`ui://` URI),
  `Apps.tool_meta(resource_uri:, visibility: nil, meta: nil, legacy: false)` (use the default `legacy: false`,
  decision 4), `Apps.client_supports?(client_capabilities)`.
- **Extension capability declaration:** `MCP::Server::Capabilities#support_extensions` (SEP-2133, merges
  repeated calls). graph_mem passes a plain `CAPABILITIES` hash today, so either add an `extensions:` key to it or
  switch to a `Capabilities` object; step A checks which one the 1.9.0 server serializes unchanged.
- **Tool `_meta`:** `MCP::Tool.meta(value)` (`lib/mcp/tool.rb:113`), serialized as `_meta` in `tools/list`.
- **Resources:** static resources (`MCP::Server.new(resources:)`, `#resources=`, `#define_resource`, with `meta:`),
  templates, and `resources_read_handler`, which **fully replaces** the default read dispatch. `_meta` on resource
  contents has been supported since 0.13.0.
- Also in 1.9.0, not used here: the Skills extension (SEP-2640, `MCP::Skill`), relevant only to a later Skills over
  MCP decision.

What **graph_mem has to wire or hand-roll** (all graph_mem code, no protocol reimplementation):

- `ServerFactory::CAPABILITIES` (`lib/graph_mem/official_mcp/server_factory.rb:12-16`) advertises tools, resources
  and prompts only: add the Apps extension.
- `ServerFactory.for` registers only `resource_templates:` and a `resources_read_handler` that goes straight to
  `ResourceCatalog.read` (`server_factory.rb:24-35`). Because that handler replaces the gem's dispatch, the gem's
  own static-resource read path is never reached: `ResourceCatalog` must learn to read static resources itself.
- `ResourceCatalog.read` (`lib/graph_mem/official_mcp/resource_catalog.rb:20-27`) returns
  `{ uri, mimeType, text|blob }` and never `_meta`.
- `ToolWrapper.build` (`lib/graph_mem/official_mcp/tool_wrapper.rb:27`, the `Class.new(MCP::Tool)` block) sets name, title, description, schemas
  and annotations, never `meta`.
- **The view runtime** (HTML documents, a ~100-line vanilla `postMessage` bridge, the result → Cytoscape adapter,
  inlining Cytoscape): nothing in the gem covers it, by design; it is host-side protocol.

## What changes on the wire (by design; open question 1)

- `initialize` result: `capabilities.extensions["io.modelcontextprotocol/ui"]`.
- `tools/list`: `_meta.ui.resourceUri` on the linked tools only. Names, descriptions, input and output schemas
  unchanged.
- `resources/list`: two static `ui://` resources (or none, if Steve prefers to rely on tool metadata only; the spec
  allows both). `resources/templates/list`: unchanged.
- `resources/read` for the two `ui://` URIs: an HTML document with `_meta.ui`.
- `tools/call` results: **unchanged**, for every client.

The snapshots (`spec/fixtures/mcp/snapshots/{default,readonly,maintenance}.json`) and the handshake fixtures
(`spec/fixtures/mcp/handshakes/{http,stdio}.json`) are re-recorded once, in step A, and the diff must show only the
items above.

## Design

### Generic resource layer

Today `ResourceCatalog` knows one kind of resource: the templated `ApplicationResource` classes
(`memory_graph{?…}` and friends, `application/json`). Step A turns it into a small registry of **providers**, each
answering `resources` (static listings), `templates`, `match?(uri)` and `read(uri)` → contents (with optional
`_meta`):

- `TemplateResourceProvider`: today's behaviour, moved as is (same URIs, same output).
- `StaticResourceProvider`: a frozen list of `{ uri:, name:, title:, description:, mime_type:, meta:, body: }`,
  where `body` is a callable that builds the content once and memoizes it. It has no knowledge of `ui://`.
- `McpApps::Views`: registers the two views into a `StaticResourceProvider`, using `MCP::Apps.ui_resource` for the
  listing (which enforces the `ui://` scheme and MIME type) and adding `_meta.ui` to both listing and content.

`resources/read` asks the providers in order and raises `ResourceNotFoundError` as today when none matches. A later
provider (skills, or anything else) registers the same way without touching the read path. Static resources are
per profile, like tools, so a view is only registered on a profile that advertises the tools it calls.

### Which tools link to which view

The view a host renders for a tool call is decided by the **tool's** `_meta.ui.resourceUri`, and hosts render it on
every call of that tool, the agent's included. Linking `search` and `get_entities` (the two tools agents call most)
would put a widget into nearly every turn that touches memory. Recommendation, pending open question 2:

| Tool | Links to | Why |
|---|---|---|
| `traverse_graph` | graph view | A neighbourhood or path is a graph by nature, and agents call it rarely. |
| `find_shortest_path` | graph view | Same. |
| `get_context` | graph view | The natural "show me my project" entry point; rare in agent turns. |
| `search` | **not linked in v1** (search view only if Steve wants it; see question 2) | The most frequent agent call. |
| `get_entities` | not linked | Frequent; the views call it, it needs no view of its own. |
| `set_context` | not linked | The views call it; it returns no graph. |

A view can call **any** model-visible tool through `tools/call`, linked or not, so the search view can still call
`search`, and the graph view `get_entities`. The linkage only decides which tool *results* open a view by
themselves. If `search` stays unlinked, the search view is reached from the graph view (a search box that swaps the
view) or, in hosts that list UI resources, opened directly. Step A verifies on Claude and Cursor how a view is
reachable without a linked tool; if it isn't, open question 2 decides between linking `search` and merging the two
views into one document with two tabs.

### Graph view (`ui://graph-mem/graph`)

On `ui/notifications/tool-result` from a linked tool it draws that result. On first load with no tool result
(opened directly), it follows decision 3:

1. `tools/call get_context`. If it returns a project (`status` other than `no_context`): draw that project's
   subset with `search` in catalog mode (`project_id:`, `per_page: 100`, paging up to a cap) plus
   `get_entities(entity_ids:, relations: "internal")` for the edges.
2. With no context: draw all root entities, Explore's default view. Explore picks
   `entity_type IN ("Project", NULL)` (`app/controllers/api/v1/graph_data_controller.rb:66-70`). Through existing
   tools that is `search` in catalog mode with `entity_types: ["Project"]`, paged, then
   `get_entities(relations: "internal")`. Untyped entities (`entity_type` NULL) can't be selected by
   `entity_types`; they are left out, and the view says so (open question 5).
3. Node cap: the same 2,000 as `GraphDataController::MAX_NODES`, with a "truncated, N total" note.

Interaction: click a node → `get_entities` for its details in a side panel (observations, relations); a depth 1/2
"expand" → `traverse_graph`; "path between two selected nodes" → `find_shortest_path`; "scope to this project" →
`set_context(entity_id)` and redraw, and "clear scope" → `set_context(null)`, both only on an explicit click
(decision 2). The selection goes to `ui/update-model-context` as a short text plus ids, so the next agent turn knows
what the user is looking at. No write tool is ever called; there is no edit control in the DOM.

`set_context` is per MCP client (`app/tools/set_context_tool.rb`, `graph_mem_context.set_project!`), and the host
proxies the view's calls over the agent's own connection, so **scoping in the view also changes the agent's active
project** (which only boosts `search`, never filters). The view labels the control "Set as active project" and shows
the `shared_client_id_warning` if the tool returns one.

### Search view (`ui://graph-mem/search`)

A query box, the filters `search` already takes (project, entity types, match-in name/type/aliases/observations,
perspective), paging (`page`, `per_page`), and a hit list built from `search`'s `structuredContent`. Clicking a hit
calls `get_entities`; "Show as graph" swaps to the graph view with those ids (the same idea as the Search page's
"Show as graph"). The current query goes to `ui/update-model-context`.

### Rendering and packaging

- **Reuse:** `GRAPH_STYLES` and `LAYOUT_OPTIONS` from `app/javascript/graph/cytoscape_config.js`, the graph rules
  of `app/assets/stylesheets/graph.css`, the same vendored Cytoscape 3.31.4. **Don't reuse**
  `explore_controller.js` (Stimulus, Turbo, history, edit dialogs, drag-drop edits) or `api_client.js`
  (`fetch('/api/v1/graph_data')`): neither works under `connect-src 'none'`, and both carry edit paths.
- **Inline everything; no CDN, no `csp` domains.** The vendored build
  (`vendor/javascript/cytoscape.js-3.31.4-dist/cytoscape.esm.min.mjs`, 416,235 bytes) is ESM ending in
  `export{Ah as default};`. A data: or blob: module import is blocked by the default `script-src`, so the HTML
  builder inlines the file into one `<script type="module">` and rewrites that exact trailer to a local binding.
  A spec pins the trailer, so a future Cytoscape bump fails loudly instead of shipping a broken view. No second copy
  of the file is committed; the HTML is built at boot (memoized) from the files already in the repo.
- **Where the files live:** the view JS under `app/javascript/mcp_apps/` (so `spec/javascript_sinks_spec.rb` covers
  it; render text with `textContent`, never `innerHTML` with graph data), the HTML shells outside `app/views` (they
  must carry inline scripts by design, and `spec/inline_scripts_spec.rb` forbids those in `app/views`; no exemption
  is needed if they live elsewhere), for example `lib/graph_mem/mcp_apps/templates/`.
- `_meta.ui`: `prefersBorder: true`, no `csp` (the restrictive default), no `permissions`, no `domain`.
- **Theming:** read `hostContext.styles.variables` and `theme`, with fallbacks in `:root`, so the views follow the
  host's light/dark mode. (The operator UI's own theme switch stays a separate backlog item.)
- **Size:** about 430 KB per graph view document. Hosts may cache it; check that both transports (Streamable HTTP
  and stdio) send a response that size without hitting a limit, and record the number in the PR.

### Lockdown, privacy, cloud gate

- `AccessGate` already wraps every `/mcp` path; `resources/read` and the view's proxied `tools/call` use the same
  session and token. No new route, no allowlist change.
- The templates are static: no graph data, settings, paths or hostnames are baked into the HTML. Facts reach the
  view only in tool results, which the host already receives today.
- The anonymizer and `cloud_allowed` govern graph_mem's own LLM calls; this train makes none and changes none.
- Tool results keep today's `content` text for the model; the views read `structuredContent`, so nothing new goes
  to the host's model.

## Steps (one PR each)

Versions follow 1.84.0. Each PR keeps the default `/mcp` at 12 tools, unchanged tool schemas and results, the
operator Explore and Search pages untouched, and its own CHANGELOG entry and docs.

### A. Generic resource layer, Apps capability, stub views → 1.85.0

- Providers as above; `TemplateResourceProvider` first, in its own commit, with no output change (snapshots
  identical).
- Declare the extension; register the two `ui://` resources on the profiles that advertise their tools; add
  `_meta.ui.resourceUri` to the tools Steve picks (question 2) through `ToolWrapper` (a per-tool `mcp_ui_view`
  setting on `ApplicationTool`, empty by default).
- Stub HTML for both views: the `ui/initialize` handshake, a title, and the tool result's entity count.
- Specs: `initialize` carries the extension; `tools/list` has `_meta.ui` on exactly the linked tools and nothing
  else changed; `resources/read` for each `ui://` URI returns the MIME type, a full HTML document, `_meta.ui`, and no
  `http:`/`https:` `src`/`href` and no `fetch(`; an unknown URI still raises not-found; the templated resources read
  as before; a client without the extension gets byte-identical `tools/call` results.
- Re-record the snapshots and handshake fixtures; `docs/mcp_tools.md` and `docs/protocol_compat.md` get a short
  MCP Apps section.
- Manual check, recorded in the PR: the stubs render in Claude and in Cursor (global server entry), and how a view
  is reachable without a linked tool (question 2).

### B. Graph view → 1.86.0

- The bridge helper, the HTML builder with inlined Cytoscape (trailer rewrite and its spec), the result → elements
  adapter for `search`, `get_entities`, `traverse_graph`, `find_shortest_path` and `get_context` results, the
  unscoped/scoped first load (decision 3), the node panel, expand, path, scope/clear, model-context updates, host
  theming.
- Specs: adapter unit specs on synthetic envelopes recorded from the real tools in the test DB (synthetic entities
  only); a headless smoke with a stub `postMessage` host if it fits the existing system-spec setup without a new
  gem or package (otherwise a manual check).

### C. Search view, docs → 1.87.0

- The search view (filters, paging, click-through, "Show as graph"), the user guide page
  (`docs/guides/` or `docs/operator/`: what the views do, which clients render them, the Cursor global-entry note),
  README feature line, CHANGELOG.
- Manual check on Claude and Cursor, recorded in `docs/protocol_compat.md`.

If step A shows that a view can't be opened without a linked tool and Steve keeps `search` unlinked, B and C merge
into one document with two tabs (one `ui://` resource), and C becomes the docs-only patch.

## Open questions for Steve

1. **The wire additions** listed under "What changes on the wire" (the capability, `_meta.ui` on some tools, two
   `ui://` resources in `resources/list`, their `resources/read`): are they within "the surface stays as is"?
   Tool names, params, outputs and results do not change.
2. **Which tools link to a view?** Recommended: `traverse_graph`, `find_shortest_path` and `get_context` → graph
   view; `search` and `get_entities` unlinked, so routine agent memory calls don't open a widget every turn. Or link
   `search` → search view too, accepting a widget on most memory turns.
3. **Which profiles get the views?** Recommended: `default` and `readonly` (the readonly profile has every tool the
   views call); `maintenance` too?
4. **List the `ui://` resources in `resources/list`,** or rely on tool metadata only (the spec allows both)?
   Recommended: list them.
5. **Untyped root entities:** Explore's root view also shows entities with no type, which `search`'s
   `entity_types` filter can't select. Accept that the view leaves them out (with a note), or is that worth a tool
   change later (a hard stop)?
6. **An on/off setting** (`mcp_apps_enabled`, a settings-table key, no migration) so the capability, the links and
   the resources can be turned off without a deploy? Default on or off?
7. **Scoping changes the agent's active project** (one context per MCP client). Fine as is, with the label "Set as
   active project", or should the view restore the previous context when it closes (best effort; a host may tear
   the view down without notice)?
