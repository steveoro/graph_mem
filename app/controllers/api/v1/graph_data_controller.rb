# frozen_string_literal: true

module Api
  module V1
    class GraphDataController < BaseController
      # "Show as graph" (UI-3) sends one page of search results; UI-4b's Explore reuses it.
      MAX_IDS = 100
      IDS_ERROR = "ids must be 1 to #{MAX_IDS} comma-separated entity ids.".freeze

      # GET /api/v1/graph_data(?ids=1,2,3 | ?scoped_entity_id= | ?entity_id= | ?root_only=true)
      def index
        entity_id = params[:entity_id]
        scoped_entity_id = params[:scoped_entity_id]
        root_only = params[:root_only] == "true"

        if params.key?(:ids)
          render_ids_graph(params[:ids])
        elsif scoped_entity_id.present?
          render_scoped_subgraph(scoped_entity_id)
        elsif entity_id.present?
          render_subgraph(entity_id)
        elsif root_only
          render_root_graph
        else
          render_full_graph
        end
      end

      private

      # The given entities and the relations among them only (no hop expansion); unknown ids
      # are skipped. 422 unless ids is 1 to MAX_IDS positive integers, comma-separated.
      def render_ids_graph(raw)
        ids = parse_ids(raw)
        return render_error(IDS_ERROR) unless ids

        entities = MemoryEntity.where(id: ids).includes(:active_memory_observations).order(:id)
        found = entities.map(&:id)
        relations = MemoryRelation.where(from_entity_id: found, to_entity_id: found).includes(:from_entity, :to_entity).order(:id)
        render_graph_data(entities, relations, { focus_entity_ids: found.map(&:to_s) })
      end

      # @return [Array<Integer>, nil] de-duplicated ids, or nil when the list is invalid
      def parse_ids(raw)
        return nil unless raw.is_a?(String)

        parts = raw.split(",", -1).map(&:strip)
        return nil unless parts.all? { |part| part.match?(/\A[1-9]\d{0,18}\z/) }

        ids = parts.map(&:to_i).uniq
        ids if ids.size.between?(1, MAX_IDS)
      end

      def render_full_graph
        entities = MemoryEntity.all.includes(:active_memory_observations)
        relations = MemoryRelation.all
        render_graph_data(entities, relations)
      end

      def render_root_graph
        entities = MemoryEntity.where(entity_type: [ "Project", nil ]).includes(:active_memory_observations)
        entity_ids = entities.pluck(:id)
        relations = MemoryRelation.where(from_entity_id: entity_ids, to_entity_id: entity_ids)
        render_graph_data(entities, relations)
      end

      def render_scoped_subgraph(scoped_entity_id)
        root_entity = MemoryEntity.find(scoped_entity_id)

        child_ids = MemoryRelation
          .where(relation_type: "part_of", to_entity_id: root_entity.id)
          .pluck(:from_entity_id)

        all_ids = ([ root_entity.id ] + child_ids).uniq

        entities = MemoryEntity.where(id: all_ids).includes(:active_memory_observations)
        relations = MemoryRelation.where(from_entity_id: all_ids, to_entity_id: all_ids)

        render_graph_data(entities, relations, { focus_entity_id: scoped_entity_id })
      end

      def render_subgraph(entity_id)
        MemoryEntity.find(entity_id)

        connected_entity_ids = MemoryRelation.where(
          "from_entity_id = ? OR to_entity_id = ?", entity_id, entity_id
        ).pluck(:from_entity_id, :to_entity_id).flatten.uniq

        all_entity_ids = ([ entity_id.to_i ] + connected_entity_ids).uniq

        entities = MemoryEntity.where(id: all_entity_ids).includes(:active_memory_observations)
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
              memory_observations_count: entity.active_memory_observations.size,
              is_focus: options[:focus_entity_id] == entity.id.to_s
            }
          }
        end

        edges = relations.map do |relation|
          {
            group: "edges",
            data: {
              id: "r#{relation.id}",
              relation_id: relation.id,
              source: relation.from_entity_id.to_s,
              target: relation.to_entity_id.to_s,
              label: relation.relation_type,
              weight: relation.weight,
              confidence: relation.confidence,
              properties: relation.properties,
              from_entity_name: relation.from_entity&.name,
              to_entity_name: relation.to_entity&.name
            }
          }
        end

        render json: { elements: nodes + edges, options: options }
      end
    end
  end
end
