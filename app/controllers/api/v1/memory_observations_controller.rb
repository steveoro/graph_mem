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

      # DELETE /api/v1/memory_entities/:memory_entity_id/memory_observations/delete_duplicates
      def delete_duplicates
        duplicates_deleted = 0

        # Group observations by content to find duplicates
        content_groups = @memory_entity.memory_observations.group_by(&:content)

        content_groups.each do |content, observations|
          # If there are multiple observations with the same content, keep the oldest and delete the rest
          if observations.length > 1
            # Sort by created_at to keep the oldest
            sorted_observations = observations.sort_by(&:created_at)
            observations_to_delete = sorted_observations[1..-1] # All except the first (oldest)

            observations_to_delete.each do |obs|
              obs.destroy!
              duplicates_deleted += 1
            end
          end
        end

        render json: {
          message: "Successfully deleted #{duplicates_deleted} duplicate observations",
          deleted_count: duplicates_deleted
        }
      rescue => e
        render json: { error: "Failed to delete duplicates: #{e.message}" }, status: :unprocessable_content
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
