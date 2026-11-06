# frozen_string_literal: true

class RailsCodeMap
  # A built Rails code map (1.75.0): its entries, edges and declared gems, with the lookups the scan
  # uses. Pure and read-only: every index is built in the constructor.
  #
  #   map.entry("GogglesDb::Badge")                    # => #<data Entry name="GogglesDb::Badge", type="Model", …>
  #   map.resolve("Badge", files: ["README.md"])       # => #<data Resolution status=:ambiguous, candidates=[…]>
  #   map.resolve("Badge", files: ["app/strategies/goggles_db/importers/badge.rb"]).entry.name
  #                                                    # => "GogglesDb::Importers::Badge"
  #   map.guide_for(["app/models/goggles_db/badge.rb"]) # => { own: [Entry…], related: [Entry…] }
  class Map
    # `status` is :resolved (with `entry`), :ambiguous (with the candidates' names) or :none.
    Resolution = Data.define(:status, :entry, :candidates)
    NONE = Resolution.new(status: :none, entry: nil, candidates: [])
    # Mentions read from one part's text, at most.
    MAX_MENTIONS = 500
    MENTION = /\b[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\b/

    attr_reader :entries, :edges, :gems, :unreadable_files, :counters

    # @param entries [Array<Entry>]
    # @param edges [Array<Edge>] between entries
    # @param gems [Set<String>] declared gem names, downcased
    # @param complete [Boolean] false when a cap cut the map (RailsCodeMap::MAX_FILES, MAX_ENTRIES)
    # @param unreadable_files [Array<String>] relative paths the extractor couldn't read
    # @param counters [Hash{Symbol => Integer, Boolean}] the build's counters (RailsCodeMap#call)
    def initialize(entries: [], edges: [], gems: Set.new, complete: true, unreadable_files: [], counters: {})
      @entries = entries.freeze
      @edges = edges.freeze
      @gems = gems.to_set { |name| RailsCodeMap.project_key(name) }.freeze
      @complete = complete
      @unreadable_files = unreadable_files.freeze
      @counters = counters.freeze
      @by_name = entries.index_by { |entry| entry.name.downcase }
      @by_key = Hash.new { [] }
      entries.each { |entry| entry.keys.each { |key| @by_key[key] = @by_key[key] + [ entry ] } }
      @by_file = Hash.new { [] }
      entries.each { |entry| entry.files.each { |file| @by_file[file] = @by_file[file] + [ entry ] } }
      @neighbours = Hash.new { [] }
      edges.each do |edge|
        @neighbours[edge.from] = @neighbours[edge.from] | [ edge.to ]
        @neighbours[edge.to] = @neighbours[edge.to] | [ edge.from ]
      end
    end

    EMPTY = new.freeze

    # @return [Boolean] no entries (not a Rails project, or nothing mapped)
    def empty? = @entries.empty?

    # @return [Boolean] every file was read and no cap cut the map
    def complete? = @complete

    # @param name [String]
    # @return [Entry, nil] the entry of exactly that name (ignoring case)
    def entry(name) = @by_name[name.to_s.strip.downcase]

    # @param name [String]
    # @return [Boolean] a gem the project declares ("-", "_" and spaces alike)
    def gem?(name) = @gems.include?(RailsCodeMap.project_key(name))

    # The entry a name means, as the scan answers it: the exact name, else the one entry a key
    # (short name, path, file path, trailing part; RailsCodeMap.keys_for) points to, else the one
    # left after narrowing by the part's own files, by the entries related to them, then by their
    # namespaces.
    #
    # @param name [String]
    # @param files [Array<String>] the part's files, relative to the root
    # @return [Resolution]
    def resolve(name, files: [])
      text = name.to_s.strip
      return NONE if text.empty?

      exact = @by_name[text.downcase]
      return resolved(exact) if exact

      candidates = @by_key[RailsCodeMap.lookup_key(text)]
      return NONE if candidates.empty?
      return resolved(candidates.first) if candidates.size == 1

      narrowed = narrow(candidates, Array(files))
      narrowed ? resolved(narrowed) : Resolution.new(status: :ambiguous, entry: nil, candidates: candidates.map(&:name))
    end

    # The entries a part's prompt lists: the ones its files define, and the ones related to them
    # or (by a resolvable CamelCase mention) named in its text.
    #
    # @param files [Array<String>] the part's files
    # @param text [String, nil] the part's text
    # @return [Hash{Symbol => Array<Entry>}] `{ own:, related: }`
    def guide_for(files, text: nil)
      files = Array(files)
      own = own_entries(files)
      names = own.to_set(&:name)
      linked = own.flat_map { |entry| @neighbours[entry.name] }.filter_map { |name| @by_name[name.downcase] }
      mentioned = mentions(text).filter_map do |token|
        found = resolve(token, files: files)
        found.entry if found.status == :resolved
      end
      { own: own, related: (linked + mentioned).uniq.reject { |entry| names.include?(entry.name) } }
    end

    # @param files [Array<String>]
    # @return [Array<Entry>] the entries those files define
    def own_entries(files) = Array(files).flat_map { |file| @by_file[file] }.uniq

    private

    def resolved(entry) = Resolution.new(status: :resolved, entry: entry, candidates: [ entry.name ])

    # The part's own files decide first: one candidate defined there is the one; two or more are
    # both in the part, so its answer can't say which it meant. Only when none is defined there do
    # the part's related entries, then its namespaces, decide.
    def narrow(candidates, files)
      defined_here = candidates.select { |entry| entry.files.intersect?(files) }
      return defined_here.size == 1 ? defined_here.first : nil if defined_here.any?

      own = own_entries(files)
      related = own.flat_map { |entry| @neighbours[entry.name] }.to_set
      namespaces = own.to_set { |entry| namespace(entry.name) }
      [ ->(entry) { related.include?(entry.name) },
        ->(entry) { namespaces.include?(namespace(entry.name)) } ].each do |rule|
        kept = candidates.select(&rule)
        return kept.first if kept.size == 1
      end
      nil
    end

    def namespace(name) = name.split("::")[0..-2].join("::")

    def mentions(text)
      return [] if text.blank?

      text.scan(MENTION).uniq.first(MAX_MENTIONS)
    end
  end
end
