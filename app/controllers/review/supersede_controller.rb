# frozen_string_literal: true

module Review
  # Find & supersede (fact supersede F5): search observation text (inactive ones too), see every
  # match with its guard and verdict, and supersede or retire a selection as one undoable change
  # (FactSupersede::Bulk). Operator only (no allow_guest); CSRF on create. A bulk change never
  # crosses projects: "all projects" lists matches without the actions.
  class SupersedeController < ApplicationController
    PER_PAGE = 50
    UNDO_TOAST_WINDOW = ExploreResponses::UNDO_TOAST_WINDOW

    # GET /review/supersede?q=&project_id=&fact_id=&include_inactive=1
    def index
      load_search
    end

    # POST /review/supersede
    def create
      load_search
      result = FactSupersede::Bulk.call(project: @search.project, observation_ids: params[:observation_ids], action: params[:bulk_action],
                                        replacement: params[:replacement], use_fact_text: params[:use_fact_text] == "1",
                                        reason: params[:reason], fact: @search.fact, rendered_at: rendered_at)
      return refused(result[:error]) unless result[:success]

      flash[:notice] = result[:message]
      flash[:undo] = { "uuid" => result[:change_set_uuid], "label" => result[:message], "until" => UNDO_TOAST_WINDOW.from_now.iso8601 } if result[:undoable]
      redirect_to review_supersede_path(search_params), status: :see_other
    end

    private

    def load_search
      @search = FactSupersede::Search.new(q: params[:q], project_id: params[:project_id], fact_id: params[:fact_id],
                                          include_inactive: params[:include_inactive] == "1")
      @projects = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).order(:name).pluck(:name, :id)
      @entries = Kaminari.paginate_array(@search.entries).page(params[:page]).per(PER_PAGE)
      @rendered_at = Time.current
    end

    def refused(error)
      flash.now[:alert] = error
      render :index, status: :unprocessable_content
    end

    def rendered_at
      Time.iso8601(params[:rendered_at].to_s)
    rescue ArgumentError
      nil
    end

    def search_params
      params.permit(:q, :project_id, :fact_id, :include_inactive).to_h.compact_blank
    end
  end
end
