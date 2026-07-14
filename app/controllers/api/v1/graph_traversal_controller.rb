# frozen_string_literal: true

module Api
  module V1
    class GraphTraversalController < BaseController
      # GET /api/v1/graph/traverse
      def traverse
        start_entity_id = params[:start_entity_id].to_i
        return render_error("start_entity_id is required") unless start_entity_id.positive?

        result = traversal_service.expand(
          start_entity_id: start_entity_id,
          max_depth: params[:max_depth] || GraphTraversalService::DEFAULT_MAX_DEPTH,
          direction: params[:direction] || GraphTraversalService::DEFAULT_DIRECTION,
          relation_types: relation_types_param,
          max_entities: params[:max_entities] || GraphTraversalService::DEFAULT_MAX_ENTITIES
        )

        if result.nil?
          return render_error("Entity not found with ID: #{start_entity_id}", status: :not_found)
        end

        render json: GraphTraversalSerializer.traversal(result)
      end

      # GET /api/v1/graph/shortest_path
      def shortest_path
        from_entity_id = params[:from_entity_id].to_i
        to_entity_id = params[:to_entity_id].to_i
        return render_error("from_entity_id is required") unless from_entity_id.positive?
        return render_error("to_entity_id is required") unless to_entity_id.positive?

        result = traversal_service.shortest_path(
          from_entity_id: from_entity_id,
          to_entity_id: to_entity_id,
          max_depth: params[:max_depth] || GraphTraversalService::DEFAULT_MAX_DEPTH,
          direction: params[:direction] || GraphTraversalService::DEFAULT_DIRECTION,
          relation_types: relation_types_param
        )

        case result
        when :missing_from
          render_error("Entity not found with ID: #{from_entity_id}", status: :not_found)
        when :missing_to
          render_error("Entity not found with ID: #{to_entity_id}", status: :not_found)
        else
          render json: GraphTraversalSerializer.path(result)
        end
      end

      private

      def traversal_service
        @traversal_service ||= GraphTraversalService.new
      end

      def relation_types_param
        raw = params[:relation_types]
        return nil if raw.blank?

        raw.is_a?(Array) ? raw : raw.to_s.split(",").map(&:strip)
      end
    end
  end
end
