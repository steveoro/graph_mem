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
    #
    # The same-fact ladder (1.82.0): being related is not being the same fact, and only the same
    # subject may make one fact obsolete. A fact's subjects are its own entity and its mentions.
    # - `same_subject`: both facts mention entities and one's subjects contain the other's (a fact
    #   with no mentions says too little about its subject: F2c gives it LLM words);
    # - `covers`: :both, :first, :second (whose subjects contain the other's), or nil;
    # - `details`: FactKeywords::Details.compare of the two texts, the first being the newer (:none,
    #   :same, :dropped, :different).
    Comparison = Data.define(:subject, :strong, :shared, :same_subject, :covers, :details) do
      def related? = subject == :related

      # The first fact is about the same thing as the second, covers all it is about, and states a
      # different detail: it may outdate it ("Updated using Rails 8.1" over "… Rails 8.0").
      def same_fact_different_detail?
        same_subject && %i[first both].include?(covers) && details == :different
      end

      # @return [String] "same", "related" or "unclear", as the fact-supersede judge reads it
      def level
        return "same" if same_subject
        return "related" if related?

        "unclear"
      end
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
                    connected: connected.nil? ? -> { joined?(first_entity, second_entity) } : connected,
                    first_text: first.content, second_text: second.content,
                    first_root: first_entity&.project_root?, second_root: second_entity&.project_root?,
                    first_words: llm_words(first), second_words: llm_words(second))
    end

    # @param first_path [Array<String>] a keyword path
    # @param first_owner [String, nil] the name of the entity that holds the first fact
    # @param second_path [Array<String>]
    # @param second_owner [String, nil]
    # @param connected [Boolean, #call] a relation joins the two owners directly (a callable is only
    #   called when the answer depends on it)
    # @param first_text [String, nil] the first fact, for its details
    # @param second_text [String, nil]
    # @param first_root [Boolean, nil] the first fact's entity is a project root (nil: read from the
    #   path, which also starts with its own entity for an entity with no project)
    # @param second_root [Boolean, nil]
    # @param first_words [Array<String>, nil] the first fact's LLM words (1.83.0), used only when both
    #   facts are on one entity and mention none
    # @param second_words [Array<String>, nil]
    # @return [Comparison]
    def compare_paths(first_path, first_owner, second_path, second_owner, connected: false, first_text: nil, second_text: nil,
                      first_root: nil, second_root: nil, first_words: nil, second_words: nil)
      first = FactKeywords.mentions(first_path, first_owner)
      second = FactKeywords.mentions(second_path, second_owner)
      if first_owner && first_owner == second_owner && first.empty? && second.empty? && first_words.present? && second_words.present?
        return compare_words(first_words, second_words, first_text, second_text)
      end

      shared = first & second
      shared += [ second_owner ] if second_owner && second_owner != first_owner && first.include?(second_owner)
      shared += [ first_owner ] if first_owner && first_owner != second_owner && second.include?(first_owner)
      siblings = shared.empty? && siblings?(first_path, first_owner, second_path, second_owner) &&
                 !(connected.respond_to?(:call) ? connected.call : connected)
      first_rooted = first_root.nil? ? rooted?(first_path, first_owner) : first_root
      second_rooted = second_root.nil? ? rooted?(second_path, second_owner) : second_root
      covers = covers(first, first_owner, first_rooted, second, second_owner, second_rooted)
      Comparison.new(subject: subject(first, second, shared, siblings), strong: first.first.present? && first.first == second.first,
                     shared: shared.uniq, same_subject: !covers.nil?, covers: covers,
                     details: FactKeywords::Details.compare(first_text, second_text))
    end

    # @param observations [Array<MemoryObservation>]
    # @return [Boolean] every one has a computed path
    def computed?(*observations)
      observations.flatten.all? { |observation| observation&.keywords_at.present? }
    end

    # 1.83.0: two facts on one entity that name no entity, by their LLM words (FactKeywords::LlmWords),
    # which take the place of the mentions: shared words relate them (none: unrelated, full weight),
    # and one fact's words containing the other's make the same subject.
    #
    # @return [Comparison]
    def compare_words(first_words, second_words, first_text, second_text)
      mine = FactKeywords::LlmWords.keys(first_words)
      theirs = FactKeywords::LlmWords.keys(second_words)
      shared = mine & theirs
      covers = if mine == theirs then :both
      elsif mine.superset?(theirs) then :first
      elsif theirs.superset?(mine) then :second
      end
      Comparison.new(subject: shared.any? ? :related : :unrelated, strong: false, shared: shared.to_a.sort, same_subject: !covers.nil?,
                     covers: covers, details: FactKeywords::Details.compare(first_text, second_text))
    end

    # @return [Array<String>, nil] a fact's computed LLM words, nil while pending or with the setting off
    def llm_words(observation)
      return nil unless observation.llm_keywords_at.present? && FactKeywords::LlmWords.enabled?

      observation.llm_keywords
    end

    # @return [Symbol, nil] whose subjects (own entity and mentions) contain the other's; nil unless
    #   both facts mention entities. A fact held by the project root is about the whole project: it
    #   covers a member's fact whose mentions it contains, and a member's fact never covers it.
    def covers(first, first_owner, first_rooted, second, second_owner, second_rooted)
      return nil if first.empty? || second.empty?
      return (:first if Set.new(first).superset?(Set.new(second))) if first_rooted && !second_rooted
      return (:second if Set.new(second).superset?(Set.new(first))) if second_rooted && !first_rooted

      mine = Set[first_owner, *first]
      theirs = Set[second_owner, *second]
      return :both if mine == theirs
      return :first if mine.superset?(theirs)

      :second if theirs.superset?(mine)
    end

    # A path that starts with its own entity: the project root's (or an entity with no project).
    def rooted?(path, owner) = owner.present? && Array(path).first == owner

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
    private_class_method :subject, :siblings?, :joined?, :covers, :rooted?, :compare_words, :llm_words
  end
end
