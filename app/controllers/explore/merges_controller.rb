# frozen_string_literal: true

module Explore
  # The merge dialog (UI-4b W6). #new renders, in the explore-dialog frame, either an entity picker
  # (same type only, from GraphSearch::Page) or the preview of merging source into target with its
  # digest; #create merges through EntityMergeService: 409 when the graph changed since the
  # preview, 422 on a blocker, nothing written in either case.
  class MergesController < BaseController
    PICKER_LIMIT = 10

    # GET /explore/merges/new?source_id=(&target_id=)(&q=)
    def new
      @source = find_entity(params[:source_id])
      if params[:target_id].present?
        @preview = EntityMergePreview.new(@source.id, find_entity(params[:target_id]).id).call
      else
        @query = params[:q].to_s.strip.first(GraphSearch::Page::MAX_QUERY_LENGTH)
        @candidates = candidates(@source, @query)
      end
    end

    # POST /explore/merges (source_id, target_id, digest)
    def create
      source = find_entity(params[:source_id])
      target = find_entity(params[:target_id])
      source_name = source.name
      result = EntityMergeService.call(source_id: source.id, target_id: target.id, digest: params[:digest], actor: Current.actor)
      if result[:success]
        result = result.merge(message: "Merged '#{source_name}' into '#{target.name}'.", removed: [ source.id ], changed: [ target.id ])
      end
      respond_with_explore(result, entity: result[:success] ? target : source)
    end

    private

    # Same-type entities matching the query (text mode: no embedding call), roots excluded.
    def candidates(source, query)
      return [] if query.blank?

      rows = GraphSearch::Page.call({ "q" => query, "types" => [ source.entity_type ], "mode" => "text" }).rows
      rows.map(&:entity).reject { |entity| entity.id == source.id || entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE }
          .first(PICKER_LIMIT)
    end
  end
end
