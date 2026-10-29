# frozen_string_literal: true

module Explore
  # Add relation (the drag menu's type picker, in the explore-dialog frame) and Remove relation
  # (the panel and the edge menu, with turbo_confirm).
  class RelationsController < BaseController
    SUGGESTIONS = 3

    # GET /explore/relations/new?from_id=&to_id=
    def new
      @from = find_entity(params[:from_id])
      @to = find_entity(params[:to_id])
      @suggested = suggested_types(@from, @to)
      @types = @suggested + (GraphVocabulary::RELATION_TYPES - @suggested)
    end

    # POST /explore/relations (from_id, to_id, relation_type)
    def create
      from = find_entity(params[:from_id])
      to = find_entity(params[:to_id])
      respond_with_explore(edits.add_relation(from, to, params[:relation_type]), entity: from)
    end

    # DELETE /explore/relations/:id
    def destroy
      id = EntityIdList.id(params[:id].to_s)
      raise ActiveRecord::RecordNotFound, "Relation not found" unless id

      relation = MemoryRelation.find(id)
      respond_with_explore(edits.remove_relation(relation), entity: relation.from_entity)
    end

    private

    # The types most used between these two entity types (part_of first under a project root).
    def suggested_types(from, to)
      counts = MemoryRelation.where(from_entity_id: MemoryEntity.where(entity_type: from.entity_type).select(:id),
                                    to_entity_id: MemoryEntity.where(entity_type: to.entity_type).select(:id))
                             .group(:relation_type).order(Arel.sql("COUNT(*) DESC"), :relation_type).limit(10).count.keys
      counts = [ "part_of" ] + counts if to.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      (counts & GraphVocabulary::RELATION_TYPES).first(SUGGESTIONS)
    end
  end
end
