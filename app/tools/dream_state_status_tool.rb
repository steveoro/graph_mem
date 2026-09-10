# frozen_string_literal: true

class DreamStateStatusTool < ApplicationTool
  def self.tool_name
    "dream_state_status"
  end

  description "Report the live dream-state compaction job (status, phase, cursor, stats, timestamps). " \
    "Takes no arguments. Do not use for stored report documents; use `get_maintenance_reports` instead. " \
    "Do not use for individual review-queue rows; use `list_maintenance_review` instead. " \
    "Do not use for graph health totals; use `get_graph_stats` instead. " \
    "Do not use for an on-demand duplicate scan; use `suggest_merges` instead."

  def call
    CompactionRunner.status_snapshot
  rescue StandardError => e
    logger.error "DreamStateStatusTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end
