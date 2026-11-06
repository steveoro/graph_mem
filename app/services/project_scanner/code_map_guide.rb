# frozen_string_literal: true

class ProjectScanner
  # Puts a Rails project's code map (RailsCodeMap, 1.75.0) between the model and the graph, part by
  # part (ChunkedExtraction's `guide:`):
  #
  # - **The prompt** lists the code entities the part's files define ("use exactly these names and
  #   types"), the ones related to them or named in the part, and that a declared gem is a Gem
  #   (ExtractionPrompt's code-map section).
  # - **The answer** is canonicalized before it is merged: an item the map resolves
  #   (RailsCodeMap::Map#resolve, narrowed by the part's files) takes the map's name and type, and
  #   loses the model's aliases and `part_of` relations (the skeleton owns containment); an item or a
  #   relation target several entries could mean is dropped and counted; any other item keeps the
  #   model's name and type, except that a declared gem's name is typed Gem. Names of Project roots
  #   aren't in the map, so ProjectLinks still decides them.
  #
  #   guide = ProjectScanner::CodeMapGuide.new(map)
  #   guide.prompt_guide(["app/models/goggles_db/badge.rb"], text) # => { own: ["GogglesDb::Badge (Model)"], related: [...], gems: true }
  #   guide.canonicalize(answer, ["README.md"])                     # => the answer, with mapped names
  #   guide.counts # => { items_mapped: 4, items_dropped: 1, targets_dropped: 0, gems_typed: 2 }
  class CodeMapGuide
    GEM_TYPE = "Gem"

    # @return [Hash{Symbol => Integer}]
    attr_reader :counts

    # @param map [RailsCodeMap::Map] a non-empty map
    def initialize(map)
      @map = map
      @counts = { items_mapped: 0, items_dropped: 0, targets_dropped: 0, gems_typed: 0 }
    end

    # @param files [Array<String>] the part's files, relative to the root
    # @param text [String] the part's text
    # @return [Hash, nil] ExtractionPrompt's `guide:`, nil when there's nothing to list
    def prompt_guide(files, text)
      found = @map.guide_for(files, text: text)
      guide = { own: found[:own].map { |entry| label(entry) }, related: found[:related].map { |entry| label(entry) },
                gems: @map.gems.any? }
      guide if guide[:own].any? || guide[:related].any? || guide[:gems]
    end

    # @param data [Object] one part's parsed answer
    # @param files [Array<String>] the part's files
    # @return [Object] the answer with its items canonicalized (anything else unchanged)
    def canonicalize(data, files)
      return data unless ExtractionMerger.usable?(data)

      data.merge("architecture" => data["architecture"].filter_map { |item| canonical_item(item, Array(files)) })
    end

    private

    def label(entry) = "#{entry.name} (#{entry.type})"

    def canonical_item(item, files)
      return item unless item.is_a?(Hash) && item["entity"].is_a?(Hash)

      entity = item["entity"]
      found = @map.resolve(entity["name"], files: files)
      case found.status
      when :ambiguous
        @counts[:items_dropped] += 1
        nil
      when :resolved
        @counts[:items_mapped] += 1
        relations = canonical_relations(item["relations"], files).reject { |relation| part_of?(relation) }
        item.merge("entity" => entity.except("aliases").merge("name" => found.entry.name, "type" => found.entry.type),
                   "relations" => relations)
      else
        item.merge("entity" => gem_typed(entity), "relations" => canonical_relations(item["relations"], files))
      end
    end

    def canonical_relations(relations, files)
      Array(relations).filter_map do |relation|
        next relation unless relation.is_a?(Hash)

        found = @map.resolve(relation["to"], files: files)
        case found.status
        when :ambiguous
          @counts[:targets_dropped] += 1
          nil
        when :resolved then relation.merge("to" => found.entry.name)
        else relation
        end
      end
    end

    def gem_typed(entity)
      name = entity["name"].to_s.strip
      return entity if name.empty? || !@map.gem?(name) || entity["type"].to_s.strip.casecmp?(GEM_TYPE)

      @counts[:gems_typed] += 1
      entity.merge("type" => GEM_TYPE)
    end

    def part_of?(relation)
      relation.is_a?(Hash) && MemoryRelation.canonical_relation_type(relation["type"].to_s.strip) == "part_of"
    end
  end
end
