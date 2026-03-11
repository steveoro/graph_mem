# frozen_string_literal: true

module Api
  module V1
    class MemoryRelationsController < BaseController
      before_action :set_relation, only: [ :destroy, :show, :update ]

      # GET /api/v1/memory_relations
      def index
        @memory_relations = MemoryRelation.all
        @memory_relations = @memory_relations.where(from_entity_id: params[:from_entity_id]) if params[:from_entity_id].present?
        @memory_relations = @memory_relations.where(to_entity_id: params[:to_entity_id]) if params[:to_entity_id].present?
        @memory_relations = @memory_relations.where(relation_type: params[:relation_type]) if params[:relation_type].present?

        render json: @memory_relations
      end

      # POST /api/v1/memory_relations
      def create
        from_entity = MemoryEntity.find_by(id: relation_params[:from_entity_id])
        to_entity = MemoryEntity.find_by(id: relation_params[:to_entity_id])

        @memory_relation = MemoryRelation.new(
          from_entity: from_entity,
          to_entity: to_entity,
          relation_type: relation_params[:relation_type]
        )

        if @memory_relation.save
          render json: @memory_relation, status: :created
        else
          render_validation_errors(@memory_relation)
        end
      end

      # GET /api/v1/memory_relations/:id
      def show
        render json: @memory_relation
      end

      # PATCH/PUT /api/v1/memory_relations/:id
      def update
        if @memory_relation.update(update_relation_params)
          render json: @memory_relation
        else
          render_validation_errors(@memory_relation)
        end
      end

      # DELETE /api/v1/memory_relations/:id
      def destroy
        @memory_relation.destroy!
        head :no_content
      end

      private

      def set_relation
        @memory_relation = MemoryRelation.find(params[:id])
      end

      def relation_params
        params.require(:memory_relation).permit(:from_entity_id, :to_entity_id, :relation_type)
      end

      def update_relation_params
        params.require(:memory_relation).permit(:relation_type)
      end
    end
  end
end
