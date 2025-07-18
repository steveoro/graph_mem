module Api
  module V1
    class GraphDataController < ApplicationController
      def index
        # Check if we're filtering to root level or getting a subgraph
        entity_id = params[:entity_id]
        root_only = params[:root_only] == 'true'
        
        if entity_id.present?
          # Get subgraph for specific entity
          render_subgraph(entity_id)
        elsif root_only
          # Get only root-level entities (Project type or nil type)
          render_root_graph
        else
          # Get full graph (existing behavior)
          render_full_graph
        end
      end

      private

      def render_full_graph
        entities = MemoryEntity.all.includes(:memory_observations)
        relations = MemoryRelation.all
        render_graph_data(entities, relations)
      end

      def render_root_graph
        # Only show entities with type 'Project' or nil (root-level)
        entities = MemoryEntity.where(entity_type: ['Project', nil]).includes(:memory_observations)
        # Only show relations between root-level entities
        entity_ids = entities.pluck(:id)
        relations = MemoryRelation.where(from_entity_id: entity_ids, to_entity_id: entity_ids)
        render_graph_data(entities, relations)
      end

      def render_subgraph(entity_id)
        # Get the main entity
        main_entity = MemoryEntity.find(entity_id)
        
        # Get all directly connected entities (one hop)
        connected_entity_ids = MemoryRelation.where(
          "from_entity_id = ? OR to_entity_id = ?", entity_id, entity_id
        ).pluck(:from_entity_id, :to_entity_id).flatten.uniq
        
        # Include the main entity
        all_entity_ids = ([entity_id.to_i] + connected_entity_ids).uniq
        
        entities = MemoryEntity.where(id: all_entity_ids).includes(:memory_observations)
        relations = MemoryRelation.where(
          from_entity_id: all_entity_ids,
          to_entity_id: all_entity_ids
        )
        
        render_graph_data(entities, relations, { focus_entity_id: entity_id })
      end

      def render_graph_data(entities, relations, options = {})
        nodes = entities.map do |entity|
          {
            group: "nodes",
            data: {
              id: entity.id.to_s,
              label: entity.name,
              type: entity.entity_type,
              aliases: entity.aliases,
              observations_count: entity.memory_observations.count,
              is_focus: options[:focus_entity_id] == entity.id.to_s
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

        render json: { elements: nodes + edges, options: options }
      end
    end
  end
end
