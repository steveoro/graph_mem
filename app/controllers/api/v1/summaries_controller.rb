# frozen_string_literal: true

module Api
  module V1
    class SummariesController < BaseController
      # POST /api/v1/summarize
      def create
        query = params[:query].to_s.strip
        return render_error("query is required") if query.blank?
        TokenBudget.validate_max_tokens!(params[:max_tokens]) if params.key?(:max_tokens)

        context_scope = GraphMemContext.scoped_entity_scope
        result = SummarizerService.call(
          query: query,
          entity_id: params[:entity_id],
          max_results: params[:max_results],
          max_observations: params[:max_observations],
          observations_per_entity: params[:observations_per_entity],
          max_depth: params[:max_depth],
          include_sources: params.fetch(:include_sources, true),
          scope: params[:scope],
          style: params[:style],
          context_entity_ids: context_scope&.entity_ids,
          context_scope: context_scope,
          temporal_window: TemporalWindow.from_params(
            occurred_after: params[:occurred_after],
            occurred_before: params[:occurred_before],
            as_of: params[:as_of]
          ),
          max_tokens: params[:max_tokens]
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
