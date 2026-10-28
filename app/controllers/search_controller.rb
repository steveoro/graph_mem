# frozen_string_literal: true

# The Search page (UI-3): every mode and filter of the MCP `search` tool, state in the URL. A
# thin adapter around GraphSearch::Page; operators and guests get the same results.
class SearchController < ApplicationController
  include GuestSearchThrottle

  allow_guest :results
  throttle_guest_search :results

  PERMITTED = [ :q, :mode, :strategy, :project_id, :perspective, :occurred_after, :occurred_before, :as_of,
                :include_obsolete, :page, { types: [], match: [] } ].freeze

  # GET /search
  def results
    @search = GraphSearch::Page.call(search_params)
    render :results, status: (@search.error ? :unprocessable_content : :ok)
  end

  private

  def search_params
    params.permit(*PERMITTED)
  end
end
