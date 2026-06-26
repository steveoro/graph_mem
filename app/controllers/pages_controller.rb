# frozen_string_literal: true

class PagesController < ApplicationController
  def home
    @snapshot = MaintenanceDashboardSnapshot.call
    @compaction = @snapshot[:compaction]
    @graph_stats = @snapshot[:graph_stats]
    @latest_reports = @snapshot[:latest_reports]
    @schedules = @snapshot[:schedules]
    @cursor_entity = @snapshot[:cursor_entity]
    @embeddings = @snapshot[:embeddings]
    @agent_contexts = @snapshot[:agent_contexts]
    @refreshed_at = @snapshot[:refreshed_at]
  end

  def graph
    @vector_available = EmbeddingService.vector_enabled?
  end
end
