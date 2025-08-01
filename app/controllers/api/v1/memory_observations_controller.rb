module Api
  module V1
    class MemoryObservationsController < ApplicationController
      before_action :set_memory_entity
      before_action :set_memory_observation, only: [ :destroy, :show, :update ]

      # GET /api/v1/memory_entities/:memory_entity_id/memory_observations
      def index
        @memory_observations = @memory_entity.memory_observations
        render json: @memory_observations
      end

      # POST /api/v1/memory_entities/:memory_entity_id/memory_observations
      def create
        @memory_observation = @memory_entity.memory_observations.build(observation_params)

        if @memory_observation.save
          render json: @memory_observation, status: :created, location: api_v1_memory_entity_memory_observation_url(@memory_entity, @memory_observation)
        else
          render json: @memory_observation.errors, status: :unprocessable_content
        end
      end

      # GET /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def show
        render json: @memory_observation
      end

      # PATCH/PUT /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def update
        if @memory_observation.update(observation_params)
          render json: @memory_observation
        else
          render json: @memory_observation.errors, status: :unprocessable_content
        end
      end

      # DELETE /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def destroy
        @memory_observation.destroy!
        head :no_content
      end

      private

      def set_memory_entity
        @memory_entity = MemoryEntity.find(params[:memory_entity_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "MemoryEntity not found" }, status: :not_found
      end

      def set_memory_observation
        @memory_observation = @memory_entity.memory_observations.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "MemoryObservation not found" }, status: :not_found
      end

      def observation_params
        params.require(:memory_observation).permit(:content)
      end
    end
  end
end
