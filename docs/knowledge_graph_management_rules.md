# Knowledge Graph management
These rules apply when using the `graph_mem` MCP server tools (e.g., `mcp1_CreateEntityTool`, `mcp1_SearchEntitiesTool`, etc.).

## Knowledge Graph Retrieval
- Always begin your chat by saying only "Remembering..." and retrieve all relevant information from your Graph Memory (e.g., using `mcp1_SearchEntitiesTool` with appropriate queries for current context, project, or recent activity).
- Refer to your knowledge graph as your "Graph Memory" or "Memory Graph".

## Knowledge Graph Memory
While conversing with the user, be attentive to any new information that falls into these categories:
    a) Current project in context
    b) Any issue presented in the question (which must be related to the target project)
    c) Goals (or tasks) implied or explicited by the question
    d) Relationships with other issues or solutions
    e) Mentions of previous attempts or solutions adopted to address the issue(s); note that this also implies recalling any memory about these past interactions or retrieving any related data from the Graph Memory (e.g., using `mcp1_SearchEntitiesTool` or `mcp1_GetEntityTool`).

## Memory Update
If any new information was gathered during the interaction, update your Graph Memory as follows:
    a) Create entities for (using `mcp1_CreateEntityTool`), specifying the entity type in the proper field:
        - "Project" with name and folder path for proper discrimination
        - "Framework" and/or "ApplicationStack", with versions (Rails, React, ..., MySql/Postgres, MongoDb, ...)
        - "Workflow" for common development procedures
        - "BestPractice" for code standards specific to this project
        - "Task", with a "priority" and "status" field to better track task progress
        - "Step" to complete a task, with "order" and "done" fields, like we would do for a to-do list
        - "Issue" for problems that arise during development or debugging of a task step
        - "PossibleSolution", for any "Issue" encountered, with a boolean flag for discriminating what worked from what didn't and a note about why it didn't work (if known)
        - "Model" (e.g., ORM models, key data structures, with their attributes and relations)
        - "DatabaseTable" (e.g., table name, columns, types, indexes)
        - "Class" (e.g., class name, key methods, purpose, file path)
        - "APIEndpoint" (e.g., path, HTTP method, request/response details)
        - "Component" (e.g., UI component name, props, purpose, file path)
        - "Service" (e.g., service name, public interface, purpose, file path)
    b) Connect entities between them using relations (using `mcp1_CreateRelationTool`).
    c) Store facts about entities as observations (using `mcp1_CreateObservationTool`).
    d) Analyze complex Tasks and separate them in Steps (representing Steps as entities and linking them to Tasks via relations).
    e) For detailed observations create markdown note files stored in the current project folder under the "/doc" subfolder (if available) or "/docs" as a second choice. The path to this note can be stored as an observation on the relevant entity in the Graph Memory.

## Implementation recommendations
  - Add linting configurations to the Graph Memory (e.g., as observations on a "Project" or "BestPractice" entity).
  - Track common error patterns and their solutions (e.g., "Issue" entities linked to "PossibleSolution" entities).
  - Document the project architecture for quick reference (e.g., "Framework" entities, "Project" entities with architecture notes as observations or linked markdown files).

## For memory organization
  - Group related entities with consistent naming.
  - Use specific relation types for clearer connections.
  - Keep observations concise and actionable.
  - Use markdown notes for detailed observations (linking their paths from the Graph Memory).
  - Do a periodic review of the Graph Memory for cleanup, removing duplicates and updating information: say "Reviewing memory..." before starting the review. Store a timestamp of the review in the Graph Memory (e.g., as an observation on a "SystemLog" or "MemoryReview" entity, using `mcp1_CreateObservationTool`).

## For conflicting information
  - If you encounter conflicting information, resolve it by:
    a) Identifying the source of the conflict.
    b) Determining the most accurate or up-to-date information: do a web search if needed.
    c) Updating the Graph Memory with the resolved information (using tools like `mcp1_CreateObservationTool`, `mcp1_DeleteObservationTool`, or updating entity properties if supported): tell the user about the resolution or ask the user for clarification if the research was unsuccessful.
