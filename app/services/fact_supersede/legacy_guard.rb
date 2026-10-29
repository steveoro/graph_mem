# frozen_string_literal: true

module FactSupersede
  # Deterministic checks that run before the judge and again at apply. Old is not wrong, and a
  # statement about another project, version or deployment can be true next to the fact:
  #
  # - "keep" (never proposed): the text names another project (the name or an alias of any other
  #   Project root, as a whole word, case-insensitive);
  # - "context" (proposed, never auto-applied, the judge is told): the text names a version or an
  #   environment / branch word that the fact doesn't, or the row is a work-log entry
  #   (`perspective: "experience"`, true when written).
  #
  #   guard = FactSupersede::LegacyGuard.new(fact)
  #   guard.check(observation) # => ["keep", "names another project (Legacy Gadget)"]
  #   guard.apply(candidates)  # sets each Candidate's guard and guard_reason
  class LegacyGuard
    KEEP = "keep"
    CONTEXT = "context"
    VERSION_PATTERN = /\bv?\d+(?:\.\d+)+\b/i
    ENVIRONMENT_WORDS = %w[legacy staging production prod preprod branch hotfix backport v1 v2 v3 v4].to_set.freeze
    # Shorter names would match ordinary words.
    MIN_NAME_LENGTH = 3

    # @param fact [MemoryObservation] the source fact
    def initialize(fact)
      @fact = fact
      @project_id = fact.fact_project_id
    end

    # @param candidates [Array<Candidate>]
    # @return [Array<Candidate>] the same candidates, guard and guard_reason set
    def apply(candidates)
      candidates.each { |candidate| candidate.guard, candidate.guard_reason = check(candidate.observation) }
    end

    # @param observation [MemoryObservation]
    # @return [Array(String, String), Array(nil, nil)] the guard and why
    def check(observation)
      text = without_own_names(observation.content.to_s)
      other = other_project_pattern && text[other_project_pattern]
      return [ KEEP, "names another project (#{other})" ] if other

      versions = text.scan(VERSION_PATTERN).map(&:downcase) - @fact.content.to_s.scan(VERSION_PATTERN).map(&:downcase)
      return [ CONTEXT, "names a version the fact doesn't (#{versions.first})" ] if versions.any?

      environment = (words(text) & ENVIRONMENT_WORDS) - words(@fact.content.to_s)
      return [ CONTEXT, "names an environment or branch the fact doesn't (#{environment.first})" ] if environment.any?
      return [ CONTEXT, "a work-log entry (true when written)" ] if observation.perspective == "experience"

      [ nil, nil ]
    end

    private

    def words(text)
      text.downcase.scan(/[\p{Alnum}]+/).to_set
    end

    # The fact's own project name and aliases are removed first, so "Gadget Project" in the text
    # doesn't count as naming a project called "Gadget".
    def without_own_names(text)
      own = names_of(MemoryEntity.where(id: @project_id))
      own.empty? ? text : text.gsub(name_pattern(own), " ")
    end

    def other_project_pattern
      return @other_project_pattern if defined?(@other_project_pattern)

      names = names_of(MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).where.not(id: @project_id))
      @other_project_pattern = names.empty? ? nil : name_pattern(names)
    end

    def names_of(scope)
      scope.pluck(:name, :aliases).flat_map { |name, aliases| [ name, *aliases.to_s.split(GraphMutationBatch::ALIAS_SEPARATOR) ] }
           .map(&:strip).select { |name| name.length >= MIN_NAME_LENGTH }.uniq
    end

    # Longest first, so "Legacy Gadget" wins over "Gadget".
    def name_pattern(names)
      alternatives = names.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }
      /(?<![\p{Alnum}])(?:#{alternatives.join('|')})(?![\p{Alnum}])/i
    end
  end
end
