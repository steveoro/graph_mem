# frozen_string_literal: true

# ActionCable channel for broadcasting export progress updates
#
# Clients subscribe with an export_id and receive progress updates
# as the export job processes each node in the tree
class ExportProgressChannel < ApplicationCable::Channel
  def subscribed
    export_id = params[:export_id]

    if export_id.present?
      stream_from "export_progress_#{export_id}"
    else
      reject
    end
  end

  def unsubscribed
    # Cleanup when channel is unsubscribed
  end

  # Class method to broadcast progress updates
  # @param export_id [String] The export session ID
  # @param progress [Hash] Progress data with :current, :total, :message
  def self.broadcast_progress(export_id, progress)
    ActionCable.server.broadcast(
      "export_progress_#{export_id}",
      {
        type: "progress",
        current: progress[:current],
        total: progress[:total],
        percentage: calculate_percentage(progress[:current], progress[:total]),
        message: progress[:message]
      }
    )
  end

  # Class method to broadcast export completion
  # @param export_id [String] The export session ID
  # @param result [Hash] Result data with :success, :download_path or :error
  def self.broadcast_complete(export_id, result)
    ActionCable.server.broadcast(
      "export_progress_#{export_id}",
      {
        type: "complete",
        success: result[:success],
        download_path: result[:download_path],
        error: result[:error],
        message: result[:message]
      }
    )
  end

  # Class method to broadcast export error
  # @param export_id [String] The export session ID
  # @param error [String] Error message
  def self.broadcast_error(export_id, error)
    ActionCable.server.broadcast(
      "export_progress_#{export_id}",
      {
        type: "error",
        error: error
      }
    )
  end

  private

  def self.calculate_percentage(current, total)
    return 0 if total.nil? || total.zero?

    ((current.to_f / total) * 100).round(1)
  end
end
