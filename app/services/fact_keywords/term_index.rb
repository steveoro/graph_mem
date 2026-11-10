# frozen_string_literal: true

module FactKeywords
  # One project's entity terms (EntityTerms: names and aliases), indexed for finding which of the
  # project's entities a fact mentions (1.77.0). Built once per project and reused for every fact of
  # it. A term is keyed by RailsCodeMap.lookup_key, so case, spaces, "_" and "-" don't matter
  # ("Swim Meet", "swim_meet" and "SwimMeet" are one key); a plural word also matches its singular.
  #
  # #path_for walks the fact's words in order, matching the longest run of up to MAX_NGRAM words at
  # each step, and builds the fact's keyword path: the project root's name, the name of the entity
  # that holds the fact, then each other entity in the order the text first mentions it.
  #
  # - A term shared by the fact's own entity and another (a short "Badge" on GogglesDb::Badge, when
  #   GogglesDb::Importers::Badge exists too) means the fact's own entity: nothing is added.
  # - A term several other entities share is ambiguous: nothing is added, and it is counted.
  # - A name already in the path isn't added twice; the path holds at most MAX_PATH names.
  #
  #   index = FactKeywords::TermIndex.new(project)
  #   index.path_for("A Swimmer should only have a single Badge for a single Season.", owner: badge).path
  #   # => ["goggles_db", "GogglesDb::Badge", "GogglesDb::Swimmer", "GogglesDb::Season"]
  class TermIndex
    MAX_PATH = 12
    MAX_NGRAM = 4
    # The most project entities read (ProjectSubtree's cap is the same kind of guard).
    MAX_ENTITIES = 5000
    # A word: letters, digits and "_", joined by "::", "/", "-" or "." (GogglesDb::Badge,
    # goggles_db/badge, user-agent, app.rb).
    WORD = %r{[\p{L}\p{N}_]+(?:(?:::|/|-|\.)[\p{L}\p{N}_]+)*}

    # `path` is the keyword path; `ambiguous` the mentions left out because several entities share them.
    Result = Data.define(:path, :ambiguous)

    # @param project [MemoryEntity, nil] the project root; nil gives an index with no terms
    def initialize(project)
      @root = project
      @terms = Hash.new { |hash, key| hash[key] = Set.new }
      project_entities.each do |id, name, aliases|
        next if id == project&.id

        EntityTerms.for(Struct.new(:name, :aliases).new(name, aliases)).each { |term| @terms[key(term)] << name }
      end
      @terms.default_proc = nil
    end

    # @param text [String] the fact
    # @param owner [MemoryEntity] the entity that holds the fact
    # @return [Result]
    def path_for(text, owner:)
      path = [ (@root.name if @root && @root.id != owner.id), owner.name ].compact
      own = path.to_set(&:downcase)
      words = text.to_s.scan(WORD)
      ambiguous = 0
      index = 0
      while index < words.size && path.size < MAX_PATH
        names, length = longest_match(words, index)
        index += length
        next if names.nil? || names.any? { |name| own.include?(name.downcase) }

        fresh = names.reject { |name| path.any? { |kept| kept.casecmp?(name) } }
        if names.size > 1
          ambiguous += 1
        elsif fresh.one?
          path << fresh.first
        end
      end
      Result.new(path: path, ambiguous: ambiguous)
    end

    private

    # @return [Array(Set<String>, Integer), Array(nil, Integer)] the names the longest run of words
    #   starting at `index` names, and how many words it took (1 when nothing matched)
    def longest_match(words, index)
      [ MAX_NGRAM, words.size - index ].min.downto(1) do |length|
        run = words[index, length]
        names = @terms[key(run.join(" "))] || @terms[key((run[0...-1] + [ run.last.singularize ]).join(" "))]
        return [ names, length ] if names
      end
      [ nil, 1 ]
    end

    def key(text) = RailsCodeMap.lookup_key(text)

    # @return [Array<Array(Integer, String, String)>] id, name and aliases of the project's entities
    def project_entities
      return [] unless @root

      ids = MemoryEntity.where(project_id: @root.id).limit(MAX_ENTITIES).pluck(:id)
      ids |= ProjectSubtree.resolve(@root.id, max_entities: MAX_ENTITIES).entity_ids
      MemoryEntity.where(id: ids.first(MAX_ENTITIES)).pluck(:id, :name, :aliases)
    end
  end
end
