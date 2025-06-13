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
