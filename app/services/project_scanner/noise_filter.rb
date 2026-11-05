# frozen_string_literal: true

class ProjectScanner
  # Drops conservative noise from a scan's merged LLM extraction before reconcile (F-3b, step N).
  # Pure: it never reads the graph. The rules, in the order they run, are RULES; each one has a
  # synthetic spec, and a rule that drops an item of the synth repo's expected list is removed.
  # The deterministic fallback isn't filtered (it keeps its old behaviour).
  #
  #   data, dropped = ProjectScanner::NoiseFilter.call(merged)
  #   dropped # => { "duplicate_observations" => 1, "self_relations" => 1, "generic_items" => 2, "empty_items" => 1 }
  module NoiseFilter
    # Each rule and what it drops.
    RULES = {
      "duplicate_observations" => "an observation equal to an earlier one of the same item, ignoring case, punctuation and spacing",
      "self_relations" => "a relation from an item to itself (its name or one of its aliases)",
      "generic_items" => "an item named only by a file extension or a GENERIC_NAMES word, with at most one observation",
      "empty_items" => "an item with no observations and no relations that no other item relates to"
    }.freeze
    # Names that say nothing about a project (compared case-insensitively).
    GENERIC_NAMES = %w[util utils utilities helper helpers config configuration main base common misc core
                       manager service services model models module class function file files data index tool tools].freeze
    # File extensions (`rb`, `.md`): an item named only by one is noise.
    EXTENSIONS = "rb|md|js|ts|py|ya?ml|json|toml|txt|erb|haml|css|scss|html|sh|lock|gemspec|rake"
    EXTENSION_NAME = /\A\.?(#{EXTENSIONS})\z/i
    # The most observations a generic item may have and still be dropped.
    GENERIC_MAX_OBSERVATIONS = 1

    module_function

    # @param data [Hash] the merged extraction (`{ "project" => …, "architecture" => [...] }`)
    # @return [Array(Hash, Hash{String => Integer})] the filtered extraction and the count each
    #   rule dropped (every rule listed, zeros included)
    def call(data)
      dropped = RULES.keys.index_with(0)
      items = Array(data["architecture"]).map { |item| clean_item(item, dropped) }
      items = drop(items, dropped, "generic_items") { |item| generic?(item) }
      targets = items.flat_map { |item| item["relations"].map { |relation| relation["to"].to_s.strip.downcase } }.to_set
      items = drop(items, dropped, "empty_items") { |item| empty?(item, targets) }
      [ data.merge("architecture" => items), dropped ]
    end

    # @param text [String]
    # @return [String] lower case, punctuation as spaces, whitespace squished
    def normalized(text)
      text.to_s.downcase.gsub(/[[:punct:]]+/, " ").squish
    end

    # @param name [String]
    # @return [Boolean] only a file extension, or on GENERIC_NAMES
    def generic_name?(name)
      name = name.to_s.strip
      name.match?(EXTENSION_NAME) || GENERIC_NAMES.include?(name.downcase)
    end

    # The item with duplicate observations and self-relations removed (counted in `dropped`).
    def clean_item(item, dropped)
      seen = Set.new
      observations = Array(item["observations"]).select { |text| seen.add?(normalized(text)) }
      own = ([ item.dig("entity", "name") ] + Array(item.dig("entity", "aliases"))).map { |name| name.to_s.strip.downcase }
      relations = Array(item["relations"]).reject { |relation| own.include?(relation["to"].to_s.strip.downcase) }
      dropped["duplicate_observations"] += Array(item["observations"]).size - observations.size
      dropped["self_relations"] += Array(item["relations"]).size - relations.size
      item.merge("observations" => observations, "relations" => relations)
    end

    def drop(items, dropped, rule, &rule_matches)
      gone, kept = items.partition(&rule_matches)
      dropped[rule] += gone.size
      kept
    end

    def generic?(item)
      generic_name?(item.dig("entity", "name")) && item["observations"].size <= GENERIC_MAX_OBSERVATIONS
    end

    def empty?(item, targets)
      item["observations"].empty? && item["relations"].empty? && !targets.include?(item.dig("entity", "name").to_s.strip.downcase)
    end
    private_class_method :clean_item, :drop, :generic?, :empty?
  end
end
