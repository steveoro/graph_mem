---
name: project-scan
description: Perform a multi-stage, source-code-grounded scan of a project and persist the findings in GraphMem using GraphMem's own MCP tools. Use when the user wants to scan a project root and no LLM summarization server is reachable, or when they want a progressive, human-guided scan with checkpoints.
triggers: ["user"]
---

# Project Scan Skill

Perform a human-guided, multi-stage project scan and persist the results in the active GraphMem knowledge graph. This skill is especially useful when the `scan_project` MCP/REST path cannot be used because the LLM summarization service (Ollama or OpenAI-compatible) is disabled or unreachable.

## Scope

- Treat the target project root as the source of truth.
- Reuse an existing `Project` entity or create a new one.
- Progressively discover and persist architecture facts, components, services, dependencies, usage notes, UI details, and documentation.
- Ask the user whether to continue before each new depth level.
- Stop cleanly at any point and record the last completed depth so a later session can resume.

## When to use

Use this skill instead of the `scan_project` tool when:
- `SummarizationConfig.llm_usable?` is false or `scan_project` returns a `fallback`/`llm_unavailable` reason.
- The user wants to scan a project in stages and review each layer before continuing.
- The user wants the agent to directly inspect source files and write observations/relations to the graph.

## Required inputs

1. `project_root`: absolute path to the project directory.
2. `project_name` (optional): preferred project name. Defaults to directory name or README title.
3. `aliases` (optional): comma/pipe-separated aliases.
4. `depths` (optional): ordered list of depths to cover. Default: `[ "birds_eye", "architecture", "usage", "ui", "tests", "docs" ]`.

## Setup

1. Verify GraphMem is reachable via the MCP/REST tools configured in this session.
2. Search for an existing `Project` entity with the target name or aliases:
   - `search_entities` with `q: <project_name>` and `entity_type: Project`.
   - If found, record its `entity_id` and use `update_entity` to refresh `description`/`aliases` only if currently blank.
   - If not found, `create_entity` with `entity_type: Project`.
3. Set the project as context with `set_context` if the GraphMem client supports it.

## Scan stages

For each requested depth, follow the steps below, then ask the user whether to continue to the next depth.

### 1. Birds-eye view

Goal: project identity and top-level structure.

- Read `README*`, `package.json`, `Gemfile`, `pyproject.toml`, `requirements*.txt`, `Cargo.toml`, `go.mod`, `docker-compose*.yml`, `.devin/blueprint.yaml`.
- Create the `Project` entity (or update if existing) with:
  - `name` from README title or directory name.
  - `description` from README first paragraph or project metadata.
  - `aliases` from user input or manifest `name`.
- For each manifest file, create a `Configuration` entity and a `part_of` relation to the project.
- For each top-level non-hidden directory (excluding `node_modules`, `vendor`, `.git`, `tmp`, `log`, `coverage`, `dist`, `build`), create a `Component` entity and a `part_of` relation to the project.
- Persist all observations with source like `project_scan_skill:birds_eye:<project_root>`.
- Ask the user: "Birds-eye scan complete. Continue to architecture depth?"

### 2. Architecture depth

Goal: major services, classes, modules, frameworks, and their relations.

- List source directories (`app`, `lib`, `src`, `services`, `controllers`, `models`, `components`, `api`).
- For each significant file or module:
  - Create a `Service`, `Component`, `Class`, `Module`, or `Model` entity (use `ImportEntityResolver` canonical types if available via `entity_type`).
  - Add observations about public methods, responsibilities, and key dependencies.
  - Link to the project or parent component with `part_of`.
  - If a dependency on another discovered entity is obvious (imports, gem usage, service calls), create a `depends_on` or `relates_to` relation.
- Persist with source `project_scan_skill:architecture:<project_root>`.
- Ask the user: "Architecture depth complete. Continue to usage/config depth?"

### 3. Usage / configuration depth

Goal: how the project is run, configured, and deployed.

- Read configuration files (`config/`, `.env*`, `docker-compose*.yml`, `Dockerfile`, `Procfile`, `bin/`, CI files).
- Create `Configuration`, `Service`, or `ApplicationStack` entities as appropriate.
- Add observations about environment variables, deployment commands, scheduled jobs, and external services.
- Create `configured_by` or `depends_on` relations.
- Persist with source `project_scan_skill:usage:<project_root>`.
- Ask the user: "Usage/config depth complete. Continue to UI depth?"

### 4. UI depth (if applicable)

Goal: user-facing routes, views, components, and API endpoints.

- Explore `app/views/`, `app/controllers/`, `frontend/`, `app/components/`, `routes.rb`, `pages/`, API route definitions.
- Create `Route`, `APIEndpoint`, `Component`, or `Service` entities.
- Add observations about paths, methods, and rendered templates.
- Link UI entities to the project with `part_of`.
- Persist with source `project_scan_skill:ui:<project_root>`.
- Ask the user: "UI depth complete. Continue to tests/docs depth?"

### 5. Tests and documentation depth

Goal: test coverage and development notes.

- Explore `spec/`, `test/`, `docs/`, `README*` files, `CHANGELOG*`, `CONTRIBUTING*`.
- Create `TestCase`, `Component`, or `Documentation` entities.
- Add observations about test frameworks, important development conventions, and known issues.
- Create `tested_by` relations where clear.
- Persist with source `project_scan_skill:tests_and_docs:<project_root>`.

## Persistence rules

- Always use `source: "project_scan_skill:<depth>:<project_root>"` on observations so they can be obsoleted by later scans.
- Use `create_observation` to add facts; avoid duplicating identical content by reading existing observations first or using `bulk_update`.
- For every new entity, prefer `create_relation` with `part_of` to the project/parent.
- Use `create_entity` for new components and `create_relation` for dependencies.
- If an entity already exists, add missing observations instead of creating a duplicate.

## Progress tracking

- After each completed depth, create or update an observation on the `Project` entity with content:
  `Project scan progress: completed <depth> at <timestamp>. Next: <next_depth> or done.`
- If the user chooses to stop, record the same observation with status `paused`.
- When resuming, read the project entity, find the last `Project scan progress` observation, and continue with the next unfinished depth.

## Stopping / resuming

- If the user says stop, pause, or wait, record the completed depths and ask for confirmation before the next stage.
- If resuming, read the last progress observation and continue from the next depth.
- If the user asks to restart, obsolete previous `project_scan_skill:*` observations and start over from birds-eye.
