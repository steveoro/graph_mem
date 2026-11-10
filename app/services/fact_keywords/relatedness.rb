# frozen_string_literal: true

module FactKeywords
  # Whether two facts are about the same thing, from their keyword paths (1.78.0). A fact's
  # **mentions** are its path after its own entity (MemoryObservation#keyword_mentions). Two facts:
  #
  # - **related**: they share a mention, or one mentions the other's own entity. A shared **first**
  #   mention is the strong match;
  # - **unrelated**: both mention entities, none in common;
  # - **one_sided**: only one of them mentions any entity;
  # - **unknown**: neither mentions any entity, so the paths can't tell.
  #
  # The callers decide what each answer allows: ContradictionDetector pairs only related facts (or
  # two unknown ones that are very close), FactSupersede seeds an unjudged row for anything but an
  # unrelated pair, and the NoSharedSubject review policy dismisses rows the generators would no
  # longer seed.
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
    # @return [Comparison]
    def compare(first, second)
      compare_paths(first.keywords, first.memory_entity&.name, second.keywords, second.memory_entity&.name)
    end

    # @param first_path [Array<String>] a keyword path
    # @param first_owner [String, nil] the name of the entity that holds the first fact
    # @param second_path [Array<String>]
    # @param second_owner [String, nil]
    # @return [Comparison]
    def compare_paths(first_path, first_owner, second_path, second_owner)
      first = FactKeywords.mentions(first_path, first_owner)
      second = FactKeywords.mentions(second_path, second_owner)
      shared = first & second
      shared += [ second_owner ] if second_owner && second_owner != first_owner && first.include?(second_owner)
      shared += [ first_owner ] if first_owner && first_owner != second_owner && second.include?(first_owner)
      Comparison.new(subject: subject(first, second, shared), strong: first.first.present? && first.first == second.first,
                     shared: shared.uniq)
    end

    # @param observations [Array<MemoryObservation>]
    # @return [Boolean] every one has a computed path
    def computed?(*observations)
      observations.flatten.all? { |observation| observation&.keywords_at.present? }
    end

    def subject(first, second, shared)
      return :related if shared.any?
      return :unknown if first.empty? && second.empty?
      return :unrelated if first.any? && second.any?

      :one_sided
    end
    private_class_method :subject
  end
end
