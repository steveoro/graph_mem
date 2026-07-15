# frozen_string_literal: true

module Api
  module V1
    class SummariesController < BaseController
      # POST /api/v1/summarize
      def create
        query = params[:query].to_s.strip
        return render_error("query is required") if query.blank?

        result = SummarizerService.call(
          query: query,
          entity_id: params[:entity_id],
          max_results: params[:max_results],
          max_observations: params[:max_observations],
          max_depth: params[:max_depth],
          include_sources: params.fetch(:include_sources, true),
          style: params[:style],
          context_entity_ids: GraphMemContext.scoped_entity_ids
        )

        render json: result
      rescue ActiveRecord::RecordNotFound
        render_error("Entity not found", status: :not_found)
      rescue ArgumentError => e
        render_error(e.message)
      end
    end
  end
end
