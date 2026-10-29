# frozen_string_literal: true

# Explore (UI-4b): the graph canvas, its toolbar and the entity panel, for the operator and the
# guest. The page only carries the starting view; explore_controller.js reads the graph from
# GET /api/v1/graph_data. Every parameter is checked as an id (or 1/2 for depth) and an invalid
# one is ignored, so a bad link opens the root view instead of an error.
#
#   GET /explore?project_id=7 | ?entity_id=42&depth=2 | ?ids=1,2,3 | ?scope=full
#   GET /explore?scoped_entity_id=42  (old /graph links) is read as entity_id
class ExploreController < ApplicationController
  allow_guest :show

  SCOPES = %w[root full project entity search].freeze

  def show
    @explore = start_view
    @project_options = GraphSearch::Page.project_options
    @type_options = GraphSearch::Page.type_options
    @relation_type_options = (GraphVocabulary::RELATION_TYPES + MemoryRelation.distinct.order(:relation_type).limit(50).pluck(:relation_type)).uniq
  end

  private

  # @return [Hash] scope, entity_id, project_id, ids (a comma-separated string), depth
  def start_view
    depth = params[:depth].to_s == "2" ? 2 : 1
    ids = EntityIdList.parse(params[:ids])
    project_id = EntityIdList.id(params[:project_id])
    entity_id = EntityIdList.id(params[:entity_id]) || EntityIdList.id(params[:scoped_entity_id])
    scope = if ids then "search"
    elsif project_id then "project"
    elsif entity_id then "entity"
    elsif params[:scope] == "full" then "full"
    else "root"
    end
    { scope: scope, entity_id: (entity_id if scope == "entity"), project_id: (project_id if scope == "project"),
      ids: (ids&.join(",") if scope == "search"), depth: depth }
  end
end
