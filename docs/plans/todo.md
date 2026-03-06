# GraphMem main TO-DOs:

## Architecture
- add authentication/session layer to support multiple agent session at the same time, storing possibly the session ID and the latest context set for the session; the context can be set or cleared out, but it will remain associated to the same session allowing scoped memory nodes searches

## Management UI
- improve UX: move menu outside of Cytoscape viewport: use a top-bar menu with GraphMem on top left corner and "data-manage" command list on the right; leave "root view" & "full graph" on the graph viewport; leave the search section  below the top bar, but on a single row (use a toggle switch beside the search button)
- idea: quick report on duplicated observations, so that we can clean them easily
- idea: add a statistic report page given by GetGraphStatsTool
- idea: browsable paged AuditLog report