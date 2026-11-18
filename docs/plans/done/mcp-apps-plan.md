# MCP Apps → graph_mem 1.87.0–1.89.0: a graph view and a search view inside the chat

**✅ DONE:** shipped as **1.87.0–1.89.0** in three PRs: step A (the generic resource layer, the Apps capability,
the stub view) in #176 as 1.87.0; step B (Graph mode) in #177 as 1.88.0; step C (Search mode, the user guide
[`docs/guides/mcp-apps-views.md`](../../guides/mcp-apps-views.md)) in #178 as 1.89.0. Manual checks on Cursor are
recorded in each PR and in `docs/protocol_compat.md`; the Claude check stayed deferred.

The plan as it stood when step C started follows. It was written from `main` at `30beb6f` (1.84.0) and **reviewed at
`9df8556`** against three sources: this repo's code, the installed `mcp` 1.9.0 gem source, and the live spec (stable 2026-01-26 and the
draft). The review changed the first-load design, the tool linkage and the view packaging, and added the sections
from "Acceptance criteria" on; "What the review changed" lists the differences. Steve answered every open question
on 2026-11-12 (decisions 6–13). The train is 1.87.0–1.89.0 on top of 1.86.2. File:line references were checked
again at `862210d` (1.87.0) and, for step C, at `e7bebb5` (1.88.0), and the gem facts against the installed
`mcp` 1.10.0; the sections "The Ruby `mcp` gem" and "What changes on the wire" describe the 1.86.2 starting point that step A changed (see "A. … shipped").

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
- **Any new gem, a gem bump (such as an `mcp` bump past 1.10.0), a migration, or any non-stdlib package** (npm
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
  as `structuredContent` (`lib/graph_mem/official_mcp/tool_wrapper.rb:90-91`), so the model sees the same data
  either way.
- **Size:** neither the spec nor the docs set a limit for the HTML resource. The SDK docs note that some hosts
  limit tool-result sizes.

### Client support

- **Claude (web and Desktop):** listed on the official overview
  (<https://modelcontextprotocol.io/extensions/apps/overview>). Claude's 2026-11-10 update moves interactive
  connectors to a side panel or fullscreen and puts more of the extension (app tools) in public preview; not on
  Claude Mobile. A remote graph_mem still needs the usual reachable MCP endpoint (and a token off loopback); the view
  itself opens no connection. ext-apps issue #671 (open) reports Claude fetching a resource without rendering the
  iframe. **The Claude check is deferred** (Steve, 2026-11-17): only Linux workstations are available, Claude
  Desktop has no Linux build, and serving claude.ai over public HTTPS is not an option. **Cursor is the reference
  host** for this train's manual checks.
- **Cursor:** its docs mark "Apps (extension)" as Supported (<https://cursor.com/docs/mcp>), since Cursor 2.6.
  Known issues in the forum: inline widgets stopped mounting for some sessions around 3.9.16 (fixed in 3.12), and
  servers configured in a project's `.cursor/mcp.json` never get their `ui://` resource read, while the same server
  in the global (user-level) `mcp.json` works. Test with a global entry on a current build.
- **Also listed:** VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam, Archestra.AI on the
  overview; ChatGPT, PostHog Code, Kiro Crew and Glean in the client matrix; MCP Inspector as partial.
- **Claude Code** is in the matrix without Apps support. It and other CLIs keep the text result.
- **Step A's manual check (1.87.0, recorded in #176):**
  - **Cursor 3.23.23** (global entry, HTTP on loopback): the stub rendered inline after `traverse_graph` and
    after `find_shortest_path`. The view's own `get_entities` ran **without a consent prompt** and its result
    **did not reach the model's context**. Cursor rendered a view **once per chat** (or once per `resourceUri`):
    a later linked call in the same chat showed no view.
  - **Devin Desktop 3.13.4:** no view; the tool results arrived as plain text, as before 1.87.0.
  - **Claude: deferred** (Steve, 2026-11-17; see the Claude bullet above). Not part of this train's manual checks.
- **Step B's manual check (1.88.0, recorded in #177):** Cursor 3.23.23 (global entry, a new chat per call) drew
  every `traverse_graph` mode and both `find_shortest_path` outcomes; the panel, expand, path and "Show this
  project" worked; both subset buttons loaded with no tool result. The ~464 KB document was accepted. No consent
  prompt for the agent's calls or the view's own. Theme switches recolour the open view. Cursor offers no
  `fullscreen` display mode, so that button stays hidden. **Cursor apparently doesn't pass
  `ui/update-model-context` to the model:** asked what the view showed, the agent knew only its own tool result.

## The Ruby `mcp` gem

graph_mem pins `gem "mcp", "1.10.0"` (`Gemfile:36`) since 1.86.1 (`docs/plans/done/mcp-sdk-1.10.0-plan.md`). Nothing
in 1.10.0 is for Apps or resources (it brought `Mcp-Param-*` header validation, OAuth `issuer:`, stdio env and SSE
hardening). A further bump stays its own "one PR per upgrade" change and is a hard stop.

What **1.9.0 and 1.10.0 have** (`lib/mcp/apps.rb` is identical in both tags; read in the installed gem):

- `MCP::Apps` (`lib/mcp/apps.rb`, autoloaded): `EXTENSION_ID`, `RESOURCE_MIME_TYPE`, `URI_SCHEME`, and
  - `Apps.capability` → `{ "io.modelcontextprotocol/ui" => { mimeTypes: [...] } }`;
  - `Apps.ui_resource(uri:, name:, **rest)`: refuses a non-`ui://` URI and returns an `MCP::Resource` **instance**
    for the listing. It takes `title`, `description`, `meta` and the other `Resource` fields; there are no
    `csp`, `permissions` or `prefers_border` keywords, so the `ui` hash is written by hand inside `meta:`;
  - `Apps.tool_meta(resource_uri:, visibility: nil, meta: nil, legacy: false)`: returns
    `{ ui: { resourceUri: uri } }` with **Symbol keys** (use the default `legacy: false`, decision 4);
  - `Apps.client_supports?(client_capabilities)`.
- **Capability declaration:** `MCP::Server.new(capabilities:)` stores a plain Hash unchanged
  (`lib/mcp/server.rb:1691-1697`), so `CAPABILITIES.merge(extensions: MCP::Apps.capability)` is serialized as
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
- Also in 1.9.0 and later, not used here: the Skills extension (SEP-2640, `MCP::Skill`), relevant only to a later
  Skills over MCP decision.

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
  adapter, inlining Cytoscape): nothing in the gem covers it, by design; it is host-side protocol. The bridge's
  message checks are under "Rendering and packaging".

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
  (`spec/fixtures/mcp/snapshots/{default,readonly,maintenance}.json`) by hand, as `docs/development.md:128`
  describes. The diff must show only `_meta` on the linked tools and the new `resources/list` block.
- The handshake fixtures (`spec/fixtures/mcp/handshakes/{http,stdio}.json`) are hand-written expectations matched
  by subset (`script/mcp_compat/handshake_cases.rb`), not recordings. An added `extensions` key passes them
  unchanged. Step A adds an expectation for it instead of re-recording anything.
- Three checks compare the served capabilities with `CAPABILITIES.deep_stringify_keys`
  (`spec/requests/mcp_official_spec.rb:66`, `spec/integration/mcp_structured_output_stdio_spec.rb:77`,
  `script/mcp_compat/claude_client_check.rb:249`). With an on/off setting, one of its two states can't equal a
  constant. So `CAPABILITIES` stays today's base, and one new method, `ServerFactory.capabilities(apps_enabled:)`,
  returns the base or the base plus `extensions:`. The server and the three checks all call it, and step A adds
  an example for each state.

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
text (`spec/services/settings_schema_spec.rb` requires both). No migration. Servers are built once per
transport, so a change has to rebuild them:

- **HTTP:** saving a changed `mcp_apps_enabled` in System › Settings calls
  `GraphMem::OfficialMcp.refresh_access!(transports: true)`, the call a change of the allowed hosts or origins
  already makes (`app/controllers/concerns/mcp_access_settings.rb:51`). That call runs only for the allowlist
  keys today, so this is a small new hook: in `SettingsGroupUpdate#write_settings`
  (`app/controllers/concerns/settings_group_update.rb:35-44`), next to `apply_mcp_access_changes`, read the value
  before and after the save and call `refresh_access!(transports: true)` only when it changed. Restoring a
  backup is already covered (`app/controllers/system/backups_controller.rb:45`). The refresh closes the open MCP
  sessions, and the help text says so. Like that call it is in-process only: with several Puma workers the
  others pick the change up at their next restart (`lib/graph_mem/official_mcp.rb:44-45`).
- **Stdio:** the runner builds its server once at boot, so the change needs a restart of the runner. The help
  text says that too.
- A Solid Queue worker never serves MCP and needs nothing.

With the setting off, the server declares no extension, links no tool and lists no `ui://` resource:
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

- `find_shortest_path` → `{ found, hop_count, direction, entities, relations }` maps straight to nodes and
  edges. `found: false` shows "no path" instead of an empty canvas.
- `traverse_graph` has two modes, and the host opens the view for both:
  - **Expansion** (`start_entity_id` alone) → `{ entities, relations, traversal }`, straight to nodes and edges.
    `include` can leave either key out (`traverse_graph_tool.rb:111-118`): without `entities` the view treats
    the result as relations-only, without `relations` it draws the nodes alone, and `include: ["traversal"]`
    falls under the "neither" case below.
  - **Relation query** (no `start_entity_id`, or `from_entity_id`/`to_entity_id`;
    `app/tools/traverse_graph_tool.rb:44-52`, `:87-109`) → **relations only** by default, with ids and no names,
    and **no limit** (`app/services/relation_query_service.rb:32-41`): `traverse_graph({})` returns every relation
    in the graph. The view loads the relations' endpoints with batched `get_entities` (below) before drawing.
- **Draw cap, for any result:** 2,000 nodes (Explore's `MAX_NODES`) and 5,000 edges, with a "showing N of M"
  note. For a relations-only result the view keeps the first relations until either cap is reached and loads
  only their endpoints. The edge cap is a first value; step B adjusts it to what Cytoscape draws smoothly.
- A result with neither entities nor relations shows the two buttons below instead of an empty canvas.

**Loading a subset (decision 3).** Two buttons, "Context project" and "Root entities", start these loads; the
first calls `get_context`. `search` can't select a project's members or the root entities without a
query: catalog mode refuses `project_id` and `entity_types` (`app/services/graph_search.rb:70-71`, "project_id and
entity_types require a query"), and it returns only `entity_id`, `name`, `entity_type`. So:

1. **Context project** (`get_context` returns `status: "context_active"`; `context_cleared` and `no_context` have
   no project):
   `traverse_graph(start_entity_id: <project>, direction: "incoming", relation_types: ["part_of"], max_depth: 5,
   max_entities: 1000)` returns the members and their `part_of` edges. The other edges between them come from
   batched `get_entities(entity_ids:)` calls (below).
2. **No context: root entities.** Explore picks `entity_type IN ("Project", NULL)`
   (`app/controllers/api/v1/graph_data_controller.rb:66-70`). Through existing tools: page the unfiltered catalog
   (`search` with no arguments but `page` and `per_page: 100`) and keep the `Project` and untyped rows in the
   view, then batched `get_entities` (below) for their edges. This shows the same entities as Explore,
   untyped ones included, at one call per 100 entities of the whole graph. The view stops after 20 pages (2,000
   entities scanned) and says "scanned N of `total_entities`" when it stopped early (decision 8). The loader is
   one function, so a later `search` change can replace it. A full scan is up to 40 view-initiated calls (20
   catalog pages and up to 20 `get_entities` batches). A host may ask for consent on each, or add each result
   to the model's context. Steve (2026-11-17): keep this loader as long as the host shows no consent prompt
   (Cursor showed none, and the results didn't reach the model's context); stop and ask only if a host prompts
   for consent on every view call.
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
  Cytoscape, so no layout extension is inlined. `app/assets/stylesheets/graph.css` styles Explore's chrome; its
  only canvas rule is `.cytoscape-container` (line 7). The view writes its own few rules instead. **Don't reuse**
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
- **The bridge checks every message.** It has to post with target origin `*` (the view doesn't know the host's
  origin) and it listens on `window`, so:
  - it accepts a message only when `event.source === window.parent`;
  - it accepts only JSON-RPC 2.0 objects whose `id` matches a pending request, or whose `method` is one the view
    handles; everything else is ignored, not treated as an error;
  - message data reaches the DOM only through `textContent`.

  Don't copy the spec's sample `sendRequest` as is: it rejects a pending request on any unrelated message, so a
  notification arriving first would fail the call. The view-source spec checks the `event.source` test is
  present; the system spec (step B) sends a message from another source and an unknown method and checks both
  are ignored.
- `_meta.ui`: `prefersBorder: true`, no `csp` (the restrictive default), no `permissions`, no `domain`.
- **Theming:** read `hostContext.styles.variables` and `theme`, with fallbacks in `:root`, and use the host's font
  variables or system fonts. (The operator UI's own theme switch stays a separate backlog item.)
- **Size:** about 430 KB for the document (planned; 1.88.0 measured 464,379 bytes, and
  `spec/lib/graph_mem/mcp_apps/view_builder_spec.rb` keeps it under 512,000). Record in the PR that both
  transports (Streamable HTTP and stdio) deliver it, and whether Cursor accepts it.

### Lockdown, privacy, cloud gate

- `AccessGate` already wraps every `/mcp` path; `resources/read` and the view's proxied `tools/call` use the same
  session and token. No new route, no new asset path, no allowlist change. Stdio has no gate, as today.
- The templates are static: no graph data, settings, paths or hostnames are baked into the HTML. Facts reach the
  view only in tool results, which the host already receives today.
- The anonymizer and `cloud_allowed` govern graph_mem's own LLM calls; this train makes none and changes none. A
  search from the view calls the embedding provider, exactly as an agent's `search` does.
- **View calls are recorded as the agent's calls.** Each one goes through `ApplicationTool`'s wrapper, so it writes
  `ToolTelemetry` and `AgentContext.record_activity!` (`app/tools/application_tool.rb:138`, `:275`). Telemetry
  will count UI clicks together with agent calls; the user guide says so.
- A host may put the `content` text of a view-initiated call into the model's context. The batches and
  `observation_limit` above keep those results small.

## Steps (one PR each)

Versions follow 1.86.2. Each PR keeps the default `/mcp` at 12 tools, unchanged tool schemas and results, the
operator Explore and Search pages untouched, and its own CHANGELOG entry and docs. Branches are `claude/<topic>`.

### A. Generic resource layer, Apps capability, stub view → 1.87.0

**✅ Shipped in #176 as 1.87.0.** What step B builds on: `GraphMem::OfficialMcp::ResourceCatalog` over
providers (`TemplateResourceProvider`, `StaticResourceProvider`); `GraphMem::McpApps.enabled?` and
`GraphMem::McpApps::Views` (`GRAPH_URI`, `VIEWS` with the five `calls`, `provider_for`, `uris_for`; the body reads
`lib/graph_mem/mcp_apps/view/graph.html` as is); `ServerFactory.capabilities(apps_enabled:)`;
`ApplicationTool.mcp_ui_view` on `traverse_graph` and `find_shortest_path`; the `mcp_apps_enabled` setting and
its save hook; the stub's `postMessage` bridge in `graph.html` (only `window.parent`, only JSON-RPC 2.0, an
unknown request answered with `-32601`, notifications and stray replies dropped, text only via `textContent`);
`spec/lib/graph_mem/mcp_apps/view_source_spec.rb`. Its A0 ran a `bundle update` and holds `regexp_parser < 2.13.2`
(2.13.2 breaks `json_schemer` 2.5.0 at load) and `prism < 2` in the Gemfile. The manual check results are under
"Client support". The bullets below are the step as planned.

- **A0, before branching:** check that CI on `main` is green. A lockfile refresh on 2026-11-17 (`12b6408`) made
  every spec file fail to load on CI (the first load error, then `FrozenError` on the frozen autoload paths for
  each later file, because Rails re-runs `initialize!` after a failed boot); it was reverted in `6b51d75`, and
  `main` is green again with the 1.86.2 lockfile. This PR leaves `Gemfile.lock` alone; the refresh is retried in
  its own commit, one gem at a time, outside this train. If `main` is red at kickoff, stop and ask.
- Providers as above; `TemplateResourceProvider` first, in its own commit, with no output change (snapshots
  identical).
- Declare the extension (plain-hash `extensions:` key, through `ServerFactory.capabilities(apps_enabled:)`);
  register the `ui://` resource on all three profiles;
  add `_meta.ui.resourceUri` to `traverse_graph` and `find_shortest_path` through `ToolWrapper`: a
  per-tool `mcp_ui_view` setting on `ApplicationTool`, next to `title` (`app/tools/application_tool.rb:57-63`),
  empty by default, applied with `MCP::Apps.tool_meta` only when the server registers that view.
- The `mcp_apps_enabled` setting (decision 12): a spec that the wire is today's when it is off, and a spec that
  saving a change rebuilds the HTTP servers and saving an unchanged value doesn't.
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
- Manual check, recorded in the PR (as planned; Claude was later deferred and Cursor became the reference host):
  the stub renders in Claude and in Cursor (global server entry) when the agent calls a linked tool; the view's own `tools/call` to an unlinked tool
  (`get_entities`) works; whether the host asks for consent on each view-initiated call, and whether those
  results reach the model's context.

### B. Graph mode → 1.88.0

**✅ Shipped in #177 as 1.88.0.** What step C builds on:
- `GraphMem::McpApps::ViewBuilder.document(shell:, scripts:)` (`lib/graph_mem/mcp_apps/view_builder.rb`) builds
  the shell `graph.html` plus one inline module script: Cytoscape (its trailer turned into `return Ah;` inside a
  function scope), `cytoscape_config.js` without its `export `s, then the view scripts listed in `Views::VIEWS`
  (`scripts:`, today `bridge.js host.js adapter.js loader.js interaction.js graph_view.js`, all under
  `lib/graph_mem/mcp_apps/view/`). A view script must not use module syntax (the builder refuses it). Built once per
  process.
- `bridge.js`: every tool call goes through `bridge.callTool(name, args)`. `host.js`: theming, fullscreen,
  `size-changed`, a debounced `ui/update-model-context`, the teardown reply. `adapter.js`: results → elements and the
  draw cap. `loader.js`: `loadEntities(ids, { onProgress, knownIds })` (batched `get_entities`), `loadProject`,
  `loadContextProject`, `loadRootEntities`. `interaction.js`: the node panel, expand, path, "Show this project".
  `graph_view.js` (about 300 lines): drawing, layout, the status and note lines, the subset buttons.
- Specs: `spec/lib/graph_mem/mcp_apps/{view_builder,view_source,views}_spec.rb`,
  `spec/mcp/mcp_apps_graph_envelopes_spec.rb` (the keys the view reads, recorded from the real tools on synthetic
  data, including the `search` catalog), `spec/system/mcp_apps_graph_view_spec.rb` (headless Chrome: a stub-host page
  in a temp file, the built document in a `sandbox="allow-scripts"` iframe under the default CSP, the view's own
  `tools/call` proxied to the readonly server).
- Explore's focus rule is now `node[?is_focus]` (the API sends a boolean); the adapter writes a boolean too.

**What step B taught (design inputs for C):**
- Cursor mounts a view once per chat, and `search` is not linked, so Search mode has to be reachable from the view's
  own controls with no tool result at all.
- Cursor showed no consent prompt for the view's calls and didn't pass `ui/update-model-context` to the model. Keep
  sending the update (other hosts may use it), but the user guide must not promise that the agent sees what the view
  shows.
- A result with nothing to draw must also reset the status line; a drawing with lone nodes needs the grid next to
  the force-laid connected part (both fixed in #177; keep them working when Search mode hands hits to Graph mode).
- The view-source spec's "names no write tool and no `set_context`" check matches comments too: don't name those
  tools anywhere in the view sources, comments included.
- The real-data screenshots from the manual check couldn't be attached. Any screenshot in the PR or the user guide
  shows synthetic data only.
- B's diff was about 1,760 lines against the 1,500 estimate, a third of it specs.

The bullets below are the step as planned.

- **B0, before branching:** CI on `main` green (if red, stop and ask), then a generic `bundle update` as its own
  first commit that keeps the Gemfile holds (`regexp_parser < 2.13.2`, `prism < 2`, `mcp` exact) and json on 3.x;
  if CI goes red on it, stop and ask instead of pinning more gems.
- **What step A taught (design inputs):**
  - **A view is not guaranteed per call.** Cursor showed a view only once per chat, so a later linked call in the
    same chat may reach no view, and the mounted view doesn't get that call's result. The view must be useful on
    its own: after `ui/initialize`, if no `ui/notifications/tool-result` arrives (or it holds nothing to draw),
    show the "Context project" and "Root entities" buttons; expand, path and the subset loads are the view's own
    calls; the drawn scope goes to `ui/update-model-context`, so the agent knows what the user sees. Don't build
    anything that needs a fresh view per agent call. The user guide (step C) says so.
  - **The view's own calls in Cursor:** no consent prompt, and their results don't reach the model's context. So
    the root loader's up-to-40 calls are usable in Cursor; keep it as long as the host shows no consent prompt
    (Steve, 2026-11-17). Stop and ask only if a host prompts for consent on every view call.
  - **The model learns what the view shows only through `ui/update-model-context`** (view results don't reach it
    in Cursor). Keep that update short: scope, counts, selected ids.
- **Build on 1.87.0, don't replace it:** keep `Views` and the provider, and swap the `graph.html` body for the
  builder's output (still built once, memoized); keep the bridge's checks and the `-32601` answer; extend
  `view_source_spec.rb` to every view source and keep its "only the five tools" check, which must find at least
  one call. The vendored Cytoscape stays in `vendor/javascript/` (not copied under `lib/graph_mem/mcp_apps/view/`,
  so the view-source spec doesn't scan it). A spec pins its size (416,235 bytes), SHA-256
  (`2815a1007610f002a3fc89a28e3172534603c9439833a4d3fa4e172576b7e2d3`) and trailer
  (`export{Ah as default};` plus a newline), so a Cytoscape change fails loudly. In it, `http:` appears only in
  license comments, `Function(` once (the `Function("return this")()` fallback) and `import` only in error text;
  a spec on the built document checks that nothing but the vendored file adds such strings.
- **No new package:** Cytoscape 3.31.4 is the already-vendored file (importmap pin in `config/importmap.rb:7`),
  inlined; no CDN, no `csp` domains, no npm package (`@modelcontextprotocol/ext-apps`, a bundler), no new gem.
  Any of those is a stop-and-ask.
- The bridge helper with its message checks, the HTML builder with inlined Cytoscape and config (trailer and
  `export` rewrites, with their specs), the result → elements adapter for `traverse_graph`,
  `find_shortest_path`, `get_entities` and catalog results, the draw cap, the two subset loads (decision 3), the
  node panel, expand, path, local scoping, model-context updates, host theming, fullscreen.
- A spec checks that the view sources name no tool but the five the view may call.
- Recorded envelopes cover each `traverse_graph` mode: expansion, relations-only and `include: ["traversal"]`.
- Specs: there is no JS test runner in the repo (no `package.json`), so the adapter is tested in the browser. The
  system-spec setup has headless Chrome (`spec/support/system.rb`). A system spec writes the built HTML to a
  temporary file, opens it inside a small stub-host page that plays the `postMessage` protocol with envelopes
  recorded from the real tools in the test DB (synthetic entities only), and checks the drawn node and edge
  counts and the absence of console errors. If headless Chrome can't load a local file that way without a new
  route, a gem or a package, stop there and do a manual check instead; say so in the PR.
- Manual check, recorded in the PR: Cursor (global entry, current build) draws each `traverse_graph` mode and a
  path, the two subset buttons work with no tool result, and the document size (about 430 KB; 464,379 bytes as
  shipped) is accepted over both transports. Cursor is the reference host; the Claude check is deferred.

### C. Search mode, docs → 1.89.0

**✅ Shipped in #178 as 1.89.0.** The bullets below are the step as planned.

- **C0, before branching:** as B0 (CI on `main` green, then a generic `bundle update` as its own first commit that
  keeps the Gemfile holds and json on 3.x; stop and ask if CI goes red on it).
- **Search mode** (see "Search mode" above): a mode switch in `graph.html` ("Graph" / "Search"), reachable with no
  tool result. Its code goes in a new view script (for example `lib/graph_mem/mcp_apps/view/search_view.js`) added
  to `Views::VIEWS`' `scripts:`, so `graph_view.js` and every file stay under 500 lines. It calls only `search` and
  `get_entities`, both already in the view's five `calls`; `Views` and the builder need no other change.
  - A query is required (catalog mode refuses filters, decision 8; no change to `search`). Filters are the ones
    `search` takes with a query: `project_id`, `entity_types`, `search_in_name`/`_type`/`_aliases`/`_observations`,
    `perspective`. The project filter offers projects the view already knows (the context project from
    `get_context`, `Project` entities already loaded); it starts no catalog scan of its own.
  - Hits come from summary mode's `results` (`entity_id`, `name`, `entity_type`, `project_id`, `description`,
    `aliases`, `relevance_score`, `matched_fields`; `app/strategies/hybrid_search_strategy.rb` `SearchResult#to_h`).
    `pagination` has only `current_page` and `per_page`, so the pager is previous / next, with next disabled on a
    short page.
  - Clicking a hit opens the details with one `get_entities` call (full observations, that entity only), reusing
    the node panel (`interaction.js` `showDetails(id)`, which reads type and aliases from `state.entities`, so a hit
    that isn't drawn needs its summary passed in). "Show as graph" switches to Graph mode and draws the hits through
    `loadEntities` (batched, `observation_limit: 1`).
  - The query and filters go to `ui/update-model-context` as short text.
- **Specs:** the view-source spec covers the new script (no new exemption); `mcp_apps_graph_envelopes_spec.rb` (or a
  sibling) records `search` summary pages with a query and filters on synthetic data (no outbound HTTP:
  `spec/support/outbound_http_guard.rb`; `EmbeddingHelper` for embeddings if a spec needs them); the system spec
  (extend `mcp_apps_graph_view_spec.rb` or add a sibling) checks the switch with no tool result, a query, a filter,
  paging (next disabled on a short page), a hit's panel, "Show as graph" counts, the model-context update and no
  console errors. The document stays under 512,000 bytes.
- **Docs:** the user guide page under `docs/guides/` (what the views do, how to open them, which clients render them,
  the Cursor global-entry note and its once-per-chat mounting, that view calls count as agent calls in telemetry and
  `AgentContext` activity, that the agent may not see what the view shows), linked from the README (feature line and
  docs list) and from `docs/mcp_tools.md`. `docs/mcp_tools.md` and `docs/protocol_compat.md` describe Search mode;
  the host table in `docs/protocol_compat.md` gets the 1.88.0 and 1.89.0 Cursor checks.
- Manual check on Cursor (the reference host), recorded in the PR and in `docs/protocol_compat.md`; the Claude check
  stays deferred unless Steve gets a supported Claude client.
- Housekeeping: mark this plan DONE, move it to `docs/plans/done/` (`git mv`) and add its row to
  `docs/plans/done/README.md` (MCP Apps views, 1.87.0–1.89.0). Point the two live references at the new path:
  `lib/graph_mem/mcp_apps.rb` (module comment) and `docs/protocol_compat.md` ("MCP Apps" section). References inside
  other done plans stay as written (that folder's README says so).

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
snapshots), B about 1,500 (shipped at about 1,760), C about 900. **Stop and ask Steve if a PR's diff grows past
~3,000 lines.**

## Open questions for Steve

None. Decisions 6–13 answered the eight questions the review raised.
