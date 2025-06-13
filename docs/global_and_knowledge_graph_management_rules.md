Follow these steps for EACH interaction:

# Knowledge Graph Management (`graph_mem` set of tools)

`graph_mem` aliases: "knowledge graph", "graph mem", "memory graph", "graph memory" or "graph database". These names refer all to the same set of MCP tools.

Use `graph_mem` in each chat session to retrieve and store key information about projects, issues, solutions, and any other relevant facts you could use in future interactions.

## Session Initialization

- Always start conversations with "Remembering..." followed by searching for existing relevant information in the knowledge graph.
- If no relevant information is found, create initial entities for the current session context (e.g., a `Project` entity if starting work on a new project, or a `Task` entity for a new request).
- Use specific, concise queries when searching. Examples of effective search queries:
  - "AdminHub" (instead of "AdminHub project")
  - "Rails" (instead of "Rails framework")
  - "authentication" (instead of "user authentication system")

## Data Access with Graph Memory Tools

Use the following MCP tools (from the `graph_mem` server, prefixed with `mcp0_`) for all interactions (read and write) with the knowledge graph:

- **Entities:**
    - To find entities: `mcp0_search_entities` (for querying by name), `mcp0_list_entities` (to get a paginated list).
    - To retrieve a specific entity: `mcp0_get_entity` (includes its observations and relations).
    - To create an entity: `mcp0_create_entity`.
    - To update an entity's core properties (name, type, aliases): `mcp0_update_entity`.
    - To delete an entity: `mcp0_delete_entity` (Caution: this also deletes associated observations and relations).
- **Observations:**
    - Observations are typically accessed via `mcp0_get_entity` as they are part of an entity.
    - To create an observation for an existing entity: `mcp0_create_observation`.
    - To delete an observation: `mcp0_delete_observation`.
- **Relations:**
    - Relations are typically accessed via `mcp0_get_entity`.
    - To find specific relations: `mcp0_find_relations` (filter by source/target entity or relation type).
    - To retrieve a subgraph of multiple entities and their interrelations: `mcp0_get_subgraph_by_ids`.
    - To create a relation: `mcp0_create_relation`.
    - To delete a relation: `mcp0_delete_relation`.
- **General Search:**
    - `mcp0_search_subgraph`: Searches a query across entity names, types, and observations, returning a paginated subgraph of matching entities (with observations) and relations exclusively between them.

## Information Tracking

During conversations, track information in these categories, often mapping them to specific entity types:

1.  **Project context** - Current project, framework, tech stack (map to `Project`, `Framework`/`ApplicationStack` entities).
2.  **Issues** - Problems, bugs, conflicts reported by the user (map to `Issue`, `Error` entities); these are ALWAYS related to a parent `Project`, `Goal`, or `Task`.
3.  **Goals & tasks** - Explicit requests or implied objectives (map to `Task`, `Step` entities); these are usually related to a parent `Project`.
4.  **Relationships** - Connections between entities (e.g., `depends_on`, `part_of`). Especially track relationships between `Project` entities and others.
5.  **Solution history** - Previous attempts and their outcomes (map to `PossibleSolution` entities); usually children of a `Task` or `Issue`.
6.  **User Preferences** - User-specific settings, preferred practices, or configurations (map to `Preference` entities, possibly linked to `User` or `Project`).

## Memory Management Process

1.  **Search First** - Before creating new entities, search for existing matches using tools like `mcp0_search_entities` or `mcp0_search_subgraph`.
2.  **Update or Create** - If a relevant entity exists, decide whether to modify it or add to it. Use `mcp0_update_entity` to correct or change core properties (name, type, aliases). Use `mcp0_create_observation` to add new contextual information. If no relevant entity exists, create one with `mcp0_create_entity`.
3.  **Link Entities** - Create relations (`mcp0_create_relation`) between connected concepts to build a meaningful graph structure.
4.  **Persist Details** - Add observations (`mcp0_create_observation`) to entities to capture important context, decisions, code snippets, or timestamps.

## Entity Classification Guide

Use these entity types for consistent categorization:

- `Project` - Name and path (as an observation) for clear identification. Usually the parent entity for most knowledge sub-trees. Avoid including "project" in the name itself.
- `Framework`/`ApplicationStack` - Technology stack with versions.
- `Workflow` - Common development procedures or sequences of tasks.
- `BestPractice` - Project-specific or general coding standards and conventions.
- `Task` - Track work items with details like priority and status (managed via observations or related entities).
- `Step` - Components of a `Task`, with order and completion statuses, useful for breaking down complex work.
- `Issue` - Problems, bugs, or conflicts encountered during development, with status tracking.
- `Error` - Specific error messages, stack traces, or error types (often related to an `Issue` or `Task`).
- `PossibleSolution` - Approaches tried to solve an `Issue` or complete a `Task`, with success/failure indicators and reasoning.
- `Model` - Data structures, database models, or domain objects with attributes and relations.
- `DatabaseTable` - Schema details for database tables (columns, types, indexes).
- `Class` - Code components like classes or modules, detailing methods and purpose.
- `APIEndpoint` - Interface specifications for APIs, including request/response details and HTTP methods.
- `Route` - URL endpoints, often related to `APIEndpoint` or UI `Component` navigation.
- `Component` - UI elements or reusable software modules with properties and purpose.
- `Service` - Backend services or microservices with interface definitions.
- `Configuration` - Settings, environment variables, deployment configurations, or parameters.
- `Migration` - Database schema changes, often with timestamps and versioning information.
- `TestCase` - Test scenarios, unit tests, or integration tests with expected outcomes and status.
- `Permission` - Authorization rules, access controls, roles, or capabilities.
- `User` - Name for identification (e.g., the current user you are interacting with), helpful for personalizing paths or preferences.
- `Preference` - User or project-specific preferences, often related to `Project`, `Framework`, or `User`.

## Entity Relationship Management

1.  **Connect Related Entities** - Use `mcp0_create_relation` with meaningful relation types:
    - `depends_on` - Functional dependency (e.g., `Class` depends_on `Framework`).
    - `part_of` - Compositional relationship (e.g., `Step` part_of `Task`).
    - `relates_to` - General association when other types are not specific enough.
    - `implements` - Implementation relationship (e.g., `Class` implements `APIEndpoint` specification).
    - `extends` - Inheritance or extension (e.g., `Class` extends another `Class`).
    - `solves` - Solution relationship (e.g., `PossibleSolution` solves `Issue`).
    - `configured_by` - Links an entity (e.g., `Project`, `Service`) to its `Configuration`.
    - `tested_by` - Links an entity (e.g., `Class`, `APIEndpoint`) to a `TestCase`.
    - `migrated_by` - Links a `DatabaseTable` or `Model` to a `Migration` script/entity.
    - `authorizes` - Links an entity (e.g., `User`, a role entity) to a `Permission` or an action.
    - `integrates_with` - Denotes integration with another `Service`, `APIEndpoint`, or external system.
    - `replaces` - Indicates an entity supersedes another (e.g., for deprecation or versioning).

2.  **Document with Observations** - Add context through observations (`mcp0_create_observation`):
    - Keep observations focused, specific, and factual.
    - Include timestamps (e.g., using `mcp0_get_current_time`) for chronological tracking where relevant.
    - Reference code locations (file paths, line numbers, function names) where relevant.

3.  **Structure Complex Tasks** - Break down tasks into steps:
    - Create `Step` entities with clear ordering (e.g., using an observation like "order: 1").
    - Link `Step` entities to their parent `Task` using a `part_of` relation.
    - Track completion status of `Step` entities (e.g., via an observation like "status: completed" or by linking to a `PossibleSolution` that `solves` it).

4.  **Store Extended Documentation** - For detailed information that doesn't fit well into short observations:
    - Create markdown files in the project's `/docs` or `/doc` directory (or ask the user for a suitable location if no parent `Project` context is available).
    - Store the file paths as observations on the relevant entities in the Graph Memory.

## Query Optimization for Graph Memory

- **Start Broad, Then Narrow:** Use broad terms (e.g., project name) for initial searches with `mcp0_search_entities` or `mcp0_search_subgraph`. Then use specific entity IDs obtained from results for more targeted queries with `mcp0_get_entity` or `mcp0_get_subgraph_by_ids`.
- **Prioritize Root Entities:** Search for primary entities like 'Project' names first, then explore their relationships to discover connected information.
- **Search Before Creating:** Always search for existing entities (`mcp0_search_entities`) that might match your needs before creating a new one with `mcp0_create_entity` to avoid duplicates.
- **Leverage Relationships:** Utilize entity relationships (retrieved via `mcp0_get_entity` or `mcp0_find_relations`) to navigate the graph and find related information, rather than performing multiple disconnected searches.
- **Paginate Wisely:** When using `mcp0_list_entities` or `mcp0_search_subgraph`, be mindful of pagination (page, per_page parameters) to handle large result sets efficiently.

## Implementation Recommendations

- Add linting configurations to the Graph Memory (e.g., as observations on a `Project` or `BestPractice` entity).
- Track common error patterns and their solutions (e.g., `Issue` entities linked to `PossibleSolution` entities, detailing the `Error` type).
- Document the project architecture for quick reference (e.g., `Framework` entities, `Project` entities with architecture notes as observations or linked markdown files).
- Track development environment setup steps (e.g., as `Step` entities linked to `Project` setup `Task`s).
- Document recurring issues and their permanent fixes (e.g., `Issue` entities with multiple `PossibleSolution` children, noting which solution was effective and why).
- Store code review feedback patterns for consistency (e.g., `BestPractice` entities with review criteria or common feedback points).

## For Memory Organization

- Group related entities with consistent naming.
- Whenever a parent entity context exists (usually a `Project` name), use it as a root or anchor entity node for related information.
- Use specific relation types for clearer connections.
- Keep observations concise and actionable.
- For detailed observations or documentation, use Markdown files and link their paths from the Graph Memory (see "Store Extended Documentation").

## Handling Conflicting Information

If you encounter conflicting information in the Graph Memory:
1.  **Identify & Document:** Identify the source of the conflict. Document the conflict itself as an observation on the relevant entity(ies).
2.  **Research & Resolve:** Determine the most accurate or up-to-date information. This may involve:
    - Reviewing existing observations and entity history.
    - Performing a web search if necessary.
    - Asking the user for clarification.
3.  **Update Graph Memory:** Update the Graph Memory with the resolved information. This might involve:
    - Adding new observations with the correct information and timestamps (`mcp0_create_observation`).
    - Marking outdated observations (e.g., by adding a note like "status: outdated" or, if appropriate, deleting them using `mcp0_delete_observation`).
    - Using `mcp0_update_entity` to correct core properties like an entity's name, type, or aliases.
4.  **Record Resolution:** Add an observation detailing the resolution process and outcome for future reference.
5.  **Inform User:** Inform the user about the resolution. If research was unsuccessful or requires user input, clearly state the conflict and ask for guidance.

## Ensuring Session Continuity

- **Recall at Start:** At the beginning of each new session or task, search the Graph Memory for the most recent and relevant entities and observations related to the current context (project, user, ongoing tasks).
- **Update with Outcomes:** During and at the end of a session, update entity observations with new learnings, decisions, session outcomes, and the status of tasks or issues.
- **Capture Before Ending:** Before concluding a significant interaction or task, ensure all new, relevant information (new entities, relationships, observations) is captured in the Graph Memory.
- **Reference Past Solutions:** When encountering issues similar to past ones, retrieve and reference previously stored `PossibleSolution` entities and their outcomes to inform current actions.

---

# General suggestions

- If a database schema is available (as a file or as a result of a tool call), use it as primary source of truth for the actual database structure. Rely on the schema to determine up-to-date information about the main entities relationships or prompt the user to provide the missing information.

---

# Coding pattern preferences

- Always prefer simple solutions.
- Avoid duplication of code whenever possible: check for other areas of the codebase that might already have similar code and functionality.
- Write code that takes into account the different environments: development, test and production.
- Be careful to only make changes that are requested or you are confident are well understood and related to the change being requested.
- When fixing an issue or bug, do not introduce a new pattern or technology into the tech stack without first exhausting all options for the existing implementation. And, if you do this, be sure to remove the old implementation afterwards so we don't duplicate logic.
- Keep the codebase very clean and organized.
- Avoid writing one-shot usage short scripts in files when possible, but if you need to write them, remove the used script afterwards, especially if the script is unlikely needed again (example: any one-shot installation, setup or debug scripts; not the diagnostic ones, which may be still useful in future).
- Favor refactoring when you have more than 500 lines of code in one file.
- Mocking data is only needed for tests: never mock data for development or production.
- Never add stubbing or fake data patterns to code that affects the development or production environment.

---

# Coding workflow preferences

- Focus on the areas of code relevant to the task.
- Do not touch code that is unrelated to the task.
- Write thorough tests for all major functionalities.
- Avoid making major changes to the patterns and architecture of how a feature works after it has shown to work well, unless explicitly instructed.
- Always think about what other methods and areas of code might be affected by code changes.
