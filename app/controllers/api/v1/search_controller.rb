# frozen_string_literal: true

module Api
  module V1
    class SearchController < BaseController
      # GET /api/v1/search/subgraph
      def subgraph
        query = params[:q]
        return render_error("q parameter is required") if query.blank?

        search_in_name = params.fetch(:search_in_name, "true") == "true"
        search_in_type = params.fetch(:search_in_type, "true") == "true"
        search_in_aliases = params.fetch(:search_in_aliases, "true") == "true"
        search_in_observations = params.fetch(:search_in_observations, "true") == "true"
        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        unless search_in_name || search_in_type || search_in_aliases || search_in_observations
          return render_error("At least one search field must be enabled")
        end

        like_term = "%#{query.downcase}%"
        base = MemoryEntity.distinct
        conditions = []

        conditions << "LOWER(memory_entities.name) LIKE :q" if search_in_name
        conditions << "LOWER(memory_entities.entity_type) LIKE :q" if search_in_type
        conditions << "LOWER(memory_entities.aliases) LIKE :q" if search_in_aliases
        if search_in_observations
          base = base.joins(:memory_observations) unless base.joins_values.include?(:memory_observations)
          conditions << "LOWER(memory_observations.content) LIKE :q"
        end

        matching_ids = base.where(conditions.join(" OR "), q: like_term).pluck(:id).uniq

        begin
          vector_results = VectorSearchStrategy.new.search(query, limit: per_page * 2)
          matching_ids = (matching_ids + vector_results.map { |r| r.entity.id }).uniq
        rescue StandardError
        end

        context_ids = GraphMemContext.scoped_entity_ids
        if context_ids.present?
          ctx = context_ids.to_set
          in_ctx, out_ctx = matching_ids.partition { |id| ctx.include?(id) }
          matching_ids = in_ctx + out_ctx
        end

        total = matching_ids.length
        offset = (page - 1) * per_page
        page_ids = matching_ids.slice(offset, per_page) || []

        entities = []
        relations = []

        if page_ids.any?
          db_entities = MemoryEntity.where(id: page_ids).includes(:memory_observations)
          entities = db_entities.map { |e| entity_json(e) }

          relations = MemoryRelation.where(from_entity_id: page_ids, to_entity_id: page_ids).map { |r| relation_json(r) }
        end

        render json: {
          entities: entities,
          relations: relations,
          pagination: { total_entities: total, per_page: per_page, current_page: page, total_pages: [ (total.to_f / per_page).ceil, 1 ].max }
        }
      end

      # POST /api/v1/search/subgraph_by_ids
      def subgraph_by_ids
        ids = params[:entity_ids]
        unless ids.is_a?(Array) && ids.any?
          return render_error("entity_ids array is required and must not be empty")
        end

        ids = ids.map(&:to_i).uniq
        entities = MemoryEntity.where(id: ids).includes(:memory_observations).map { |e| entity_json(e) }
        relations = MemoryRelation.where(from_entity_id: ids, to_entity_id: ids).map { |r| relation_json(r) }

        render json: { entities: entities, relations: relations }
      end

      private

      def entity_json(entity)
        {
          entity_id: entity.id, name: entity.name, entity_type: entity.entity_type, aliases: entity.aliases,
          observations: entity.memory_observations.map { |o| { observation_id: o.id, content: o.content, created_at: o.created_at.iso8601, updated_at: o.updated_at.iso8601 } },
          created_at: entity.created_at.iso8601, updated_at: entity.updated_at.iso8601
        }
      end

      def relation_json(rel)
        { relation_id: rel.id, from_entity_id: rel.from_entity_id, to_entity_id: rel.to_entity_id, relation_type: rel.relation_type, created_at: rel.created_at.iso8601, updated_at: rel.updated_at.iso8601 }
      end
    end
  end
end
