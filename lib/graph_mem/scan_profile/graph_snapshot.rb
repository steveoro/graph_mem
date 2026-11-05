# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # What one profiled scan left in the throwaway graph, by name (no ids, which are per run): the
    # project's entities with their type, active observations and outgoing relations, sorted. The
    # report's JSON keeps this shape stable (Report::SCHEMA_VERSION) so a later, separate tool can
    # compare it with another graph.
    #
    #   GraphSnapshot.call(project)
    #   # => [{ "name" => "AlphaService", "type" => "Service", "observations" => ["…"],
    #   #       "relations" => [{ "type" => "depends_on", "to" => "SynthWidget" }] }, …]
    module GraphSnapshot
      module_function

      # @param project [MemoryEntity] the scan's Project root
      # @return [Array<Hash>] the root first, then its entities by name
      def call(project)
        entities = [ project ] + MemoryEntity.where(project_id: project.id).order(:name, :id).to_a
        names = entities.to_h { |entity| [ entity.id, entity.name ] }
        observations = MemoryObservation.active.where(memory_entity_id: names.keys).order(:id).pluck(:memory_entity_id, :content)
                                        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
        relations = MemoryRelation.where(from_entity_id: names.keys).includes(:to_entity).group_by(&:from_entity_id)
        entities.map do |entity|
          { "name" => entity.name, "type" => entity.entity_type, "observations" => observations.fetch(entity.id, []),
            "relations" => Array(relations[entity.id]).map { |rel| { "type" => rel.relation_type, "to" => rel.to_entity&.name } }
                                                      .sort_by { |rel| [ rel["type"], rel["to"].to_s ] } }
        end
      end
    end
  end
end
