# The graph view in the chat (MCP Apps)

Since 1.87.0 graph_mem serves an interactive view through MCP Apps, the MCP extension that lets a chat client
show a small web page next to a tool result. As of 1.89.0 the view has two modes:

- **Graph:** draws entities and relations with Explore's styles. You can open a node's details, expand around
  it, find a path, or load a project.
- **Search:** runs graph_mem's search with filters and pages through the hits. Any hit can be opened, or the
  hits drawn as a graph.

This guide covers what the view does, how it opens, which clients show it, and what it does and doesn't change.
The wire details are in [protocol_compat.md](../protocol_compat.md#mcp-apps), and the tool reference is in
[mcp_tools.md](../mcp_tools.md#mcp-apps-interactive-view).

- [How the view opens](#how-the-view-opens)
- [Which clients show it](#which-clients-show-it)
- [Using it in Cursor](#using-it-in-cursor)
- [Graph mode](#graph-mode)
- [Search mode](#search-mode)
- [What the view reads and changes](#what-the-view-reads-and-changes)
- [What the agent sees](#what-the-agent-sees)
- [Turning it off](#turning-it-off)

## How the view opens

The view opens when an agent calls `traverse_graph` or `find_shortest_path` in a client that supports MCP Apps.
Those two tools carry the view's link (`_meta.ui.resourceUri`). No other tool opens it: `search`, `get_context`
and the rest stay plain tool calls.

The view first draws the result of the call that opened it. From then on it works on its own: every button runs
the view's own read-tool calls through the client.

Clients without MCP Apps support see the same tool results as before, and nothing else changes for them.

## Which clients show it

| Client | Shows the view | Notes |
|---|---|---|
| Cursor | yes | The reference client, checked in 1.87.0 and 1.88.0. Needs a global `mcp.json` entry, and mounts one view per chat. |
| Devin Desktop | no | Plain tool results. |
| Claude Code | no | No MCP Apps support: plain tool results. |
| Claude (desktop and web) | not checked yet | Claude lists MCP Apps support. Checking it needs Claude Desktop, or a graph_mem reachable over public HTTPS. |

The builds each check used are in the host table of [protocol_compat.md](../protocol_compat.md#mcp-apps).

## Using it in Cursor

- **Use a global entry.** Add graph_mem to Cursor's global (user-level) `mcp.json`. Cursor's forum reports that
  a server in a project's `.cursor/mcp.json` never gets its `ui://` resource read. Every check here used a
  global entry.
- **One view per chat.** Cursor mounts the view for the first linked call in a chat. A later `traverse_graph` or
  `find_shortest_path` in the same chat opens no new view, and the open view doesn't get that call's result.
  Use the view's own controls instead (**Context project**, **Root entities**, the **Search** mode), or start a
  new chat for a fresh view.
- **No consent prompts.** In the checks, Cursor asked for no confirmation on the view's own calls. Their results
  stayed out of the model's context.
- Light and dark themes follow Cursor's. Cursor doesn't offer fullscreen, so the view hides that button there.

## Graph mode

- **The opening result:**
  - an expansion is drawn with the start entity's yellow focus border;
  - a relation query loads the relations' endpoints;
  - a shortest path is drawn highlighted, and "no path" when there is none.
- **A cap:** at most 2,000 entities and 5,000 relations, with a "Showing N of M" note when something was cut.
- **Context project:** draws the active project of the agent's connection: its `part_of` subtree, up to 1,000
  entities.
- **Root entities:** draws the Projects and untyped entities, as Explore's default view does.
- **Click a node** to see its observations and relations:
  - **Expand 1** or **Expand 2** adds its neighbours;
  - **Show this project** draws the project it belongs to;
  - **Path between selected** finds the shortest path between the last two nodes you clicked.
- **Fit** re-centers the drawing. Nodes without a relation are laid out in a grid next to the connected ones.

## Search mode

Click **Search** in the header, or in the empty state. It works without any tool result, so it's the way to look
something up in a chat whose view is already open. Switching modes keeps the drawing as it was.

- **A query is required.** graph_mem's search takes its filters only with a query.
- **Filters:**
  - **Project:** offers the projects the view already knows: Projects it has drawn or found, and the agent's
    context project. It doesn't scan the graph for more.
  - **Types:** a comma-separated list, such as `Task, Issue`.
  - **Perspective:** world facts, experience entries (work logs), or both.
  - **Match in:** name, type, aliases and observations, all on by default. At least one must stay on.
- **Previous / Next:** 20 hits per page. Search reports no total, so **Next** turns off when a page comes back
  short.
- **Click a hit** to open its details in the side panel. From there **Expand** and **Show this project** switch
  to Graph mode.
- **Show as graph** draws the page's hits and the relations between them in Graph mode.

A search error, such as every "Match in" box unchecked, shows in red in the status line.

## What the view reads and changes

- **Read only.** The view calls five read tools: `search`, `get_entities`, `traverse_graph`,
  `find_shortest_path` and `get_context`. It never writes to the graph.
- **It never changes the active project.** **Show this project** and the project filter only change what the
  view shows. To scope the agent's work to a project, ask the agent to set it.
- **Its calls count as the agent's calls.** The client sends them over the agent's connection, so they appear in
  tool telemetry and in that connection's agent activity (`AgentContext`), like any other call. Searches use
  the embedding provider as the agent's searches do.

## What the agent sees

The agent doesn't see the view's own results. After each change the view sends the client a one-line summary
through `ui/update-model-context`: what is drawn and its counts, or the query, filters and hit count. A client may
pass that summary to the model.

**Don't count on it.** In the 1.88.0 check, Cursor didn't pass the summary to the model. Asked what the view
showed, the agent knew only its own call's result. Tell the agent what you found, or ask it to run the search
itself.

## Turning it off

Settings › Feature flags › **MCP Apps views** (`mcp_apps_enabled`, default on). Turned off, graph_mem
declares no MCP Apps support, lists no `ui://` resource and links no tool. Clients see exactly the tools they
saw before 1.87.0.

- **HTTP:** saving the setting rebuilds the MCP servers, which closes open MCP sessions.
- **stdio:** the runner picks it up when restarted.
