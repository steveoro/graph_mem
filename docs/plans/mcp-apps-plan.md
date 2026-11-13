# MCP Apps → graph_mem 1.85.0–1.87.0: a graph view and a search view inside the chat

**Status (2026-11-12): PLAN, reviewed, all questions answered.** Written from `main` at `30beb6f` (1.84.0) and **reviewed the
same day at `9df8556`** against three sources: this repo's code, the installed `mcp` 1.9.0 gem source, and the
live spec (stable 2026-01-26 and the draft). The review changed the first-load design, the tool linkage and the
view packaging, and added the sections from "Acceptance criteria" on; "What the review changed" lists the
differences. Steve answered every open question on 2026-11-12 (decisions 6–13). No kickoff yet. File:line
references were checked at `9df8556`; if a line has moved, find the code by the quoted text, and if the code no
longer matches the description, **stop and ask Steve** instead of improvising. Only `spec/docs` was run.

## Goal

MCP Apps views that hosts supporting the extension (Claude, Cursor, VS Code Copilot, …) render next to the chat,
built only on graph_mem's existing tools:

1. **Graph view:** the Cytoscape.js graph of any knowledge subset, read-only.
2. **Search view:** a query box, filters, paged hits, click-through to an entity.

They are two modes of one `ui://` document (decision 6; see "How a view opens" for why).

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

### After the review (2026-11-12)

The review found that decisions 3 and 5 meet limits in the spec and in the `search` tool. Steve decided:

6. **One document with a Graph mode and a Search mode** (`ui://graph-mem/graph`); `search` is not linked. This is
   how decision 5 is applied.
7. **`get_context` is not linked.** Only `traverse_graph` and `find_shortest_path` open the view. Decision 3 is
   applied inside the view: "Context project" and "Root entities" are buttons.
8. **The root view pages the unfiltered catalog** and filters in the view. No change to `search`. Revisit when a
   graph outgrows the 2,000-entity scan or the load is slow in practice; the tool change (filters in catalog mode)
   stays a hard stop.
9. **v1 has no `set_context` control.** Scoping is local to the view. Decision 2 allows `set_context`; v1 doesn't
   use it, so the view changes no server state. The user can ask the agent to set the active project.
10. **The wire additions are accepted** as exceptions to "the surface stays as is" (the list under "What changes
    on the wire"). On the tool count of the default `/mcp`: the hard limit is about 20 tools, and under 15 is
    better. It is 12 today and this train adds none.
11. **The view is registered on all three profiles** (`default`, `readonly`, `maintenance`).
12. **An on/off setting,** `mcp_apps_enabled`, default on.
13. **The `ui://` resource is listed in `resources/list`.**

## What the review changed

- **First load.** `search` refuses `project_id` and `entity_types` without a query, so the first draft's "catalog
  mode with filters" cannot run. The project subset now comes from `traverse_graph`, the root view from the
  unfiltered catalog.
- **How a view opens.** The spec has no way to open a view without a linked tool call, and no way for one view to
  load another. The two views become two modes of one document.
- **`get_context` linkage.** Agents call `get_context` at the start of every task, so linking it opens a widget in
  every session. The recommendation no longer links it.
- **Scoping.** The view scopes locally and v1 calls `set_context` nowhere.
- **Packaging.** View JS moves out of `app/javascript/` (Propshaft would serve it publicly).
- **Facts corrected:** what the fixtures hold, what the guard specs scan, `get_context` statuses,
  several gem and spec details.
- **Sections added:** acceptance criteria, compat verification, size, release and housekeeping.

## Hard stops (ask Steve before doing any of these)

- **Any change to an MCP tool's params or outputs** (input schema, output schema, new keys in `structuredContent`,
  a changed text result, a relaxed validation), and any new tool, including an app-only tool
  (`_meta.ui.visibility: ["app"]`).
- **A change to the tool count of any profile.** This train adds no tool, so the default `/mcp` stays at 12
  (`spec/fixtures/mcp/snapshots/default.json`). Steve's limit for it is about 20, preferably under 15
  (decision 10); a new tool is still his call.
- **Any new gem, a gem bump (including `mcp` 1.9.0 → 1.10.0), a migration, or any non-stdlib package** (npm
  packages such as `@modelcontextprotocol/ext-apps`, a JS bundler, a CDN script).
- **Anything that weakens the lockdown or the anonymizer/cloud gate:** the `/mcp` `AccessGate` (IP allowlist and
  optional bearer token), the host bridge lockdown, `Llm::Anonymizer`, `cloud_allowed`. Nothing in this plan needs
  to touch them; if a step seems to, stop.
- **Letting a view call a write tool**, or `set_context` at all in v1 (decisions 2 and 9).
- **A new HTTP route, a new public asset path, or a wider CORS/allowlist** for the views. The views never call
  graph_mem over HTTP, and their sources are not served by the Rails app.
- **An exemption in a guard spec** (`spec/inline_scripts_spec.rb`, `spec/javascript_sinks_spec.rb`), or a view
  source that the new view-source spec (step A) would reject.
- **Overriding private gem code** (for example `MCP::Server#list_tools`) to vary a list per client.

What the feature *does* add to the wire, by design, is listed under "What changes on the wire". Steve accepted
those additions (decision 10); anything beyond that list is a hard stop.

## The extension, as of 2026-11-12

Spec: SEP-1865, **Stable (2026-01-26)**,
<https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx>. The repo's
`specification/` holds only `2026-01-26` and `draft` (last draft commit 2026-11-04).

- **Negotiation:** extension id `io.modelcontextprotocol/ui`. The client declares
  `capabilities.extensions["io.modelcontextprotocol/ui"] = { mimeTypes: ["text/html;profile=mcp-app"] }`. The
  server declares the extension in its `initialize` result too: a client uses an extension only when both sides
  declare it. A client that doesn't declare it gets plain tools.
- **Gating by client:** the spec says servers SHOULD check the client's capability before registering UI-enabled
  tools. graph_mem can't do that in `tools/list` (see "The Ruby `mcp` gem"), so `_meta.ui` goes to every client.
  That is tolerated: a host without the extension treats the tool as a plain tool.
- **UI resources:** ordinary MCP resources with a `ui://` URI and MIME type `text/html;profile=mcp-app`; the content
  (`text` or base64 `blob`) MUST be a valid HTML5 document. Servers MAY leave them out of `resources/list`, since
  hosts find them through tool metadata.
- **Resource `_meta.ui`:** `csp` (`connectDomains`, `resourceDomains`, `frameDomains`, `baseUriDomains`),
  `permissions` (camera, microphone, geolocation, clipboardWrite), `domain`, `prefersBorder`. **Put it on the
  `resources/read` content item:** that is where the stable spec's examples and the official SDK read it, and the
  draft makes the content item win over the listing. Repeating it on the listing is optional.
- **CSP default when `csp` is omitted:** `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self'
  'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'` (the draft adds
  `object-src 'none'`). Hosts MUST NOT allow undeclared domains. What follows for the views:
  - everything must be inlined, and a view can't `fetch` anything;
  - an inline `<script type="module">` runs; a `blob:` or `data:` script does not;
  - no `eval` or `new Function`, no WASM, no `blob:` workers;
  - no `font-src`, so embedded fonts are blocked: use the host's font variables or system fonts.
- **Tool linkage:** `_meta.ui.resourceUri` on a tool in `tools/list`; optional `_meta.ui.visibility`
  (`["model", "app"]` by default). The flat `_meta["ui/resourceUri"]` is deprecated and goes before GA (decision 4:
  not emitted).
- **How a view opens.** The spec's only rule is: a tool with `_meta.ui.resourceUri` is rendered with that resource
  when it is called. So:
  - a view opens on **every call of a linked tool, the agent's own calls included**;
  - there is **no way to open a view without a linked tool call** (no "open this `ui://` resource" action);
  - **one view cannot load or switch to another** `ui://` resource (view-to-view communication is listed as future
    work);
  - a tool result cannot choose its view: `resourceUri` is fixed on the tool definition.
- **What the host pushes to the view:** `ui/notifications/tool-input` (the arguments, at most once, before the
  result) and `ui/notifications/tool-result` (the full `CallToolResult`, `structuredContent` included). The host
  sends nothing before the view's `ui/notifications/initialized`.
- **View ↔ host messages** (JSON-RPC over `postMessage`, no SDK needed):
  - `ui/initialize` (params: `protocolVersion` `"2026-01-26"`, `appInfo`, `appCapabilities` with
    `availableDisplayModes: ["inline", "fullscreen"]`) → `ui/notifications/initialized`; the view requests
    `fullscreen` only if `hostContext.availableDisplayModes` lists it;
  - `tools/call` and `resources/read`, proxied to the server. A view can call **any tool of the same server whose
    visibility includes `"app"`** (the default), linked or not. The host MAY block a call or ask the user first;
  - `ui/update-model-context` (replaces what the view told the model before), `ui/message` (a follow-up into the
    chat), `ui/open-link`, `ui/request-display-mode` (`inline`, `fullscreen`, `pip`),
    `ui/notifications/size-changed`, `notifications/message` (logs), `ping`;
  - host → view: `ui/notifications/host-context-changed` (theme, display mode, size),
    `ui/notifications/tool-cancelled`, and `ui/resource-teardown`, which carries an id and **expects a response**.
- **Theming** arrives as standard CSS variables in `hostContext.styles.variables` (`--color-background-primary`,
  `--font-sans`, …) with `light-dark()` values, plus `hostContext.theme`. Views should set fallback values.
- **Graceful degradation:** tools MUST still return a meaningful `content` array. As a best practice (not a MUST),
  hosts keep `structuredContent` out of the model's context. graph_mem's `content` text is already the same JSON
  as `structuredContent` (`lib/graph_mem/official_mcp/tool_wrapper.rb:86-87`), so the model sees the same data
  either way.
- **Size:** neither the spec nor the docs set a limit for the HTML resource. The SDK docs note that some hosts
  limit tool-result sizes.

### Client support

- **Claude (web and Desktop):** listed on the official overview
  (<https://modelcontextprotocol.io/extensions/apps/overview>). Claude's 2026-11-10 update moves interactive
  connectors to a side panel or fullscreen and puts more of the extension (app tools) in public preview; not on
  Claude Mobile. A remote graph_mem still needs the usual reachable MCP endpoint (and a token off loopback); the view
  itself opens no connection. ext-apps issue #671 (open) reports Claude fetching a resource without rendering the
  iframe, so step A's manual check on Claude comes first.
- **Cursor:** its docs mark "Apps (extension)" as Supported (<https://cursor.com/docs/mcp>), since Cursor 2.6.
  Known issues in the forum: inline widgets stopped mounting for some sessions around 3.9.16 (fixed in 3.12), and
  servers configured in a project's `.cursor/mcp.json` never get their `ui://` resource read, while the same server
  in the global (user-level) `mcp.json` works. Test with a global entry on a current build.
- **Also listed:** VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam, Archestra.AI on the
  overview; ChatGPT, PostHog Code, Kiro Crew and Glean in the client matrix; MCP Inspector as partial.
- **Claude Code** is in the matrix without Apps support. It and other CLIs keep the text result.

## The Ruby `mcp` gem

graph_mem pins `gem "mcp", "1.9.0"` (`Gemfile:36`). The newest release is **1.10.0** (2026-11-11: `Mcp-Param-*`
header validation, OAuth `issuer:`, stdio env and SSE hardening; **nothing for Apps or resources**). No bump is
needed for this train; a bump stays its own "one PR per upgrade" change and is a hard stop.

What **1.9.0 already has** (read in the installed gem):

- `MCP::Apps` (`lib/mcp/apps.rb`, autoloaded): `EXTENSION_ID`, `RESOURCE_MIME_TYPE`, `URI_SCHEME`, and
  - `Apps.capability` → `{ "io.modelcontextprotocol/ui" => { mimeTypes: [...] } }`;
  - `Apps.ui_resource(uri:, name:, **rest)`: refuses a non-`ui://` URI and returns an `MCP::Resource` **instance**
    for the listing. It takes `title`, `description`, `meta` and the other `Resource` fields; there are no
    `csp`, `permissions` or `prefers_border` keywords, so the `ui` hash is written by hand inside `meta:`;
  - `Apps.tool_meta(resource_uri:, visibility: nil, meta: nil, legacy: false)`: returns
    `{ ui: { resourceUri: uri } }` with **Symbol keys** (use the default `legacy: false`, decision 4);
  - `Apps.client_supports?(client_capabilities)`.
- **Capability declaration:** `MCP::Server.new(capabilities:)` stores a plain Hash unchanged
  (`lib/mcp/server.rb:1679-1685`), so `CAPABILITIES.merge(extensions: MCP::Apps.capability)` is serialized as
  written. **Don't switch to a `Capabilities` object:** it drops the explicit `subscribe: false` and
  `listChanged: false` values that the handshake cases expect.
- **Tool `_meta`:** `MCP::Tool.meta(value)` (`lib/mcp/tool.rb:113`), serialized as `_meta` in `tools/list`.
- **`tools/list` is the same for every client:** `list_tools` takes no request context and has no handler hook. A
  tool (`server_context.client_capabilities`) and the read handler can see the client's capabilities; the tool
  list cannot vary by them.
- **Resources:** static resources (`MCP::Server.new(resources:)`, with `meta:` serialized as `_meta`), templates,
  and `resources_read_handler`, which **fully replaces** the default read dispatch. The handler's return value
  becomes `contents` as is, so it must return plain Hashes; a `_meta` key in them reaches the wire unchanged.
  `MCP::Resource::TextContents.new(uri:, mime_type:, text:, meta:).to_h` builds such a Hash.
- The gem's own read dispatch can't replace graph_mem's: it reads only resource *classes* (not the instance
  `Apps.ui_resource` returns), and its template matcher doesn't handle the `{?…}` form graph_mem's templates use.
- **Response size:** no limit and no chunking on outgoing responses on either transport. graph_mem serves one JSON
  body per response (`enable_json_response: true`). The 4 MiB caps apply to incoming requests only.
- Also in 1.9.0, not used here: the Skills extension (SEP-2640, `MCP::Skill`), relevant only to a later Skills over
  MCP decision.

What **graph_mem has to wire or hand-roll** (all graph_mem code, no protocol reimplementation):

- `ServerFactory::CAPABILITIES` (`lib/graph_mem/official_mcp/server_factory.rb:12-16`) advertises tools, resources
  and prompts only: add the `extensions:` key.
- `ServerFactory.for` passes no `resources:` (so `resources/list` is empty today), only `resource_templates:`, and
  sets a `resources_read_handler` that goes straight to `ResourceCatalog.read` (`server_factory.rb:25-35`).
  `ResourceCatalog` must learn to list and read static resources itself.
- `ResourceCatalog.read` (`lib/graph_mem/official_mcp/resource_catalog.rb:20-27`) returns
  `{ uri, mimeType, text|blob }` and never `_meta`.
- `ToolWrapper.build` (`lib/graph_mem/official_mcp/tool_wrapper.rb:27`, the `Class.new(MCP::Tool)` block) sets
  name, title, description, schemas and annotations, never `meta`. It also receives no profile, which matters
  when a profile or a setting leaves the views out (see "Profiles and the on/off setting").
- `bin/mcp_stdio_runner.rb:51-53` logs the counts of tools, prompts and templates: add the static resources.
- **The view runtime** (the HTML document, a ~100-line vanilla `postMessage` bridge, the result → Cytoscape
  adapter, inlining Cytoscape): nothing in the gem covers it, by design; it is host-side protocol.

## What changes on the wire (by design; decision 10)

- `initialize` result: `capabilities.extensions["io.modelcontextprotocol/ui"]`, for every client.
- `tools/list`: `_meta.ui.resourceUri` on the linked tools only, for every client. Names, descriptions, input and
  output schemas unchanged.
- `resources/list`: the static `ui://` resource, where today the list is empty (decision 13).
  `resources/templates/list`: unchanged.
- `resources/read` for the `ui://` URI: an HTML document with `_meta.ui` on the content item.
- `tools/call` results: **unchanged**, for every client.

How the specs see these changes:

- `spec/mcp/tools_list_snapshot_spec.rb` compares `tools/list`, `prompts/list` and `resources/templates/list`
  only (`list_methods`, line 14). Step A adds `resources/list` to that list and re-records the three snapshots
  (`spec/fixtures/mcp/snapshots/{default,readonly,maintenance}.json`) by hand, as `docs/development.md:129`
  describes. The diff must show only `_meta` on the linked tools and the new `resources/list` block.
- The handshake fixtures (`spec/fixtures/mcp/handshakes/{http,stdio}.json`) are hand-written expectations matched
  by subset (`script/mcp_compat/handshake_cases.rb`), not recordings. An added `extensions` key passes them
  unchanged. Step A adds an expectation for it instead of re-recording anything.
- Three checks compare the served capabilities with `CAPABILITIES.deep_stringify_keys`
  (`spec/requests/mcp_official_spec.rb:66`, `spec/integration/mcp_structured_output_stdio_spec.rb:76`,
  `script/mcp_compat/claude_client_check.rb:249`). They follow the constant, so they keep passing with the
  plain-hash form.

## Design

### Generic resource layer

Today `ResourceCatalog` knows one kind of resource: the templated `ApplicationResource` classes
(`memory_graph{?…}` and friends, `application/json`). Step A turns it into a small registry of **providers**, each
answering `resources` (static listings), `templates`, `match?(uri)` and `read(uri)` → contents (with optional
`_meta`):

- `TemplateResourceProvider`: today's behaviour, moved as is (same URIs, same output).
- `StaticResourceProvider`: a frozen list of `{ uri:, name:, title:, description:, mime_type:, meta:, body: }`,
  where `body` is a callable that builds the content once and memoizes it. It has no knowledge of `ui://`.
- `McpApps::Views`: registers the view(s) into a `StaticResourceProvider`, using `MCP::Apps.ui_resource` for the
  listing (which enforces the `ui://` scheme and MIME type) and `MCP::Resource::TextContents#to_h` with
  `meta: { ui: … }` for the content.

`resources/read` asks the providers in order and raises `ResourceNotFoundError` as today when none matches. A later
provider (skills, or anything else) registers the same way without touching the read path.

### Profiles and the on/off setting

Resource templates are on every profile today (`McpToolRegistry.resource_classes` isn't filtered), so **static
resources per profile are new behaviour**, not a copy of an existing pattern. Two rules keep the three lists
consistent:

- A view is registered on a profile only if that profile advertises every tool the view calls.
- A tool carries `_meta.ui` only on a server that also registers its view. `ToolWrapper.build(klass)` therefore
  needs to know which views the server being built has (pass the profile's view URIs, or a
  `linked_view_for(klass)` callable, from `ServerFactory.for`).

The three profiles that exist: `readonly` has all five tools the view calls (`search`, `get_entities`,
`traverse_graph`, `find_shortest_path`, `get_context`); `default` and `maintenance` add the write tools, which
the view never calls. The only state the view can change is through `get_context`, which clears a stale context
(a deleted project) exactly as it does for an agent.

The view is on all three profiles (decision 11), so the first rule only matters for a later view or profile.

The on/off setting (decision 12) is `mcp_apps_enabled`, default on: an `AppSettings` field in the
`:feature_flags` group of `SettingsSchema` (`app/services/settings_schema.rb:120`), with its i18n label and help
text (`spec/services/settings_schema_spec.rb` requires both). No migration. Servers are built once per transport, so a
change takes effect after `Transports.reset!` (which closes open MCP sessions) on HTTP, and after a restart on
stdio. With the setting off, the server declares no extension, links no tool and lists no `ui://` resource:
today's wire, exactly.

### Which tools link to which view

The view a host renders for a tool call is decided by the **tool's** `_meta.ui.resourceUri`, and hosts render it on
every call of that tool, the agent's included. How often agents call each tool therefore decides how often a
widget appears:

| Tool | Agent calls it | Linked to | Why |
|---|---|---|---|
| `traverse_graph` | rarely | **graph view** | A neighbourhood is a graph by nature. |
| `find_shortest_path` | rarely | **graph view** | Same. |
| `get_context` | **at the start of every task** (the `orient` prompt and the skill say so) | not linked | A widget in every session; and its result holds no graph (decision 7). |
| `search` | in most memory turns | not linked | The most frequent call (decision 6). |
| `get_entities` | often | not linked | The views call it; it needs no view of its own. |
| `set_context` | at task start | not linked | It returns no graph; the view doesn't call it (decision 9). |

With this linkage a user reaches the views by asking for a graph ("show me the graph around X", "how
are X and Y connected"): the agent calls `traverse_graph` or `find_shortest_path`, and the host opens the view.

A view can call any tool whose visibility includes `"app"`, linked or not, so the view can still call `search`,
`get_entities` and `get_context`.

### One document or two

Because a view opens only from a linked tool call and can't load another view, a search view that no tool links
to would be unreachable. The two ways to keep decision 5 were:

- **One document, two modes (chosen, decision 6).** A single `ui://graph-mem/graph` resource with a Graph mode and a
  Search mode, switched inside the page. "Show as graph" and "Search" are mode switches, not navigation. Cytoscape
  is inlined once.
- **Two documents (not chosen).** `ui://graph-mem/graph` and `ui://graph-mem/search`, with `search` linked to
  the second. Each document is self-contained, so "Show as graph" in the search view needs Cytoscape inlined
  there too (two ~430 KB documents), and a search widget opens on most memory turns.


### Graph mode

On `ui/notifications/tool-result` the view draws that result:

- `traverse_graph` → `{ entities, relations, traversal }` and `find_shortest_path` →
  `{ found, hop_count, direction, entities, relations }` map straight to nodes and edges. `found: false` shows
  "no path" instead of an empty canvas.
- A result with no entities (an empty neighbourhood) shows the two buttons below instead of an empty canvas.

**Loading a subset (decision 3).** Two buttons, "Context project" and "Root entities", start these loads; the
first calls `get_context`. `search` can't select a project's members or the root entities without a
query: catalog mode refuses `project_id` and `entity_types` (`app/services/graph_search.rb:70-71`, "project_id and
entity_types require a query"), and it returns only `entity_id`, `name`, `entity_type`. So:

1. **Context project** (`get_context` returns `status: "context_active"`; `context_cleared` and `no_context` have
   no project):
   `traverse_graph(start_entity_id: <project>, direction: "incoming", relation_types: ["part_of"], max_depth: 5,
   max_entities: 1000)` returns the members and their `part_of` edges. The other edges between them come from
   `get_entities(entity_ids:, relations: "internal")`, in batches (below).
2. **No context: root entities.** Explore picks `entity_type IN ("Project", NULL)`
   (`app/controllers/api/v1/graph_data_controller.rb:66-70`). Through existing tools: page the unfiltered catalog
   (`search` with no arguments but `page` and `per_page: 100`) and keep the `Project` and untyped rows in the
   view, then `get_entities(relations: "internal")` for their edges. This shows the same entities as Explore,
   untyped ones included, at one call per 100 entities of the whole graph. The view stops after 20 pages (2,000
   entities scanned) and says "scanned N of `total_entities`" when it stopped early (decision 8). The loader is
   one function, so a later `search` change can replace it.
3. **Caps:** 1,000 nodes for a project subset (`GraphTraversalService::MAX_ENTITIES`; Explore's
   `GraphDataController::MAX_NODES` is 2,000), with a "showing N of `scope_entity_count`" note from `get_context`.

**`get_entities` batches.** The tool has no cap on `entity_ids` and returns every active observation of each
entity. The view sends at most 100 ids per call with `relations: "all"`, dedupes the edges by `relation_id` and
keeps only those whose two ends are both in the loaded set (`relations: "internal"` keeps only the edges inside one
call, so edges between two batches would be lost). It passes `observation_limit: 1`: 0 or less means no limit
(`app/services/observation_ranking_service.rb:21`). It loads full observations only for the node the user clicks.

**The adapter** builds Cytoscape elements with the keys `GRAPH_STYLES` reads, as
`graph_data_controller.rb:138-170` does: `data.label`, `data.type`, `data.is_focus`. The existing style selector
is `node[is_focus="true"]` while the controller sends a boolean; step B checks which value the selector matches
and the adapter writes that one.

**Interaction:** click a node → `get_entities` for its details in a side panel (observations, relations); a depth
1/2 "expand" → `traverse_graph`; "path between two selected nodes" → `find_shortest_path`. The selection goes to
`ui/update-model-context` as a short text plus ids, so the next agent turn knows what the user is looking at. No
write tool is ever called; there is no edit control in the DOM. The view asks for `fullscreen` on a button, sends
`ui/notifications/size-changed`, and answers `ui/resource-teardown`.

**Scoping (decisions 2 and 9).** "Show this project" is **view state**: the view runs the project load for that
project and calls nothing that changes server state. v1 has no `set_context` control, for two reasons:

- the host proxies the view's calls over the agent's own connection, so `set_context` would change **the agent's**
  active project (`app/tools/set_context_tool.rb:44`), which boosts `search` and scopes name → id resolution;
- clients that send no `X-MCP-Client` header, and every stdio client, share the `"default"` context, which is also
  the ambient boost for callers without a context of their own. A click there would affect other clients.

The view puts the shown project in `ui/update-model-context`, so a user who wants it as the active project asks
the agent, and the agent's `set_context` call is visible in the chat. A "Set as active project" button can come
in a later release.

### Search mode

A query box, the filters `search` takes with a query (project, entity types, match-in name/type/aliases/
observations, perspective `world`/`experience`), paging, and a hit list built from `search`'s `structuredContent`
(`entity_id`, `name`, `entity_type`, `project_id`, `description`, `aliases`, `relevance_score`,
`matched_fields`). Summary-mode pagination has no total (`per_page` and `current_page` only), so the pager is
"previous / next", with "next" disabled when a page comes back short. Clicking a hit calls `get_entities`; "Show
as graph" switches to Graph mode with the hits' ids. The current query goes to `ui/update-model-context`.

### Rendering and packaging

- **Reuse:** `GRAPH_STYLES` and `LAYOUT_OPTIONS` from `app/javascript/graph/cytoscape_config.js` and the vendored
  Cytoscape 3.31.4. The layouts Explore uses (`cose`, `breadthfirst`, `concentric`, `grid`) are built into
  Cytoscape, so no layout extension is inlined. `app/assets/stylesheets/graph.css` has a single graph rule
  (`.cytoscape-container`, line 7); the view writes its own few rules instead. **Don't reuse**
  `explore_controller.js` (Stimulus, Turbo, history, edit dialogs, drag-drop edits) or `api_client.js`
  (`fetch('/api/v1/graph_data')`): neither works under `connect-src 'none'`, and both carry edit paths.
- **Inline everything; no CDN, no `csp` domains.** The HTML builder writes one `<script type="module">` holding,
  in order: Cytoscape, the config, the view code. There is no importmap inside the iframe, so the sources are
  concatenated and their module syntax removed:
  - `vendor/javascript/cytoscape.js-3.31.4-dist/cytoscape.esm.min.mjs` (416,235 bytes) has no `import`, no
    `</script` and no `fetch(`, and ends with `export{Ah as default};` plus a newline. The builder rewrites that
    exact trailer to a local binding. A spec pins the trailer, so a Cytoscape bump fails loudly instead of
    shipping a broken view.
  - `cytoscape_config.js` has no imports and two `export const`. `LAYOUT_OPTIONS` holds a function, so it can't
    travel as JSON: the builder inlines the file's source with `export ` stripped. A spec pins that too.
  - Cytoscape contains one `Function("return this")()` fallback, reached only when `self` is missing. Step B
    checks the browser console for CSP violations.
  - No second copy of any file is committed; the HTML is built once per process (memoized).
- **Where the files live:** the view JS, CSS and HTML shell under `lib/graph_mem/mcp_apps/` (for example
  `lib/graph_mem/mcp_apps/view/`). **Not under `app/javascript/`:** importmap-rails adds that folder to
  Propshaft's paths, so the files would be served publicly at `/assets/…`. **Not under `app/views/`:** the shell
  carries an inline script by design, and `spec/inline_scripts_spec.rb` forbids those there.
- **A view-source spec** (new, step A) replaces what the guard specs would not catch
  (`spec/javascript_sinks_spec.rb` scans only `app/javascript/**/*.js`, and only for interpolated `innerHTML`
  template literals). It fails on any `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval(`,
  `new Function`, `fetch(`, `XMLHttpRequest`, `WebSocket`, or `http:`/`https:` URL in the view sources. Text is
  rendered with `textContent`.
- `_meta.ui`: `prefersBorder: true`, no `csp` (the restrictive default), no `permissions`, no `domain`.
- **Theming:** read `hostContext.styles.variables` and `theme`, with fallbacks in `:root`, and use the host's font
  variables or system fonts. (The operator UI's own theme switch stays a separate backlog item.)
- **Size:** about 430 KB for the document. Record in the PR that both transports (Streamable HTTP and stdio)
  deliver it, and whether Claude and Cursor accept it.

### Lockdown, privacy, cloud gate

- `AccessGate` already wraps every `/mcp` path; `resources/read` and the view's proxied `tools/call` use the same
  session and token. No new route, no new asset path, no allowlist change. Stdio has no gate, as today.
- The templates are static: no graph data, settings, paths or hostnames are baked into the HTML. Facts reach the
  view only in tool results, which the host already receives today.
- The anonymizer and `cloud_allowed` govern graph_mem's own LLM calls; this train makes none and changes none. A
  search from the view calls the embedding provider, exactly as an agent's `search` does.
- **View calls are recorded as the agent's calls.** Each one goes through `ApplicationTool`'s wrapper, so it writes
  `ToolTelemetry` and `AgentContext.record_activity!` (`app/tools/application_tool.rb:122`, `:259`). Telemetry
  will count UI clicks together with agent calls; the user guide says so.
- A host may put the `content` text of a view-initiated call into the model's context. The batches and
  `observation_limit` above keep those results small.

## Steps (one PR each)

Versions follow 1.84.0. Each PR keeps the default `/mcp` at 12 tools, unchanged tool schemas and results, the
operator Explore and Search pages untouched, and its own CHANGELOG entry and docs. Branches are `claude/<topic>`.

### A. Generic resource layer, Apps capability, stub view → 1.85.0

- Providers as above; `TemplateResourceProvider` first, in its own commit, with no output change (snapshots
  identical).
- Declare the extension (plain-hash `extensions:` key); register the `ui://` resource on all three profiles;
  add `_meta.ui.resourceUri` to `traverse_graph` and `find_shortest_path` through `ToolWrapper`: a
  per-tool `mcp_ui_view` setting on `ApplicationTool`, next to `title` (`app/tools/application_tool.rb:57-63`),
  empty by default, applied with `MCP::Apps.tool_meta` only when the server registers that view.
- The `mcp_apps_enabled` setting (decision 12), with a spec that the wire is today's when it is off.
- Stub HTML: the `ui/initialize` handshake, a title, the tool result's entity count, the teardown reply.
- Specs:
  - `initialize` carries the extension, and the rest of the capabilities are unchanged;
  - `tools/list` has `_meta.ui` on exactly the linked tools and nothing else changed;
  - `resources/list` lists the view on the chosen profiles and nowhere else (snapshot spec, extended);
  - `resources/read` for the `ui://` URI returns the MIME type, a full HTML document and `_meta.ui` on the content
    item; an unknown URI still raises not-found; the templated resources read as before;
  - a linked tool never points at a view its server doesn't register (per profile, and with the setting off);
  - the view-source spec;
  - `tools/call` results are byte-identical with and without the extension declared by the client.
- Re-record the snapshots by replacing only the changed entries in place (keep the recorded order, so the diff
  stays small); add the handshake expectation; `docs/mcp_tools.md` and `docs/protocol_compat.md` get a
  short MCP Apps section.
- Manual check, recorded in the PR: the stub renders in Claude (first, because of ext-apps #671) and in Cursor
  (global server entry) when the agent calls a linked tool; the view's own `tools/call` to an unlinked tool
  (`get_entities`) works, and whether the host asks for consent.

### B. Graph mode → 1.86.0

- The bridge helper, the HTML builder with inlined Cytoscape and config (trailer and `export` rewrites, with their
  specs), the result → elements adapter for `traverse_graph`, `find_shortest_path`, `get_entities` and catalog
  results, the two subset loads (decision 3), the node panel, expand, path, local scoping, model-context updates,
  host theming, fullscreen. A spec checks that the view sources name no tool but the five the view may call.
- Specs: there is no JS test runner in the repo (no `package.json`), so the adapter is tested in the browser. The
  system-spec setup has headless Chrome (`spec/support/system.rb`). A system spec writes the built HTML to a
  temporary file, opens it inside a small stub-host page that plays the `postMessage` protocol with envelopes
  recorded from the real tools in the test DB (synthetic entities only), and checks the drawn node and edge
  counts and the absence of console errors. If headless Chrome can't load a local file that way without a new
  route, a gem or a package, stop there and do a manual check instead; say so in the PR.

### C. Search mode, docs → 1.87.0

- Search mode (filters, paging, click-through, "Show as graph"), the user guide page under `docs/guides/` (what
  the views do, how to open them, which clients render them, the Cursor global-entry note, that view calls count
  as agent calls), the README feature line.
- Manual check on Claude and Cursor, recorded in `docs/protocol_compat.md`.
- Housekeeping: mark this plan DONE, move it to `docs/plans/done/` and add its row to
  `docs/plans/done/README.md`.

### Release (each step)

`lib/graph_mem/version.rb`, then `bin/rails graph_mem:sync_skill_version` (SKILL.md line 18 and the README badge;
`spec/docs/agent_text_sync_spec.rb` compares them), then the CHANGELOG entry under the new version. Don't edit
`version.rb` or SKILL.md while the full suite is running.

## Compat verification (each step)

As in `docs/plans/done/mcp-sdk-1.9.0-plan.md`:

- `ruby script/mcp_compat/compare.rb`: 0 failed expectations, 0 unexpected differences. graph_mem will now declare
  an extension the reference servers don't. Step A checks how `compare.rb` reports that, records it as a
  `divergence` in the handshake cases and in `docs/protocol_compat.md`, and changes `compare.rb` only if it can't
  express it (ask Steve first).
- `script/mcp_compat/clients.sh <url>`: every row OK, same row count as before the step.
- `script/mcp_compat/claude_client_check.rb`: passes (Claude Code ignores the extension).

## Acceptance criteria

- Tool counts stay 12 / 9 / 22 (`spec/lib/graph_mem/mcp_tool_registry_spec.rb`); the snapshot diff holds only
  `_meta` on the linked tools and the `resources/list` block.
- `tools/call` text and `structuredContent` are identical before and after, for every tool.
- No new route, asset path, gem, package or migration; `Gemfile.lock` and `db/structure.sql` are untouched.
- The view sources pass the view-source spec; no guard spec gains an exemption.
- The full suite is green on CI (CircleCI rspec, rubocop, brakeman; Actions lint, scan_ruby, scan_js).
- No real hostnames, IPs, usernames or home paths in docs or fixtures. Synthetic data only.
- The manual checks are recorded in each PR with the client name and build.

## Size

Rough estimates, to be corrected in each PR: A about 700 changed lines (half of it specs and re-recorded
snapshots), B about 1,500, C about 900. **Stop and ask Steve if a PR's diff grows past ~3,000 lines.**

## Open questions for Steve

None. Decisions 6–13 answered the eight questions the review raised.
