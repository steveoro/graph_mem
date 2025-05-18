module Api
  module V1
    class MemoryRelationsController < ApplicationController
      before_action :set_relation, only: [ :destroy, :show, :update ]

      # GET /api/v1/memory_relations
      def index
        @memory_relations = MemoryRelation.all
        # Apply filters if parameters are present
        @memory_relations = @memory_relations.where(from_entity_id: params[:from_entity_id]) if params[:from_entity_id].present?
        @memory_relations = @memory_relations.where(to_entity_id: params[:to_entity_id]) if params[:to_entity_id].present?
        @memory_relations = @memory_relations.where(relation_type: params[:relation_type]) if params[:relation_type].present?

        render json: @memory_relations
      end

      # POST /api/v1/memory_relations
      def create
        # Find associated entities first
        from_entity = MemoryEntity.find_by(id: relation_params[:from_entity_id])
        to_entity = MemoryEntity.find_by(id: relation_params[:to_entity_id])

        # Build the relation, assigning the found entities (or nil if not found)
        @memory_relation = MemoryRelation.new(
          from_entity: from_entity,
          to_entity: to_entity,
          relation_type: relation_params[:relation_type]
        )

        if @memory_relation.save
          # The location header requires the ID, which is now available.
          # Note: api_v1_memory_relation_url might not exist if routes are nested.
          # If relations are typically accessed via entities, this location might need adjustment
          # or removal depending on API design goals.
          # For now, assuming a direct route `api_v1_memory_relation_path` exists.
          render json: @memory_relation, status: :created # , location: api_v1_memory_relation_url(@memory_relation)
        else
          # Default belongs_to validation errors will now be more accurate
          render json: @memory_relation.errors, status: :unprocessable_entity
        end
      end

      # GET /api/v1/memory_relations/:id
      def show
        render json: @memory_relation
      end

      # PATCH/PUT /api/v1/memory_relations/:id
      def update
        # Only allow relation_type to be updated
        if @memory_relation.update(update_relation_params)
          render json: @memory_relation
        else
          render json: @memory_relation.errors, status: :unprocessable_entity
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
      rescue ActiveRecord::RecordNotFound
        render json: { error: "MemoryRelation not found" }, status: :not_found
      end

      # Strong parameters for creating relations
      def relation_params
        params.require(:memory_relation).permit(:from_entity_id, :to_entity_id, :relation_type)
      end

      # Separate strong parameters for updating relations (only allow relation_type)
      def update_relation_params
        params.require(:memory_relation).permit(:relation_type)
      end
    end
  end
end
