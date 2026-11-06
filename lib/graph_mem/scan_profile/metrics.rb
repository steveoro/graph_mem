# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # The noise metrics of one profiled scan (F-3b, step M): read-only queries on the throwaway
    # graph of one project, plus the rescan's churn and, for the synth repo, recall and precision
    # against its expected list. (A relation to itself never reaches the graph: MemoryRelation
    # refuses it. The scan's noise filter counts those it drops.)
    #
    #   Metrics.call(project, expected: SynthRepo.expected("code"))
    #   # => { "entities" => 6, "entities_without_observations" => 1, "short_observations" => 1, …,
    #   #      "recall" => { "entities" => 1.0, … }, "precision" => { … } }
    #   Metrics.churn(scans["rescan"]) # => 0
    module Metrics
      # Shorter active observations count as short.
      SHORT_OBSERVATION = 20
      # A bare file name or extension: `.rb`, `md`, `user.rb`, `README.md`, `Gemfile`.
      FILENAME = /\A(\.[a-z0-9]{1,8}|(#{ProjectScanner::NoiseFilter::EXTENSIONS})|[\w.-]+\.(#{ProjectScanner::NoiseFilter::EXTENSIONS})|(gem|rake|docker|proc)file)\z/i
      # Names that say nothing about the project: the noise filter's list.
      GENERIC_NAMES = ProjectScanner::NoiseFilter::GENERIC_NAMES
      # The rescan counters that are churn when the code didn't change.
      CHURN_KEYS = %w[entities_created observations_created observations_obsoleted relations_created relations_deleted].freeze

      module_function

      # @param project [MemoryEntity] the scan's Project root
      # @param expected [Hash, nil] SynthRepo.expected(profile), nil for a real repo
      # @return [Hash{String => Object}]
      def call(project, expected: nil)
        entities = MemoryEntity.where(project_id: project.id).to_a
        ids = entities.map(&:id)
        observations = MemoryObservation.active.where(memory_entity_id: ids).pluck(:memory_entity_id, :content)
        relations = MemoryRelation.where(from_entity_id: ids).or(MemoryRelation.where(to_entity_id: ids)).pluck(:from_entity_id, :to_entity_id, :relation_type)
        metrics = graph_metrics(project, entities, observations, relations)
        expected ? metrics.merge(accuracy(project, entities, relations, expected)) : metrics
      end

      # What a rescan of unchanged code created, obsoleted or deleted.
      #
      # @param rescan [Hash, nil] the rescan run's stats (Runner), nil without a rescan
      # @return [Integer, nil]
      def churn(rescan)
        rescan && CHURN_KEYS.sum { |key| rescan[key].to_i }
      end

      # @param name [String]
      # @return [Boolean] a bare file name or extension
      def filename?(name) = name.to_s.strip.match?(FILENAME)

      # @param name [String]
      # @return [Boolean] on GENERIC_NAMES
      def generic?(name) = GENERIC_NAMES.include?(name.to_s.strip.downcase)

      # @param text [String]
      # @return [String] lower case, punctuation as spaces, whitespace squished
      def normalized(text) = ProjectScanner::NoiseFilter.normalized(text)

      def graph_metrics(project, entities, observations, relations)
        per_entity = observations.group_by(&:first).transform_values { |rows| rows.map(&:last) }
        touching = relations.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(from, to, _type), list|
          list[from] << to
          list[to] << from
        end
        {
          "entities" => entities.size,
          "entities_without_observations" => entities.count { |entity| per_entity[entity.id].blank? },
          "observations" => observations.size,
          "short_observations" => observations.count { |_id, content| content.to_s.strip.length < SHORT_OBSERVATION },
          "duplicate_observations" => per_entity.values.sum { |texts| texts.size - texts.map { |text| normalized(text) }.uniq.size },
          "generic_names" => entities.count { |entity| generic?(entity.name) },
          "filename_names" => entities.count { |entity| filename?(entity.name) },
          "root_only_entities" => entities.count { |entity| touching[entity.id].any? && touching[entity.id].all?(project.id) },
          "isolated_entities" => entities.count { |entity| touching[entity.id].empty? },
          # 1.75.0: the entities a Rails code map's skeleton holds (an active fact of its source).
          "code_map_entities" => MemoryObservation.active.where(memory_entity_id: entities.map(&:id), source: RailsCodeMap::SOURCE)
                                                  .distinct.count(:memory_entity_id),
          "types" => entities.map(&:entity_type).tally.sort_by { |type, count| [ -count, type ] }.to_h
        }
      end

      def accuracy(project, entities, relations, expected)
        names = entities.to_h { |entity| [ entity.id, entity.name.downcase ] }.merge(project.id => project.name.downcase)
        found = names.except(project.id).values.uniq
        wanted = expected[:entities].map(&:downcase)
        found_relations = relations.filter_map do |from, to, type|
          [ names[from], MemoryRelation.canonical_relation_type(type), names[to] ] if names[from] && names[to] && type != "part_of"
        end.uniq
        wanted_relations = expected[:relations].map { |from, type, to| [ from.downcase, MemoryRelation.canonical_relation_type(type), to.downcase ] }
        { "recall" => { "entities" => ratio((wanted & found).size, wanted.size), "relations" => ratio((wanted_relations & found_relations).size, wanted_relations.size) },
          "precision" => { "entities" => ratio((wanted & found).size, found.size), "relations" => ratio((wanted_relations & found_relations).size, found_relations.size) },
          "unexpected" => entities.map(&:name).uniq.reject { |name| wanted.include?(name.downcase) }.sort,
          "missed" => expected[:entities].reject { |name| found.include?(name.downcase) } }
      end

      def ratio(part, whole)
        whole.zero? ? nil : (part.to_f / whole).round(3)
      end
      private_class_method :graph_metrics, :accuracy, :ratio
    end
  end
end
