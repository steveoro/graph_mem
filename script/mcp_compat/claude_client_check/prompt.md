You are checking the graph_mem MCP servers `gm-http`, `gm-ro`, `gm-maint` and `gm-stdio` from Claude Code.
Use only their MCP tools and the MCP resource tools; there is nothing else to use. Create only entities whose
names start with `McpCheck`, and delete them in step 26. Run every step in order, even after a failure. For each
step, record the key values (ids, counts, error codes and text) in `actual`, and `pass` = whether `actual` matches
`expected`. Steps 13, 16 and 25 are checked by the calling script: skip them.

Folders for the scan steps: SYNTH = `{{SYNTH}}`, OUTSIDE = `{{OUTSIDE}}`, HIDDEN = `{{HIDDEN}}`.

**gm-http (default profile)**
1. List gm-http's tools. Expected: exactly these 12: set_context, get_context, search, get_entities, summarize, rank_observations, traverse_graph, find_shortest_path, get_current_time, graph_write, graph_edit, graph_delete.
2. `get_current_time`. Expected: an ISO-8601 time and a `version` field.
3. `graph_write`: create a `Project` entity `McpCheck Synth Project` and a `Component` entity `McpCheck SynthWidget` with the observation "McpCheck probe observation 1", plus a relation SynthWidget `part_of` Project. Then send the identical write again. Expected: both ids, the observation id and the relation id returned; the second write is rejected (as a possible duplicate or a name conflict) and writes nothing.
4. `set_context` with the project id, then `get_context`. Expected: the active project is `McpCheck Synth Project`.
5. `search` "McpCheck SynthWidget", then `search` "McpCheck NullId". Expected: SynthWidget is the first hit of the first search, with no error; the second finds no entity named `McpCheck NullId`.
6. `get_entities` for the SynthWidget id. Expected: the step-3 observation.
7. `traverse_graph` from the project, depth 1. Expected: SynthWidget is reached via `part_of`.
8. `find_shortest_path` SynthWidget → Project. Expected: a path of length 1.
9. `rank_observations` for SynthWidget. Expected: a ranked list containing the step-3 observation.
10. `summarize` SynthWidget. Expected: a summary, or a clear "disabled/unavailable" message; not a crash or a stack trace.
11. `graph_edit`: change the observation text to "McpCheck probe observation 1 (edited)". Expected: success, and `get_entities` shows the new text.
12. Resources on gm-http (use the resource tools; percent-encode the space): read `memory_entities?name=McpCheck%20SynthWidget`, `memory_graph?entity_id=<project id>&depth=1&include_relations=true`, `memory_observations?memory_entity_id=<widget id>` and `memory_relations?from_entity_id=<widget id>`. Expected: each read returns JSON containing the McpCheck data, and the graph read reaches SynthWidget.

**gm-ro (readonly profile)**
14. List gm-ro's tools. Expected: exactly 9 (step 1's list without graph_write, graph_edit and graph_delete).
15. Try to use `graph_write` on gm-ro. Expected: it isn't offered (or "Tool not found"); nothing is written.

**gm-maint (maintenance profile)**
17. List gm-maint's tools. Expected: 22 = step 1's 12 plus get_graph_stats, dream_state_status, get_maintenance_reports, list_maintenance_review, apply_maintenance_review, dismiss_maintenance_review, suggest_merges, detect_contradictions, scan_project, scan_project_status.
18. `get_graph_stats` and `list_maintenance_review` (read only; don't apply or dismiss anything). Expected: numbers and a list, no error.
19. `scan_project` with `project_root: "/etc"`, `dry_run: true`. Expected: refused, error envelope with `code: "not_mounted"`.
20. `scan_project` with `project_root: HIDDEN`, `dry_run: true`. Expected: refused, `code: "denied"`.
21. `scan_project` with `project_root: OUTSIDE`, `dry_run: true`. Expected: refused, `code: "outside_filter"`, with an "add it in Settings › Project scans" hint.
22. `scan_project` with `project_root: SYNTH`, `dry_run: true`, `file_globs: ["../*"]`. Expected: refused, `code: "invalid_file_globs"`.
23. `scan_project` with `project_root: SYNTH`, `dry_run: true`, then `scan_project_status` with the returned scan_id, at once. Expected: accepted with a `scan_id`; the status is found (`pending` with phase `queued`, or later), and nothing is written to the graph.

**gm-stdio (maintenance profile over stdio)**
24. Repeat steps 17 (expect 22 tools), 2, step 5's first search, and step 19 on gm-stdio. Expected: the same results as over HTTP, the refusal included as the same JSON error envelope with `code: "not_mounted"`.

**Cleanup**
26. On gm-http: `graph_delete` SynthWidget (by id), then try `McpCheck Synth Project` (by id): refused with `code: "project_delete_needs_maintenance"`. Then on gm-maint: `graph_delete` the project (by id). Then on gm-http `set_context` with `entity_id: null` and `search` "McpCheck". Expected: widget deleted; project refused on gm-http and deleted on gm-maint; context cleared; no McpCheck entity left.

Return one entry per step you ran (1–12, 14, 15, 17–24, 26) in `steps`, and anything odd in `odd`.
