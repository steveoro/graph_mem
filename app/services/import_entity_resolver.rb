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

    # Reference-node resolution (a mere reference never creates a
    # project-scoped copy). Order:
    #   1. the entity the referrer's stored edge already targets — an
    #      unchanged re-import must no-op even after a claim or a second
    #      declarer (Post keeps pointing at its stored Foo);
    #   2. exactly ONE declarer, Class↔Module siblings included — a claim
    #      can retype the stub (include Foo → class Foo);
    #   3. the global (unclaimed) stub, either declared type or sibling;
    #   4. nil — caller creates a fresh global stub; the ambiguous-
    #      endpoint collector queues the re-point proposals.
    # @param parent_entity_id [Integer, nil] the referencing entity (the
    #   payload parent the reference node sits under)
    def find_reference(name, raw_type, project_id:, parent_entity_id: nil)
      if parent_entity_id
        named = MemoryEntity.where(name: name).select(:id)
        linked = MemoryRelation.where(from_entity_id: parent_entity_id, to_entity_id: named)
                               .or(MemoryRelation.where(to_entity_id: parent_entity_id,
                                                        from_entity_id: named))
        candidate_ids = linked.flat_map { |r| [ r.from_entity_id, r.to_entity_id ] }.uniq - [ parent_entity_id ]
        return MemoryEntity.find_by(id: candidate_ids.first) if candidate_ids.one?
      end

      type = canonical_type(raw_type)
      siblings = %w[Class Module].include?(type) ? %w[Class Module] - [ type ] : []
      declared = MemoryEntity.where(name: name, entity_type: [ type ] + siblings).where.not(project_id: nil)
      declared = declared.where.not(project_id: project_id) if project_id
      return declared.first if declared.one?

      MemoryEntity.find_by(name: name, entity_type: type, project_id: nil) ||
        (siblings.any? && MemoryEntity.find_by(name: name, entity_type: siblings, project_id: nil))
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
        # Exactly one same-named entity in the whole graph resolves even
        # across a scope boundary — deliberately: a single foreign
        # candidate is unambiguous (there is nothing else the name could
        # mean). Writes therefore DO wire to foreign-scope entities here;
        # documented design choice (Graphy flagged it) — revisit only if
        # cross-project writes need a stricter rule.
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
