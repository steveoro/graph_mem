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
      content = observation.content.to_s
      other = other_project_name(content)
      return [ KEEP, "names another project (#{other})" ] if other

      text = without_own_names(content)
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

    # One longest-first pass over the own and the other projects' names: "Gadget Project" in the
    # text is the fact's own project even when another is called "Gadget", and "Gadget Mobile" is
    # another project even when the fact's is called "Gadget".
    def other_project_name(text)
      return if other_names.empty?

      text.scan(all_names_pattern).find { |hit| other_names_down.include?(hit.downcase) }
    end

    # The own names are removed only for the version and environment checks.
    def without_own_names(text)
      own_names.empty? ? text : text.gsub(own_names_pattern, " ")
    end

    def own_names
      @own_names ||= names_of(MemoryEntity.where(id: @project_id))
    end

    def other_names
      @other_names ||= names_of(MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).where.not(id: @project_id))
    end

    def other_names_down = @other_names_down ||= other_names.to_set(&:downcase)
    def all_names_pattern = @all_names_pattern ||= name_pattern(own_names + other_names)
    def own_names_pattern = @own_names_pattern ||= name_pattern(own_names)

    def names_of(scope)
      scope.pluck(:name, :aliases).flat_map { |name, aliases| [ name, *aliases.to_s.split(GraphMutationBatch::ALIAS_SEPARATOR) ] }
           .map(&:strip).select { |name| name.length >= MIN_NAME_LENGTH }.uniq
    end

    # Longest first, so "Legacy Gadget" wins over "Gadget". scan returns whole matches (no groups).
    def name_pattern(names)
      alternatives = names.uniq.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }
      /(?<![\p{Alnum}])(?:#{alternatives.join('|')})(?![\p{Alnum}])/i
    end
  end
end
