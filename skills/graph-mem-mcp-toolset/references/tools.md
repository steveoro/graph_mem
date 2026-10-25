Read `references/tools.md` when a tool call fails, when choosing entity or relation types or search parameters, when an observation needs a lifecycle change or conflicts with another, or when an older client uses alias tool names.

# graph_mem tool reference

The default `/mcp` connection omits maintenance tools. Use a separate
`/mcp/maintenance` connection only when maintenance work is required; the
`/mcp/readonly` profile exposes context and read tools only.

## Workflow Prompts

Use the server's MCP prompts instead of carrying the full procedure in every
client context:

- `orient` at session start
- `recall(topic)` before work
- `persist` before ending (not available on the readonly profile)

Successful tool responses also provide concise `next_move` guidance and a
no-context banner when orientation is required.

## MCP Tool Errors

Tool `isError` content is a JSON envelope with `category`, `retriable`, `next_move`,
and `message`, plus a `code` naming the exact reason when there is one (e.g. `scan_project`'s
`outside_filter`). Follow `next_move`. Do not retry `system_error` blindly.
graph_mem's repository documents the category table in `docs/mcp_tools.md` (Error Handling).

## Multi-Agent Context Scoping

- Context is **per-agent**, keyed by the `X-MCP-Client` header, and persisted in the DB (survives restarts).
- `set_context` affects ONLY your own client bucket; pass `entity_id: null` to clear it.
- Agents without the header share the `"default"` bucket. Set a stable `X-MCP-Client` in your MCP config when multiple agents use one instance.
- Because context persists, on Orient you may already have an active context from a prior session — always `get_context` first before assuming none.

## Standard Compatibility

graph_mem accepts both its native snake_case/ID-based parameters and the
`@modelcontextprotocol/server-memory` camelCase/name-based conventions:

- Entity references accept either `entity_id` (integer) or entity name (string).
- Traversal references (`start_entity_id`, `from_entity_id`, `to_entity_id`) also accept entity IDs or names.
- Field names accept camelCase (e.g. `entityType`) or snake_case (`entity_type`).
- `graph_write` accepts either three arrays (`entities`, `observations`, `relations`) or a single `operations` array with `type`-discriminated items.
- Observation text accepts `text_content`, `content`, or `contents` (array).
- Relation endpoints accept `from_entity_id`/`to_entity_id` (int), `from`/`to` (name), or `from_entity`/`to_entity` (name).
- Use native snake_case keys by default. Compatibility aliases are for
  interoperating clients, not a reason to mix naming styles in one request.

### Name resolution

A name argument resolves in order: context project → global namespace → a single foreign-scope candidate → `AmbiguousReference` (retry with `entity_id`). Destructive ops are name-unsafe across scopes: `graph_delete`/`graph_edit` with a bare name can hit another project's same-named entity when it's the only candidate — use `entity_id` for deletes and moves.

A `Project` root can be deleted only on the maintenance profile (`/mcp/maintenance`, or stdio with
`GRAPH_MEM_MCP_PROFILE=maintenance`), and only once no entity is scoped to it
(`code: "project_delete_needs_maintenance"` / `"project_has_members"` otherwise). Deleting it clears
every client context that pointed at it.

## Query and Type Guidance

Use the `recall` prompt for query strategy. Canonical type examples are
published as soft `graph_write` schema examples; novel types remain valid.

## Observations

- Keep observations **crisp and factual**; include timestamps and code paths where relevant.
- For longform content, write to `/docs` and store the file path as an observation.
- Keep generated summaries ephemeral unless persistence is explicitly requested.
  `summarize` always derives evidence from the current active graph and returns
  source entity/observation IDs; never treat IDs or claims emitted by an LLM as
  authoritative.
- The deterministic evidence path is authoritative and always available.
  LLM synthesis is optional; provider failure, missing configuration, or a
  disabled feature must degrade to deterministic output without exposing
  credentials or internal exception details.

## Conflict Handling

1. Note the conflict as an observation on the relevant entity.
2. Research (graph history / web / user) to resolve.
3. Update the graph: new observations, mark outdated ones, edit entity if needed.
4. Record the resolution; inform the user if open questions remain.
