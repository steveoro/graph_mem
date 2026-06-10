# frozen_string_literal: true

class DreamStateStatusTool < ApplicationTool
  def self.tool_name
    "dream_state_status"
  end

  description "Report the current dream-state compaction run: status, phase, cursor position, and stats. " \
    "Use to check whether background graph optimization is running or paused."

  def call
    CompactionRunner.status_snapshot
  rescue StandardError => e
    logger.error "DreamStateStatusTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end
