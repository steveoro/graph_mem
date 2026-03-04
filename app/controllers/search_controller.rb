# frozen_string_literal: true

class SearchController < ApplicationController
  RESULTS_PER_PAGE = 25

  def results
    @query = params[:q].to_s.strip
    @strategy = %w[text vector].include?(params[:strategy]) ? params[:strategy] : "text"
    @vector_available = EmbeddingService.vector_enabled?

    if @query.blank?
      @results = Kaminari.paginate_array([]).page(1)
      @scoped_counts = {}
      return
    end

    entities = perform_search
    @results = Kaminari.paginate_array(entities).page(params[:page]).per(RESULTS_PER_PAGE)

    page_entity_ids = @results.map(&:id)
    @scoped_counts = MemoryRelation
      .where(relation_type: "part_of", to_entity_id: page_entity_ids)
      .group(:to_entity_id)
      .count
  end

  private

  def perform_search
    if @strategy == "vector" && @vector_available
      vector_search
    else
      text_search
    end
  end

  def text_search
    EntitySearchStrategy.new.search(@query).map(&:entity)
  end

  def vector_search
    strategy = VectorSearchStrategy.new
    entity_results = strategy.search(@query, limit: 100)

    obs_entity_ids = strategy.search_observations(@query, limit: 100)
    obs_entities = MemoryEntity.where(id: obs_entity_ids).index_by(&:id)

    seen_ids = Set.new
    merged = []

    entity_results.each do |sr|
      merged << sr.entity unless seen_ids.include?(sr.entity.id)
      seen_ids.add(sr.entity.id)
    end

    obs_entity_ids.each do |eid|
      next if seen_ids.include?(eid)
      merged << obs_entities[eid] if obs_entities[eid]
      seen_ids.add(eid)
    end

    merged
  end
end
