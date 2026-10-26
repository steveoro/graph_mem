# frozen_string_literal: true

class PagesController < ApplicationController
  allow_guest :home, :graph

  def home
    redirect_to search_path and return if guest_signed_in?

    @snapshot = MaintenanceDashboardSnapshot.call
    @compaction = @snapshot[:compaction]
    @graph_stats = @snapshot[:graph_stats]
    @latest_reports = @snapshot[:latest_reports]
    @schedules = @snapshot[:schedules]
    @cursor_entity = @snapshot[:cursor_entity]
    @embeddings = @snapshot[:embeddings]
    @agent_contexts = @snapshot[:agent_contexts]
    @project_scans = @snapshot.dig(:operations, :project_scans) || []
    @project_scan_skills = @snapshot.dig(:operations, :project_scan_skills) || []
    @scan_reviews = @snapshot[:scan_reviews] || { count: 0, items: [] }
    @refreshed_at = @snapshot[:refreshed_at]
  end

  def graph
    @vector_available = EmbeddingService.vector_enabled?
  end
end
