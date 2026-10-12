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
    def find_by_name_and_type(name, raw_type, project_id: nil)
      type = canonical_type(raw_type)
      own = project_id && MemoryEntity.find_by(name: name, entity_type: type, project_id: project_id)
      return own if own

      MemoryEntity.find_by(name: name, entity_type: type, project_id: nil)
    end

    # Reference-node resolution (a mere reference never creates a
    # project-scoped copy). Order:
    #   1. the entity a resolved referrer's stored edge already targets —
    #      an unchanged re-import must no-op even after a claim or a
    #      second declarer (Post keeps pointing at its stored Foo). Edges
    #      are limited to the relation types the payload declares for the
    #      reference (+ part_of — the stub-park edge), so an unrelated
    #      `mentions`/`relates_to` edge to a namesake can't hijack it;
    #   2. the importing project's OWN declaration — a same-scope class
    #      always wins over foreign declarers (S11: `Swimmer <
    #      ApplicationRecord` inside the same project binds in-scope);
    #   3. exactly ONE foreign declarer, Class↔Module siblings included —
    #      a claim can retype the stub (include Foo → class Foo);
    #   4. the global (unclaimed) stub, either declared type or sibling;
    #   5. nil — caller creates a fresh global stub; the ambiguous-
    #      endpoint collector queues the re-point proposals.
    # @param referrer_ids [Array<Integer>] resolved ids of the payload
    #   entities whose edges reference this node — NOT the tree parent
    #   (references park under the project root; the real referrer is the
    #   source endpoint of the payload relation, e.g. Post for
    #   `Post -mixes_in-> Notifiable`).
    # @param relation_types [Array<String>] the payload edge types that
    #   reference this node (canonical); restricts step 1's stored-edge
    #   match. Empty = any edge type counts.
    def find_reference(name, raw_type, project_id:, referrer_ids: [], relation_types: [])
      stored = stored_reference_target(name, referrer_ids, relation_types)
      return stored if stored

      type = canonical_type(raw_type)
      siblings = %w[Class Module].include?(type) ? %w[Class Module] - [ type ] : []
      types = [ type ] + siblings

      if project_id
        own = MemoryEntity.find_by(name: name, entity_type: types, project_id: project_id)
        return own if own
      end

      declared = MemoryEntity.where(name: name, entity_type: types).where.not(project_id: nil)
      declared = declared.where.not(project_id: project_id) if project_id
      return declared.first if declared.one?

      MemoryEntity.find_by(name: name, entity_type: types, project_id: nil)
    end

    # The namesake a referrer's stored edge already points at. The match
    # requires a SINGLE distinct candidate across every declared referrer
    # — a tie (Post edges to two different Foos) falls through rather
    # than picking one. `part_of` always counts so the parked stub edge
    # still resolves its parked target.
    def stored_reference_target(name, referrer_ids, relation_types)
      return nil if referrer_ids.blank?

      named = MemoryEntity.where(name: name).select(:id)
      linked = MemoryRelation.where(from_entity_id: referrer_ids, to_entity_id: named)
                             .or(MemoryRelation.where(to_entity_id: referrer_ids,
                                                      from_entity_id: named))
      types = relation_types | [ "part_of" ]
      linked = linked.where(relation_type: types) if relation_types.present?
      candidate_ids = linked.flat_map { |r| [ r.from_entity_id, r.to_entity_id ] }.uniq - referrer_ids
      MemoryEntity.find_by(id: candidate_ids.first) if candidate_ids.one?
    end

    # Project root id by name — the scope an import just claimed for its
    # AMBIGUOUS endpoint resolution (rake tasks pass it to the seeder).
    def project_root_id(project_name)
      MemoryEntity.find_by(name: project_name, entity_type: "Project")&.id
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
