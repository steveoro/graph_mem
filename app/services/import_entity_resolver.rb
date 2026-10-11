# frozen_string_literal: true

# Keeps import matching and execution aligned on canonical entity types.
class ImportEntityResolver
  class << self
    def canonical_type(raw_type)
      EntityTypeMapping.canonicalize(raw_type) || raw_type.to_s.strip
    end

    # Project-scoped name+type lookup: the import's own project first, then
    # the GLOBAL namespace (project_id NULL — reference stubs, Project roots,
    # operator-created globals). Entities belonging to OTHER projects are
    # never matched: scoped names let same-name entities coexist per project,
    # so RepoB's `module Foo` no longer collides with RepoA's `class Foo`.
    def find_by_name_and_type(name, raw_type, project_id: nil, include_declared: false)
      type = canonical_type(raw_type)
      own = project_id && MemoryEntity.find_by(name: name, entity_type: type, project_id: project_id)
      return own if own

      if include_declared
        # Reference resolution order: exactly ONE other project declaring
        # this name+type resolves directly (a mere reference never creates
        # a project-scoped copy); 2+ declarers stay ambiguous and fall
        # through to the global stub.
        # NOTE: `where.not(project_id: [])` matches EVERY row in
        # ActiveRecord — build the exclusion as two clauses so a nil
        # project_id never collapses into "not in ()".
        declarers = MemoryEntity.where(name: name, entity_type: type).where.not(project_id: nil)
        declarers = declarers.where.not(project_id: project_id) if project_id
        return declarers.first if declarers.one?
        # 2+ declarers: ambiguous — fall through to the global stub.
      end

      MemoryEntity.find_by(name: name, entity_type: type, project_id: nil)
    end

    # Name-only scoped lookup (MCP writes + relation targets): the context
    # project first, then the global namespace. A name declared by several
    # projects raises AmbiguousReference with the candidates — resolution
    # never guesses.
    def find_by_name(name, project_id: nil)
      if project_id
        in_scope = MemoryEntity.find_by(name: name, project_id: project_id)
        return in_scope if in_scope
      end
      global = MemoryEntity.find_by(name: name, project_id: nil)
      return global if global

      candidates = MemoryEntity.where(name: name)
      candidates = candidates.where.not(project_id: project_id) if project_id
      if candidates.size == 1
        candidates.first
      elsif candidates.size > 1
        raise McpGraphMemErrors::AmbiguousReference.new(name, candidates)
      end
    end

    # Read-only name-only lookup for Class↔Module same-name collisions —
    # scoped to ONE project (project_id nil = the global namespace). A
    # same-name pair in another project is not a collision any more.
    # Matching must NEVER write — this only returns the colliding entity;
    # ImportExecutionStrategy decides whether retyping is allowed.
    def class_module_collision(name, raw_type, project_id: nil)
      type = canonical_type(raw_type)
      return unless %w[Class Module].include?(type)

      MemoryEntity.find_by(name: name, entity_type: %w[Class Module] - [ type ], project_id: project_id)
    end
  end
end
