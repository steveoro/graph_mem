# frozen_string_literal: true

class ProjectScanner
  # Merges the answers of a scan's parts into the one `{ "project" => …, "architecture" => [...] }`
  # result reconcile takes (F-3). Pure. Items with the same name and canonical type (both
  # case-insensitive) become one: aliases unioned (first spelling kept), the first non-blank description,
  # observations unioned in part order with the stripped-text dedupe reconcile uses, relations
  # unioned by target and canonical type with the highest confidence kept. The same name with two
  # types stays two items. Parts or items that aren't Hashes, and parts without an `architecture`
  # array, are skipped.
  #
  #   merger = ProjectScanner::ExtractionMerger.new
  #   merger.add(part_one_json)
  #   merger.add(part_two_json)
  #   merger.result                # => { "project" => {...}, "architecture" => [...] }
  #   merger.names(limit: 50)      # => ["SynthWidget", "Alpha Service", ...] most-mentioned first
  class ExtractionMerger
    def initialize
      @project = { "name" => nil, "aliases" => [], "description" => nil }
      @items = {}
      @mentions = Hash.new(0)
    end

    # @param data [Hash, nil] one part's parsed answer
    # @return [Boolean] whether the part was usable (a Hash with an `architecture` array)
    def add(data)
      return false unless self.class.usable?(data)

      add_project(data["project"])
      data["architecture"].each { |item| add_item(item) if item.is_a?(Hash) && item["entity"].is_a?(Hash) }
      true
    end

    # @param data [Object]
    # @return [Boolean] a Hash with an `architecture` array
    def self.usable?(data)
      data.is_a?(Hash) && data["architecture"].is_a?(Array)
    end

    # @return [Hash] the merged extraction
    def result
      { "project" => @project.merge("aliases" => @project["aliases"].dup), "architecture" => @items.values.map { |item| export(item) } }
    end

    # @param limit [Integer]
    # @return [Array<String>] entity names, most mentioned (as an entity or a relation target) first
    def names(limit:)
      @items.values.each_with_index
            .sort_by { |item, position| [ -@mentions[item[:name].downcase], position ] }
            .map { |item, _| item[:name] }.uniq(&:downcase).first(limit)
    end

    private

    def add_project(project)
      return unless project.is_a?(Hash)

      @project["name"] ||= project["name"].to_s.strip.presence
      @project["description"] ||= project["description"].to_s.strip.presence
      union!(@project["aliases"], project["aliases"])
    end

    def add_item(raw)
      entity = raw["entity"]
      name = entity["name"].to_s.strip
      type = ImportEntityResolver.canonical_type(entity["type"])
      return if name.blank? || type.blank?

      # Case-insensitive like the database's collation, which would find "class" for "Class" anyway.
      item = (@items[[ name.downcase, type.downcase ]] ||= { name: name, type: entity["type"].to_s.strip, aliases: [], description: nil,
                                                     observations: [], relations: {} })
      @mentions[name.downcase] += 1
      union!(item[:aliases], entity["aliases"])
      item[:description] ||= entity["description"].to_s.strip.presence
      Array(raw["observations"]).each do |content|
        text = content.to_s.strip
        item[:observations] << text unless text.blank? || item[:observations].include?(text)
      end
      Array(raw["relations"]).each { |relation| add_relation(item, relation) }
    end

    def add_relation(item, relation)
      return unless relation.is_a?(Hash)

      to = relation["to"].to_s.strip
      type = relation["type"].to_s.strip
      return if to.blank? || type.blank?

      @mentions[to.downcase] += 1
      key = [ to.downcase, MemoryRelation.canonical_relation_type(type) ]
      kept = item[:relations][key]
      item[:relations][key] = relation.merge("to" => to, "type" => type) if kept.nil? || relation["confidence"].to_f > kept["confidence"].to_f
    end

    def union!(list, values)
      Array(values).each do |value|
        text = value.to_s.strip
        list << text unless text.blank? || list.any? { |kept| kept.casecmp?(text) }
      end
    end

    def export(item)
      {
        "entity" => { "name" => item[:name], "type" => item[:type], "aliases" => item[:aliases], "description" => item[:description] },
        "observations" => item[:observations],
        "relations" => item[:relations].values
      }
    end
  end
end
