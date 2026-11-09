# frozen_string_literal: true

# The deterministic code map of a Rails project's own code (1.75.0): what a project scan writes as
# its skeleton (ProjectScanner::SkeletonWriter) and hands the model as fixed names and types
# (ProjectScanner::CodeMapGuide), so the model no longer picks, or makes up, the names of classes.
#
# Pure (no database): RailsAstExtractor's declarations give one entry per Ruby file's main constant
# (ZeitwerkPaths), with its fully qualified name, its Rails role type, its aliases (the short name
# and the path) and its "Defined at" fact; app/views gives View and Layout entries (Views);
# config/routes.rb gives a Route entry; the extractor's edges, the routes and the views give the
# relations (Edges); the Gemfile and the root gemspecs give the declared gems (Gems).
#
# A folder that isn't a Rails application or engine (Detector) gets Map::EMPTY, and the scan behaves
# as before. Caps: MAX_FILES files are read and MAX_ENTRIES entries kept; past either the map is
# incomplete, and the skeleton writer then retires nothing.
#
#   map = RailsCodeMap.build("/path/to/goggles_db", reserved_names: ["goggles_db", "GogglesDb"])
#   map.entry("GogglesDb::Badge").type # => "Model"
#   map.counters                       # => { entities: 412, views: 37, relations: 520, … }
class RailsCodeMap
  # The `source` of the facts and the `properties.source` of the relations a skeleton writes.
  SOURCE = "rails_code_map"
  MAX_FILES = 3000
  MAX_ENTRIES = 2000
  ROUTES_FILE = "config/routes.rb"

  # One mapped entity. `name` is its fully qualified constant (or path, for views, layouts and the
  # routes file), `type` its role type, `kind` Class/Module as declared (View, Layout, Route
  # otherwise), `files` the files that define it, `facts` its observations, `aliases` the ones
  # stored on the entity, `keys` its lookup keys (RailsCodeMap.lookup_key) and `superclass` the
  # superclass as written (nil when none).
  Entry = Data.define(:name, :type, :kind, :files, :facts, :aliases, :keys, :superclass)
  # One relation between two entries, by name.
  Edge = Data.define(:from, :to, :relation)

  # @param text [String]
  # @return [String] the lookup form of a name: lowercase, without spaces, "_" and "-"
  #   ("Swimmer Badge", "swimmer_badge" and "SwimmerBadge" are all "swimmerbadge")
  def self.lookup_key(text) = text.to_s.strip.downcase.gsub(/[\s_-]+/, "")

  # @param text [String]
  # @return [Array<String>] the lookup keys of a name or path
  def self.keys_for(text) = [ lookup_key(text) ]

  # @param name [String]
  # @return [String] the project-name form ProjectScanner::ProjectLinks compares ("goggles-db" is "goggles_db")
  def self.project_key(name) = name.to_s.strip.downcase.gsub(/[\s_-]+/, "_")

  # @param root [String] the project folder
  # @param reserved_names [Array<String>] names never mapped: the project's own name and aliases,
  #   and the other Project roots'
  # @param keep [#call, nil] `keep.call(absolute_path)` false skips a file (the scan's file filter)
  # @return [Map] Map::EMPTY when the folder isn't a Rails project
  def self.build(root, reserved_names: [], keep: nil)
    new(root, reserved_names: reserved_names, keep: keep).call
  end

  # @param (see .build)
  def initialize(root, reserved_names: [], keep: nil)
    @root = File.expand_path(root.to_s)
    @reserved = Array(reserved_names).filter_map { |name| self.class.project_key(name).presence }.to_set
    @keep = keep
    @truncated = false
  end

  # @return [Map]
  def call
    gems = Gems.names(@root, keep: @keep)
    return Map::EMPTY unless Detector.rails?(@root, gems: gems)

    extractor = RailsAstExtractor.new(@root, project_name: SOURCE, keep: capped_keep)
    graph = extractor.extract
    code, non_conventional, reserved = ZeitwerkPaths.entries(extractor.declarations, extractor.superclasses, reserved: @reserved)
    views, views_complete = Views.entries(@root, keep: @keep)
    entries = code + views + [ routes_entry ].compact
    edges, route_facts = Edges.build(graph, entries, namespaces: Edges.namespaces(@root, keep: @keep))
    entries = entries.map { |entry| route_facts[entry.name] ? entry.with(facts: entry.facts + [ route_facts[entry.name] ]) : entry }

    kept = entries.first(MAX_ENTRIES)
    names = kept.to_set(&:name)
    edges = edges.select { |edge| names.include?(edge.from) && names.include?(edge.to) }
    complete = !@truncated && views_complete && entries.size <= MAX_ENTRIES
    Map.new(entries: kept, edges: edges, gems: gems, complete: complete, unreadable_files: extractor.unreadable_files,
            counters: { entities: kept.size, views: kept.count { |entry| %w[View Layout].include?(entry.type) },
                        relations: edges.size, unreadable_files: extractor.unreadable_files.size,
                        non_conventional_files: non_conventional, reserved: reserved, complete: complete })
  end

  private

  # The scan's filter, then MAX_FILES: past it every file is refused and the map is incomplete.
  def capped_keep
    read = 0
    lambda do |path|
      next false if @keep && !@keep.call(path)

      read += 1
      @truncated = true if read > MAX_FILES
      read <= MAX_FILES
    end
  end

  def routes_entry
    path = File.join(@root, ROUTES_FILE)
    return nil unless File.file?(path) && !File.symlink?(path) && (@keep.nil? || @keep.call(path))

    Entry.new(name: ROUTES_FILE, type: "Route", kind: "Route", files: [ ROUTES_FILE ], facts: [ "Defined at #{ROUTES_FILE}" ],
              aliases: [], keys: self.class.keys_for(ROUTES_FILE), superclass: nil)
  end
end
