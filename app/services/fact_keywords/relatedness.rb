# frozen_string_literal: true

module FactKeywords
  # Whether two facts are about the same thing, from their keyword paths (1.78.0). A fact's
  # **mentions** are its path after its own entity (MemoryObservation#keyword_mentions). Two facts:
  #
  # - **related**: they share a mention, or one mentions the other's own entity. A shared **first**
  #   mention is the strong match;
  # - **unrelated**: held by two different entities the paths don't connect (siblings, 1.80.0:
  #   "gadget_mcp › Rework" and "gadget_mcp › Server Rules"), or both mention entities, none in common.
  #   Never siblings: two entities a relation joins directly (Deployment part_of Infrastructure), a
  #   fact held by its project root itself (or by an entity with no project: its path starts with its
  #   own entity), which is about the whole project, and a path that no longer holds its owner (the
  #   entity was renamed since it was computed), which can't tell;
  # - **one_sided**: one own entity, and only one of them mentions any entity;
  # - **unknown**: one own entity, and neither mentions any entity, so the paths can't tell.
  #
  # The callers decide what each answer allows: ContradictionDetector pairs only related facts (or
  # two unknown ones that are very close), FactSupersede neither judges nor seeds an unrelated pair
  # that no search term found, and the NoSharedSubject review policy dismisses rows the generators
  # would no longer seed.
  #
  #   FactKeywords::Relatedness.compare(badge_fact, other_fact)
  #   # => #<data Comparison subject=:related, strong=true, shared=["GogglesDb::Swimmer"]>
  module Relatedness
    SUBJECTS = %i[related unrelated one_sided unknown].freeze

    # `subject` is one of SUBJECTS; `strong` a shared first mention; `shared` the shared names, in
    # the first fact's path order (a mentioned own entity included).
    Comparison = Data.define(:subject, :strong, :shared) do
      def related? = subject == :related
    end

    module_function

    # @param first [MemoryObservation] with its keyword path computed and its entity loaded
    # @param second [MemoryObservation]
    # @param connected [Boolean, #call, nil] whether a relation joins the two entities directly; nil
    #   asks the database (one query, only when the answer depends on it). A caller comparing one
    #   fact with many passes what it preloaded.
    # @return [Comparison]
    def compare(first, second, connected: nil)
      first_entity = first.memory_entity
      second_entity = second.memory_entity
      compare_paths(first.keywords, first_entity&.name, second.keywords, second_entity&.name,
                    connected: connected.nil? ? -> { joined?(first_entity, second_entity) } : connected)
    end

    # @param first_path [Array<String>] a keyword path
    # @param first_owner [String, nil] the name of the entity that holds the first fact
    # @param second_path [Array<String>]
    # @param second_owner [String, nil]
    # @param connected [Boolean, #call] a relation joins the two owners directly (a callable is only
    #   called when the answer depends on it)
    # @return [Comparison]
    def compare_paths(first_path, first_owner, second_path, second_owner, connected: false)
      first = FactKeywords.mentions(first_path, first_owner)
      second = FactKeywords.mentions(second_path, second_owner)
      shared = first & second
      shared += [ second_owner ] if second_owner && second_owner != first_owner && first.include?(second_owner)
      shared += [ first_owner ] if first_owner && first_owner != second_owner && second.include?(first_owner)
      siblings = shared.empty? && siblings?(first_path, first_owner, second_path, second_owner) &&
                 !(connected.respond_to?(:call) ? connected.call : connected)
      Comparison.new(subject: subject(first, second, shared, siblings), strong: first.first.present? && first.first == second.first,
                     shared: shared.uniq)
    end

    # @param observations [Array<MemoryObservation>]
    # @return [Boolean] every one has a computed path
    def computed?(*observations)
      observations.flatten.all? { |observation| observation&.keywords_at.present? }
    end

    def subject(first, second, shared, siblings)
      return :related if shared.any?
      return :unrelated if siblings
      return :unknown if first.empty? && second.empty?
      return :unrelated if first.any? && second.any?

      :one_sided
    end

    # Two different own entities, each still in its own path, neither of them at the head of it (a
    # project root, or an entity with no project).
    def siblings?(first_path, first_owner, second_path, second_owner)
      return false if first_owner.nil? || second_owner.nil? || first_owner == second_owner

      pairs = [ [ first_path, first_owner ], [ second_path, second_owner ] ]
      # A path that no longer holds its owner (the entity was renamed since) can't tell.
      return false unless pairs.all? { |path, owner| Array(path).include?(owner) }

      pairs.none? { |path, owner| Array(path).first == owner }
    end

    # @return [Boolean] a relation joins the two entities directly, in either direction
    def joined?(first, second)
      return false if first.nil? || second.nil? || first.id == second.id

      MemoryRelation.where(from_entity_id: first.id, to_entity_id: second.id)
                    .or(MemoryRelation.where(from_entity_id: second.id, to_entity_id: first.id)).exists?
    end
    private_class_method :subject, :siblings?, :joined?
  end
end
