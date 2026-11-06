# frozen_string_literal: true

class RailsCodeMap
  # The code entries of a Rails code map (1.75.0): one per Ruby file, for the file's **main
  # constant**, the one its path names under a Zeitwerk root (app/models/goggles_db/badge.rb declares
  # GogglesDb::Badge; RailsAstExtractor::Roles.main_constant?). A file without one (a core_ext patch,
  # a VERSION-only file) is skipped and counted as non-conventional; a constant named like the
  # project or another root (lib/goggles_db.rb's GogglesDb) is skipped and counted as reserved.
  #
  #   entries, non_conventional, reserved = ZeitwerkPaths.entries(extractor.declarations, extractor.superclasses,
  #                                                               reserved: Set["goggles_db"])
  #   entries.first.name    # => "GogglesDb::Badge"
  #   entries.first.aliases # => ["Badge", "goggles_db/badge"]
  #   entries.first.facts   # => ["Defined at app/models/goggles_db/badge.rb:L2"]
  module ZeitwerkPaths
    module_function

    # @param declarations [Hash{String => Array<Hash>}] RailsAstExtractor#declarations
    # @param superclasses [Hash{String => String}] RailsAstExtractor#superclasses
    # @param reserved [Set<String>] project keys (RailsCodeMap.project_key) never mapped
    # @return [Array(Array<Entry>, Integer, Integer)] the entries (by file path), the non-conventional
    #   files and the reserved constants skipped
    def entries(declarations, superclasses, reserved:)
      by_file = Hash.new { |hash, file| hash[file] = [] }
      declarations.each { |qualified, decls| decls.each { |decl| by_file[decl[:file]] << [ qualified, decl ] } }

      found = {}
      non_conventional = 0
      skipped = 0
      by_file.keys.sort.each do |file|
        root, = RailsAstExtractor::Roles.zeitwerk_root(file)
        qualified, decl = root && by_file[file].find { |name, _| RailsAstExtractor::Roles.main_constant?(file, root, name) }
        next non_conventional += 1 unless qualified

        path = file.delete_prefix("#{root}/").delete_suffix(RailsAstExtractor::RUBY_EXT)
        next skipped += 1 if reserved?(qualified, path, reserved)

        fact = "Defined at #{[ file, decl[:line] ].compact.join(':')}"
        found[qualified] = if (entry = found[qualified])
                             # The main constant of two roots (app/models and lib): one entry, both files.
                             entry.with(files: entry.files + [ file ], facts: entry.facts + [ fact ],
                                        keys: (entry.keys + RailsCodeMap.keys_for(file)).uniq)
        else
                             build(qualified, decl, file, path, fact, superclasses[qualified])
        end
      end
      [ found.values, non_conventional, skipped ]
    end

    def build(qualified, decl, file, path, fact, superclass)
      short = qualified.split("::").last
      aliases = [ (short unless short == qualified), path ].compact.uniq
      keys = (suffixes(qualified) + [ path, file ]).flat_map { |text| RailsCodeMap.keys_for(text) }.uniq
      Entry.new(name: qualified, type: decl[:type], kind: decl[:kind], files: [ file ], facts: [ fact ],
                aliases: aliases, keys: keys, superclass: superclass)
    end

    # "A::B::C" => ["A::B::C", "B::C", "C"]: an answer may name a constant by any trailing part.
    def suffixes(qualified)
      parts = qualified.split("::")
      parts.each_index.map { |index| parts.drop(index).join("::") }
    end

    def reserved?(qualified, path, reserved)
      [ qualified, qualified.underscore, path ].any? { |text| reserved.include?(RailsCodeMap.project_key(text)) }
    end
    private_class_method :build, :suffixes, :reserved?
  end
end
