# frozen_string_literal: true

module Explore
  # Move under… (the drag menu): a confirm card with the subtree size and the project change,
  # then the move (NodeOperationsStrategy#move_to_parent) in an explore.move change set.
  class MovesController < BaseController
    # GET /explore/moves/new?node_id=&parent_id=
    def new
      @node = find_entity(params[:node_id])
      @parent = find_entity(params[:parent_id])
      @card = ExploreMoveCard.new(@node, @parent)
    end

    # POST /explore/moves (node_id, parent_id)
    def create
      node = find_entity(params[:node_id])
      parent = find_entity(params[:parent_id])
      respond_with_explore(edits.move(node, parent), entity: node)
    end
  end
end
