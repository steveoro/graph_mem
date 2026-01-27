# frozen_string_literal: true

require_relative "../../lib/import_session"

class DataExchangeController < ApplicationController
  # Skip CSRF for API-like endpoints (file download and JSON responses)
  skip_before_action :verify_authenticity_token, only: [ :export, :export_async, :move_node, :merge_node, :delete_node ]

  # GET /data_exchange/export?ids[]=1&ids[]=2
  # Returns JSON file with selected root nodes and all their children (sync/direct download)
  def export
    entity_ids = params[:ids]

    if entity_ids.blank?
      return render json: { error: "No entity IDs provided" }, status: :unprocessable_content
    end

    strategy = ExportStrategy.new
    json_content = strategy.export_json(entity_ids)

    filename = "graph_mem_export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"

    send_data json_content,
              type: "application/json",
              disposition: "attachment",
              filename: filename
  end

  # POST /data_exchange/export_async
  # Starts an async export job with progress updates via ActionCable
  def export_async
    entity_ids = params[:ids]

    if entity_ids.blank?
      return render json: { error: "No entity IDs provided" }, status: :unprocessable_content
    end

    export_id = SecureRandom.uuid

    # Enqueue the export job
    ExportJob.perform_later(export_id, entity_ids)

    render json: {
      success: true,
      export_id: export_id,
      message: "Export started. Subscribe to the progress channel for updates."
    }
  end

  # GET /data_exchange/download_export?export_id=xxx
  # Download a completed async export file
  def download_export
    export_id = params[:export_id]

    if export_id.blank?
      return render json: { error: "No export ID provided" }, status: :unprocessable_content
    end

    filepath = ExportJob.download_path(export_id)

    unless File.exist?(filepath)
      return render json: { error: "Export file not found. It may have expired." }, status: :not_found
    end

    filename = "graph_mem_export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json"

    send_file filepath,
              type: "application/json",
              disposition: "attachment",
              filename: filename
  end

  # GET /data_exchange/root_nodes
  # Returns list of root nodes for the export selection UI (JSON API)
  def root_nodes
    strategy = ExportStrategy.new
    nodes = strategy.root_nodes

    render json: {
      nodes: nodes.map do |entity|
        {
          id: entity.id,
          name: entity.name,
          entity_type: entity.entity_type,
          observations_count: entity.memory_observations_count
        }
      end
    }
  end

  # POST /data_exchange/import_upload
  # Receives JSON file, runs matching, stores in temp files, redirects to review
  def import_upload
    unless params[:file].present?
      flash[:error] = "Please select a file to import"
      return redirect_to root_path
    end

    begin
      file_content = params[:file].read
      json_data = JSON.parse(file_content)

      strategy = ImportMatchingStrategy.new
      match_result = strategy.match(json_data)

      unless match_result[:success]
        flash[:error] = match_result[:error]
        return redirect_to root_path
      end

      # Store in temp files instead of session to avoid cookie overflow
      import_session_id = ImportSession.create(
        import_data: json_data,
        matches: serialize_match_results(match_result[:match_results]),
        stats: match_result[:stats],
        version: match_result[:version]
      )

      # Only store the small session ID in the cookie
      session[:import_session_id] = import_session_id

      redirect_to import_review_data_exchange_index_path
    rescue JSON::ParserError => e
      flash[:error] = "Invalid JSON file: #{e.message}"
      redirect_to root_path
    rescue StandardError => e
      Rails.logger.error "Import upload failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      flash[:error] = "Import failed: #{e.message}"
      redirect_to root_path
    end
  end

  # GET /data_exchange/import_review
  # Shows matching results page with operator controls
  def import_review
    import_session_id = session[:import_session_id]

    unless ImportSession.exists?(import_session_id)
      flash[:error] = "No import data found. Please upload a file first."
      return redirect_to root_path
    end

    @matches = ImportSession.load_matches(import_session_id)
    @stats = ImportSession.load_stats(import_session_id)
    @version = ImportSession.load_version(import_session_id)

    # Get available parent entities for the "Make children of" dropdown
    @available_parents = ExportStrategy.new.root_nodes.map do |entity|
      { id: entity.id, name: entity.name, entity_type: entity.entity_type }
    end
  end

  # POST /data_exchange/import_execute
  # Execute import based on operator decisions
  def import_execute
    import_session_id = session[:import_session_id]

    unless ImportSession.exists?(import_session_id)
      flash[:error] = "No import data found. Please upload a file first."
      return redirect_to root_path
    end

    import_data = ImportSession.load_data(import_session_id)
    decisions = build_decisions_from_params

    strategy = ImportExecutionStrategy.new
    report = strategy.execute(import_data, decisions)

    # Store report in temp file and clear import data files
    ImportSession.store_report(import_session_id, report.to_h)

    redirect_to import_report_data_exchange_index_path
  end

  # GET /data_exchange/import_report
  # Shows the import results report
  def import_report
    import_session_id = session[:import_session_id]

    unless ImportSession.report_exists?(import_session_id)
      flash[:error] = "No import report found."
      return redirect_to root_path
    end

    @report = ImportSession.load_report(import_session_id)
  end

  # DELETE /data_exchange/import_cancel
  # Cancel the import and clear temp files
  def import_cancel
    import_session_id = session[:import_session_id]

    # Clean up temp files
    ImportSession.cleanup(import_session_id)

    # Clear session reference
    session.delete(:import_session_id)

    flash[:notice] = "Import cancelled"
    redirect_to root_path
  end

  # GET /data_exchange/orphan_nodes
  # Returns list of orphan nodes with suggested parent matches (JSON API)
  def orphan_nodes
    strategy = OrphanMatchingStrategy.new
    orphans = strategy.orphans_with_matches

    render json: { orphans: orphans }
  end

  # POST /data_exchange/move_node
  # Move a node to a new parent
  def move_node
    node_id = params[:node_id].to_i
    parent_id = params[:parent_id].to_i

    if node_id.zero? || parent_id.zero?
      return render json: { error: "Invalid node or parent ID" }, status: :unprocessable_content
    end

    strategy = NodeOperationsStrategy.new
    result = strategy.move_to_parent(node_id, parent_id)

    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_content
    end
  end

  # POST /data_exchange/merge_node
  # Merge a source node into a target node
  def merge_node
    source_id = params[:source_id].to_i
    target_id = params[:target_id].to_i

    if source_id.zero? || target_id.zero?
      return render json: { error: "Invalid source or target ID" }, status: :unprocessable_content
    end

    strategy = NodeOperationsStrategy.new
    result = strategy.merge_into(source_id, target_id)

    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_content
    end
  end

  # DELETE /data_exchange/delete_node
  # Delete a node
  def delete_node
    node_id = params[:node_id].to_i

    if node_id.zero?
      return render json: { error: "Invalid node ID" }, status: :unprocessable_content
    end

    strategy = NodeOperationsStrategy.new
    result = strategy.delete_node(node_id)

    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_content
    end
  end

  private

  # Serialize match results for file storage
  def serialize_match_results(results)
    results.map(&:to_h)
  end

  # Build decisions array from form params
  def build_decisions_from_params
    decisions = []

    # Expect params like: decisions[0][node_path], decisions[0][action], etc.
    decision_params = params[:decisions] || {}

    decision_params.each do |_index, decision|
      decisions << {
        node_path: decision[:node_path],
        action: decision[:action] || "create",
        target_id: decision[:target_id].presence&.to_i,
        parent_id: decision[:parent_id].presence&.to_i
      }
    end

    decisions
  end
end
