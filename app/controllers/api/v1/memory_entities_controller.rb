# frozen_string_literal: true

require_dependency "memory_entity"

module Api
  module V1
    class MemoryEntitiesController < BaseController
      before_action :set_entity, only: [ :show, :update, :destroy, :merge ]

      # GET /api/v1/memory_entities
      def index
        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        entities = ::MemoryEntity.order(:id)
        total = entities.count
        paginated = entities.offset((page - 1) * per_page).limit(per_page)

        render json: {
          entities: paginated.as_json(only: [ :id, :name, :entity_type, :aliases, :description, :memory_observations_count, :created_at, :updated_at ]),
          pagination: { total_entities: total, per_page: per_page, current_page: page, total_pages: [ (total.to_f / per_page).ceil, 1 ].max }
        }
      end

      # GET /api/v1/memory_entities/:id
      def show
        render json: {
          id: @memory_entity.id,
          name: @memory_entity.name,
          entity_type: @memory_entity.entity_type,
          aliases: @memory_entity.aliases,
          description: @memory_entity.description,
          memory_observations_count: @memory_entity.memory_observations_count,
          created_at: @memory_entity.created_at.iso8601,
          updated_at: @memory_entity.updated_at.iso8601,
          observations: @memory_entity.memory_observations.map { |o|
            { id: o.id, content: o.content, memory_entity_id: o.memory_entity_id, created_at: o.created_at.iso8601, updated_at: o.updated_at.iso8601 }
          },
          relations_from: @memory_entity.relations_from.map { |r|
            { relation_id: r.id, to_entity_id: r.to_entity_id, to_entity_name: r.to_entity&.name, relation_type: r.relation_type }
          },
          relations_to: @memory_entity.relations_to.map { |r|
            { relation_id: r.id, from_entity_id: r.from_entity_id, from_entity_name: r.from_entity&.name, relation_type: r.relation_type }
          }
        }
      end

      # POST /api/v1/memory_entities
      def create
        @memory_entity = ::MemoryEntity.new(entity_params)

        if @memory_entity.save
          render json: @memory_entity, status: :created, location: api_v1_memory_entity_url(@memory_entity)
        else
          render_validation_errors(@memory_entity)
        end
      end

      # GET /api/v1/memory_entities/search
      def search
        query = params[:q]
        if query.present?
          strategy = HybridSearchStrategy.new
          results = strategy.search(query, semantic: true, context_entity_ids: GraphMemContext.scoped_entity_ids)
          render json: results.map(&:to_h)
        else
          render json: []
        end
      end

      # PATCH/PUT /api/v1/memory_entities/:id
      def update
        if request.put?
          missing = []
          missing << "name" unless params.dig(:memory_entity, :name).present?
          missing << "entity_type" unless params.dig(:memory_entity, :entity_type).present?
          if missing.any?
            return render_error("PUT requires all fields: #{missing.join(', ')}")
          end
        end

        if @memory_entity.update(entity_params)
          render json: @memory_entity
        else
          render_validation_errors(@memory_entity)
        end
      end

      # DELETE /api/v1/memory_entities/:id
      def destroy
        @memory_entity.destroy!
        head :no_content
      end

      # POST /api/v1/memory_entities/:id/merge_into/:target_id
      def merge
        source_entity = @memory_entity
        target_entity = ::MemoryEntity.find(params[:target_id])

        ActiveRecord::Base.transaction do
          target_entity.aliases = (target_entity.aliases.split(/,\|\;/) + source_entity.aliases.split(/,\|\;/)).uniq.join(",")
          target_entity.save!
          source_entity.memory_observations.update_all(memory_entity_id: target_entity.id)

          ::MemoryRelation.where(from_entity_id: source_entity.id)
                          .where.not(to_entity_id: target_entity.id)
                          .update_all(from_entity_id: target_entity.id)

          ::MemoryRelation.where(to_entity_id: source_entity.id)
                          .where.not(from_entity_id: target_entity.id)
                          .update_all(to_entity_id: target_entity.id)

          ::MemoryRelation.where(from_entity_id: source_entity.id, to_entity_id: target_entity.id).destroy_all
          ::MemoryRelation.where(from_entity_id: target_entity.id, to_entity_id: source_entity.id).destroy_all

          target_entity.update_column(:memory_observations_count, target_entity.memory_observations.count)

          source_entity.destroy!
        end

        head :no_content
      rescue ActiveRecord::RecordNotFound
        render_error("Target MemoryEntity not found when attempting to merge.", status: :not_found)
      rescue ActiveRecord::RecordInvalid => e
        render_error("Merge failed: #{e.message}")
      end

      private

      def set_entity
        @memory_entity = ::MemoryEntity.includes(:memory_observations, :relations_from, :relations_to).find(params[:id])
      end

      def entity_params
        params.require(:memory_entity).permit(:name, :entity_type, :aliases, :description)
      end
    end
  end
end
