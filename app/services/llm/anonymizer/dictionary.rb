# frozen_string_literal: true

require "set"

module Llm
  module Anonymizer
    # The names a session masks: every Project root's name and aliases (PRJ), and every member of
    # the scope's projects (ENT, or PER for a person type), each also without its trailing generic
    # words ("Gadget Project" → "Gadget"), plus the usernames found in home paths (USER). Two pluck queries. Matching is by words: text and terms are split into word
    # pieces (letters and digits, then camel-case boundaries), and a run of pieces whose joined,
    # case-folded letters equal a term's matches when the pieces are joined by nothing, a space,
    # "-", "_" or a separator the term itself has (and its JSON-escaped form). So "Gadget
    # Project", "gadget-project", "GadgetProject", "GADGET_PROJECT" and "gadgetproject" all match
    # one term, inside identifiers and path segments too; a plural "s"/"es" is matched for terms of
    # 5 letters or more. The longest term wins, leftmost first.
    class Dictionary
      MAX_TERMS = 20_000
      MIN_LENGTH = 3
      PERSON_TYPES = %w[Person User].freeze
      # Generic words never masked on their own.
      ALLOWED = %w[rails ruby user users service services controller controllers model models project projects component components
                   config configuration app application api test tests spec specs main admin default server client data file files
                   system task tasks job jobs view views docs readme].to_set.freeze
      BASE_SEPARATORS = [ "", " ", "-", "_" ].freeze
      WORD = /[\p{L}\p{N}]+/
      CAMEL = /(?<=[\p{Ll}\p{N}])(?=\p{Lu})|(?<=\p{Lu})(?=\p{Lu}\p{Ll})/

      # @param scope [Llm::Scope]
      # @return [Dictionary]
      # @raise [Refused] `:dictionary_cap` over MAX_TERMS
      def self.build(scope)
        new.tap do |dictionary|
          project = NodeOperationsStrategy::PROJECT_ENTITY_TYPE
          MemoryEntity.where(entity_type: project, project_id: nil).pluck(:name, :aliases).each do |name, aliases|
            dictionary.add_entry("PRJ", name, aliases)
          end
          ids = scope.project_ids
          if ids.present?
            MemoryEntity.where(project_id: ids).pluck(:name, :aliases, :entity_type).each do |name, aliases, type|
              dictionary.add_entry(PERSON_TYPES.include?(type) ? "PER" : "ENT", name, aliases)
            end
          end
        end
      end

      # @param text [String]
      # @return [Array<Array(Integer, Integer)>] the word pieces' [start, stop) offsets
      def self.pieces(text)
        text.to_enum(:scan, WORD).flat_map do
          match = Regexp.last_match
          start = match.begin(0)
          match[0].split(CAMEL).map { |piece| [ start, (start += piece.length) ] }
        end
      end

      def initialize
        @types = {}
        @separators = BASE_SEPARATORS.to_set
        @longest = 0
      end

      # @param type [String] PRJ, ENT, PER or USER
      # @param name [String]
      # @param aliases [String, nil] a comma (or | ;) list
      # @return [void]
      def add_entry(type, name, aliases = nil)
        [ name, *aliases.to_s.split(/[,|;]/) ].each do |term|
          add(type, term)
          add(type, without_generic_tail(term.to_s))
        end
      end

      # @param type [String]
      # @param term [String]
      # @return [void]
      # @raise [Refused] `:dictionary_cap`
      def add(type, term)
        term = term.to_s.strip
        offsets = self.class.pieces(term)
        key = offsets.map { |start, stop| term[start...stop] }.join.downcase
        return if key.length < MIN_LENGTH || ALLOWED.include?(key) || @types.key?(key)

        @types[key] = type
        raise Refused, :dictionary_cap if @types.size > MAX_TERMS

        @longest = [ @longest, key.length ].max
        offsets.each_cons(2) do |(_, stop), (start, _)|
          separator = term[stop...start]
          @separators << separator << JSON.generate(separator)[1...-1]
        end
      end

      # @return [Integer] the number of terms
      def size = @types.size

      # @param text [String] text without tokens
      # @return [Array<Array(Integer, Integer, String, String)>] non-overlapping matches as
      #   [start, stop, type, term key], leftmost first, longest term at each position
      def matches(text)
        pieces = self.class.pieces(text)
        found = []
        index = 0
        while index < pieces.size
          last, type, key = longest_at(text, pieces, index)
          if last
            found << [ pieces[index][0], pieces[last][1], type, key ]
            index = last + 1
          else
            index += 1
          end
        end
        found
      end

      # @return [String] never the terms
      def inspect = "#<#{self.class.name} #{size} terms>"

      private

      # "Gadget Project" is also called "Gadget" (a repo, a folder, a gem): the name without its
      # trailing generic words is a term too.
      def without_generic_tail(term)
        words = self.class.pieces(term).map { |start, stop| term[start...stop] }
        words.pop while words.size > 1 && ALLOWED.include?(words.last.downcase)
        words.join(" ")
      end

      def longest_at(text, pieces, index)
        best = nil
        joined = +""
        (index...pieces.size).each do |last|
          break if last > index && !@separators.include?(text[pieces[last - 1][1]...pieces[last][0]])

          joined << text[pieces[last][0]...pieces[last][1]].downcase
          # A plural adds at most two letters.
          break if joined.length > @longest + 2
          key = lookup(joined)
          best = [ last, @types[key], key ] if key
        end
        best
      end

      # @return [String, nil] the term key `joined` matches, a plural of a 5+ letter term included
      def lookup(joined)
        return joined.dup if @types.key?(joined) # `joined` keeps growing in the caller

        %w[es s].each do |suffix|
          stem = joined.delete_suffix(suffix)
          return stem if stem != joined && stem.length >= 5 && @types.key?(stem)
        end
        nil
      end
    end
  end
end
