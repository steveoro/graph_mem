# Knowledge Graph Management

Use your Graph Memory to store and retrieve information about projects, issues, and solutions.

## Data Access Hierarchy

1. **PREFERRED: Use MCP Resources First** - When available, always prioritize MCP resources over direct tools:
   - `memory_entities` - Access entities with filtering, sorting, and optional inclusion of related data
   - `memory_observations` - Query observations with text search and optional entity inclusion
   - `memory_relations` - Explore relationships with bidirectional entity inclusion

2. **FALLBACK: Use Graph Memory Tools** - Only use these tools when MCP resources aren't available:
   - For entities: `mcp1_search_entities`, `mcp1_get_entity`, `mcp1_list_entities`
   - For observations: Use entity tools with relevant observations included
   - For relations: `mcp1_find_relations`, `mcp1_get_subgraph_by_ids`

## Session Initialization

- Always start conversations with "Remembering..." followed by retrieving relevant information
- Use concise, targeted queries rather than broad searches
- Refer to the storage as "Graph Memory" or "Memory Graph"

## Information Tracking

During conversations, monitor for information in these categories:

1. **Project context** - Current project, framework, tech stack
2. **Issues** - Problems, bugs, conflicts reported by the user
3. **Goals & tasks** - Explicit requests or implied objectives
4. **Relationships** - Connections between entities (depends_on, part_of, etc.)
5. **Solution history** - Previous attempts and their outcomes

## Memory Management Process

1. **Search First** - Before creating new entities, search for existing matches
2. **Update or Create** - Update existing entities or create new ones as needed
3. **Link Entities** - Create relations between connected concepts
4. **Persist Details** - Add observations to capture important information

## Entity Classification Guide

Use these entity types for consistent categorization:

- `Project` - Name and path for clear identification
- `Framework`/`ApplicationStack` - Technology stack with versions
- `Workflow` - Common development procedures
- `BestPractice` - Project-specific code standards
- `Task` - Track work items with priority and status
- `Step` - Task components with order and completion statuses (like we would do for a to-do list)
- `Issue` - Problems during development with status tracking
- `PossibleSolution` - Approaches tried with success/failure indicators
- `Model` - Data structures with attributes and relations
- `DatabaseTable` - Schema details (columns, types, indexes)
- `Class` - Code components with methods and purpose
- `APIEndpoint` - Interface specifications with request/response details
- `Component` - UI elements with props and purpose
- `Service` - Backend services with interface definitions

## Entity Relationship Management

1. **Connect Related Entities** - Use `create_relation` (or MCP resource) with meaningful relation types:
   - `depends_on` - Functional dependency
   - `part_of` - Compositional relationship
   - `relates_to` - General association
   - `implements` - Implementation relationship
   - `extends` - Inheritance or extension
   - `solves` - Solution relationship

2. **Document with Observations** - Add context through observations:
   - Keep observations focused and specific
   - Include timestamps for chronological tracking
   - Reference code locations where relevant

3. **Structure Complex Tasks** - Break down tasks into steps:
   - Create Step entities with clear ordering
   - Link Steps to parent Tasks
   - Track completion status

4. **Store Extended Documentation** - For detailed information:
   - Create markdown files in project `/docs` or `/doc` directory
   - Store file paths as observations on relevant entities

## Implementation recommendations
  - Add linting configurations to the Graph Memory (e.g., as observations on a "Project" or "BestPractice" entity).
  - Track common error patterns and their solutions (e.g., "Issue" entities linked to "PossibleSolution" entities).
  - Document the project architecture for quick reference (e.g., "Framework" entities, "Project" entities with architecture notes as observations or linked markdown files).

## For memory organization
  - Group related entities with consistent naming.
  - Use specific relation types for clearer connections.
  - Keep observations concise and actionable.
  - Use markdown notes for detailed observations (linking their paths from the Graph Memory).

## For conflicting information
  - If you encounter conflicting information, resolve it by:
    a) Identifying the source of the conflict.
    b) Determining the most accurate or up-to-date information: do a web search if needed.
    c) Updating the Graph Memory with the resolved information (using tools like `create_observation`, `delete_observation`, or updating entity properties if supported): tell the user about the resolution or ask the user for clarification if the research was unsuccessful.

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

---

# Quality Management protocol

## 1. Code Quality
- Follow best practices commonly used for the current project language, framework or application stack. If the project is new or the framework wasn't well defined from start, prompt the user with a possible choice for best practices and or application stacks.
- Follow naming conventions.
- Maintaining code consistency.

## 2. Performance
- Prevention of unnecessary re-rendering
- Efficient data fetching. Practical example: prevent the "n+1 query" problem.
- Bundle size optimization. Practical example: prevent unnecessary dependencies when possible (like adding a new library reference when just a handful of lines of code could achieve the same)

## 3. Security
- Strict validation of input values
- Appropriate error handling
- Secure management of sensitive information

## 4. UI/UX
- Ensuring responsive design
- Compliance with accessibility standards
- Maintaining consistent design system (see also step "1. Code Quality" above)
