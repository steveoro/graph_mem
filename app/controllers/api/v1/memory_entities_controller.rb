# frozen_string_literal: true

# Ensure model is loaded (useful in development/testing environments)
require_dependency "memory_entity"

module Api
  module V1
    class MemoryEntitiesController < ApplicationController
      before_action :set_entity, only: [ :show, :update, :destroy ]

      # GET /api/v1/memory_entities
      def index
        @memory_entities = ::MemoryEntity.all
        render json: @memory_entities
      end

      # GET /api/v1/memory_entities/:id
      def show
        render json: @memory_entity
      end

      # POST /api/v1/memory_entities
      def create
        @memory_entity = ::MemoryEntity.new(entity_params)

        if @memory_entity.save
          render json: @memory_entity, status: :created, location: api_v1_memory_entity_url(@memory_entity)
        else
          render json: @memory_entity.errors, status: :unprocessable_entity
        end
      end

      # GET /api/v1/memory_entities/search
      def search
        query = params[:q]
        if query.present?
          @memory_entities = ::MemoryEntity.where("(LOWER(name) LIKE ?) OR (LOWER(entity_type) LIKE ?) OR (LOWER(aliases) LIKE ?)",
                                                 "%#{query.downcase}%", "%#{query.downcase}%", "%#{query.downcase}%")
        else
          @memory_entities = ::MemoryEntity.none
        end
        render json: @memory_entities
      end

      # PATCH/PUT /api/v1/memory_entities/:id
      def update
        if @memory_entity.update(entity_params)
          render json: @memory_entity
        else
          render json: @memory_entity.errors, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/memory_entities/:id
      def destroy
        @memory_entity.destroy!
        head :no_content
      end

      # POST /api/v1/memory_entities/:id/merge_into/:target_id
      def merge
        source_entity = @memory_entity # Set by before_action :set_entity for params[:id]
        target_entity = ::MemoryEntity.find(params[:target_id])

        ActiveRecord::Base.transaction do
          # Re-assign observations from source to target
          source_entity.memory_observations.update_all(memory_entity_id: target_entity.id)

          # Re-assign relations where source_entity is the 'from' entity
          # Avoid creating self-loops if target_entity was the original 'to'
          ::MemoryRelation.where(from_entity_id: source_entity.id)
                          .where.not(to_entity_id: target_entity.id)
                          .update_all(from_entity_id: target_entity.id)

          # Re-assign relations where source_entity is the 'to' entity
          # Avoid creating self-loops if target_entity was the original 'from'
          ::MemoryRelation.where(to_entity_id: source_entity.id)
                          .where.not(from_entity_id: target_entity.id)
                          .update_all(to_entity_id: target_entity.id)

          # Delete relations that were directly between source and target to prevent self-loops
          ::MemoryRelation.where(from_entity_id: source_entity.id, to_entity_id: target_entity.id).destroy_all
          ::MemoryRelation.where(from_entity_id: target_entity.id, to_entity_id: source_entity.id).destroy_all

          # Note: This simplified merge might create duplicate relations if, for example,
          # A->C and B->C exist, and A is merged into B, resulting in two B->C relations
          # if (from_entity_id, to_entity_id, relation_type) is not unique.
          # This matches the behavior of the existing rake task `graph:merge_entities`.
          # A robust solution would involve a unique index in the database or more complex de-duplication logic here.

          # Delete the source entity
          source_entity.destroy!
        end

        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Target MemoryEntity not found when attempting to merge." }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "Merge failed: #{e.message}" }, status: :unprocessable_entity
      end

      private

      # Use callbacks to share common setup or constraints between actions.
      def set_entity
        @memory_entity = ::MemoryEntity.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "MemoryEntity not found" }, status: :not_found
      end

      # Only allow a list of trusted parameters through.
      def entity_params
        # Allow name and entity_type. observations_count is handled by counter_cache.
        params.require(:memory_entity).permit(:name, :entity_type)
      end
    end
  end
end
