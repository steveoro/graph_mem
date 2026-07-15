# frozen_string_literal: true

module Api
  module V1
    class MemoryObservationsController < BaseController
      before_action :set_memory_entity
      before_action :set_memory_observation, only: [ :destroy, :show, :update ]

      # GET /api/v1/memory_entities/:memory_entity_id/memory_observations
      def index
        @memory_observations = if include_obsolete?
          @memory_entity.memory_observations
        else
          @memory_entity.active_memory_observations
        end
        render json: @memory_observations
      end

      # GET /api/v1/memory_entities/:memory_entity_id/memory_observations/rank
      def rank
        observations = if include_obsolete?
          @memory_entity.memory_observations
        else
          @memory_entity.active_memory_observations
        end
        observations = observations.sort_by { |obs| -obs.trust_score.to_f }
        observations = observations.first(params[:limit].to_i) if params[:limit].to_i > 0

        render json: {
          entity_id: @memory_entity.id,
          name: @memory_entity.name,
          observations: observations.map { |observation|
            MemoryObservationSerializer.call(observation, id_key: :id, content_key: :content, include_entity_id: true)
          }
        }
      end

      # POST /api/v1/memory_entities/:memory_entity_id/memory_observations/detect_contradictions
      def detect_contradictions
        max_distance = params[:max_distance].to_f
        max_distance = ContradictionDetector::DEFAULT_MAX_DISTANCE if max_distance <= 0.0

        max_results = params[:max_results].to_i
        max_results = ContradictionDetector::DEFAULT_MAX_RESULTS if max_results <= 0

        pairs = ContradictionDetector.detect(
          @memory_entity.id,
          max_distance: max_distance,
          max_results: max_results,
          persist: true
        )

        render json: {
          entity_id: @memory_entity.id,
          name: @memory_entity.name,
          candidate_count: pairs.length,
          candidates: pairs.map { |p|
            {
              observation_id_1: p.observation_id_1,
              observation_id_2: p.observation_id_2,
              distance: p.distance,
              confidence: p.confidence
            }
          }
        }
      end

      # POST /api/v1/memory_entities/:memory_entity_id/memory_observations
      def create
        @memory_observation = @memory_entity.memory_observations.build(observation_params)

        if @memory_observation.save
          render json: @memory_observation, status: :created, location: api_v1_memory_entity_memory_observation_url(@memory_entity, @memory_observation)
        else
          render_validation_errors(@memory_observation)
        end
      end

      # GET /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def show
        render json: @memory_observation
      end

      # PATCH/PUT /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def update
        attributes = observation_params.to_h.symbolize_keys
        return render_error("At least one observation attribute must be provided") if attributes.empty?

        result = if supersede?
          @memory_observation.supersede!(attributes, reason: lifecycle_params[:reason])
        else
          @memory_observation.update_active!(attributes)
        end

        render json: result.as_json.merge(
          superseded_observation_id: supersede? ? @memory_observation.id : nil
        )
      rescue MemoryObservation::InactiveObservationError => e
        render_error(e.message)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_errors(e.record)
      end

      # DELETE /api/v1/memory_entities/:memory_entity_id/memory_observations/:id
      def destroy
        @memory_observation.mark_obsolete!(reason: params[:reason])
        head :no_content
      end

      # DELETE /api/v1/memory_entities/:memory_entity_id/memory_observations/delete_duplicates
      def delete_duplicates
        duplicates_deleted = 0

        content_groups = @memory_entity.active_memory_observations.group_by(&:content)

        begin
          Current.deletion_reason = "duplicate"
          content_groups.each do |_content, observations|
            if observations.length > 1
              sorted_observations = observations.sort_by(&:created_at)
              observations_to_delete = sorted_observations[1..-1]

              observations_to_delete.each do |obs|
                obs.destroy!
                duplicates_deleted += 1
              end
            end
          end
        ensure
          Current.deletion_reason = nil
        end

        render json: {
          message: "Successfully deleted #{duplicates_deleted} duplicate observations",
          deleted_count: duplicates_deleted
        }
      rescue => e
        render_error("Failed to delete duplicates: #{e.message}")
      end

      private

      def set_memory_entity
        @memory_entity = MemoryEntity.find(params[:memory_entity_id])
      end

      def set_memory_observation
        @memory_observation = @memory_entity.memory_observations.find(params[:id])
      end

      def observation_params
        params.require(:memory_observation).permit(
          :content,
          :confidence,
          :source,
          :valid_from,
          :valid_until,
          tags: []
        )
      end

      def lifecycle_params
        lifecycle = params.fetch(:memory_observation, ActionController::Parameters.new).permit(:supersede, :reason)
        lifecycle[:supersede] = params[:supersede] if params.key?(:supersede)
        lifecycle[:reason] = params[:reason] if params.key?(:reason) && lifecycle[:reason].blank?
        lifecycle
      end

      def supersede?
        ActiveModel::Type::Boolean.new.cast(lifecycle_params[:supersede])
      end

      def include_obsolete?
        ActiveModel::Type::Boolean.new.cast(params[:include_obsolete])
      end
    end
  end
end
