module Api
  module V1
    class GraphDataController < ApplicationController
      def index
        entities = MemoryEntity.all.includes(:memory_observations)
        relations = MemoryRelation.all

        nodes = entities.map do |entity|
          {
            group: "nodes",
            data: {
              id: entity.id.to_s,
              label: entity.name,
              type: entity.entity_type,
              observations_count: entity.memory_observations.count
            }
          }
        end

        edges = relations.map do |relation|
          {
            group: "edges",
            data: {
              id: "r#{relation.id}",
              source: relation.from_entity_id.to_s,
              target: relation.to_entity_id.to_s,
              label: relation.relation_type
            }
          }
        end

        render json: { elements: nodes + edges }
      end
    end
  end
end
