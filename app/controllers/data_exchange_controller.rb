# frozen_string_literal: true

class DataExchangeController < ApplicationController
  # Skip CSRF for API-like endpoints (file download)
  skip_before_action :verify_authenticity_token, only: [ :export ]

  # GET /data_exchange/export?ids[]=1&ids[]=2
  # Returns JSON file with selected root nodes and all their children
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
  # Receives JSON file, runs matching, stores in session, redirects to review
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

      # Store in session for the review step
      session[:import_data] = json_data
      session[:import_matches] = serialize_match_results(match_result[:match_results])
      session[:import_stats] = match_result[:stats]
      session[:import_version] = match_result[:version]

      redirect_to import_review_data_exchange_index_path
    rescue JSON::ParserError => e
      flash[:error] = "Invalid JSON file: #{e.message}"
      redirect_to root_path
    rescue StandardError => e
      Rails.logger.error "Import upload failed: #{e.message}"
      flash[:error] = "Import failed: #{e.message}"
      redirect_to root_path
    end
  end

  # GET /data_exchange/import_review
  # Shows matching results page with operator controls
  def import_review
    unless session[:import_matches].present?
      flash[:error] = "No import data found. Please upload a file first."
      return redirect_to root_path
    end

    @matches = session[:import_matches]
    @stats = session[:import_stats]
    @version = session[:import_version]

    # Get available parent entities for the "Make children of" dropdown
    @available_parents = ExportStrategy.new.root_nodes.map do |entity|
      { id: entity.id, name: entity.name, entity_type: entity.entity_type }
    end
  end

  # POST /data_exchange/import_execute
  # Execute import based on operator decisions
  def import_execute
    unless session[:import_data].present?
      flash[:error] = "No import data found. Please upload a file first."
      return redirect_to root_path
    end

    import_data = session[:import_data]
    decisions = build_decisions_from_params

    strategy = ImportExecutionStrategy.new
    report = strategy.execute(import_data, decisions)

    # Store report in session and clear import data
    session[:import_report] = report.to_h
    session.delete(:import_data)
    session.delete(:import_matches)
    session.delete(:import_stats)
    session.delete(:import_version)

    redirect_to import_report_data_exchange_index_path
  end

  # GET /data_exchange/import_report
  # Shows the import results report
  def import_report
    unless session[:import_report].present?
      flash[:error] = "No import report found."
      return redirect_to root_path
    end

    @report = session[:import_report]
  end

  # DELETE /data_exchange/import_cancel
  # Cancel the import and clear session data
  def import_cancel
    session.delete(:import_data)
    session.delete(:import_matches)
    session.delete(:import_stats)
    session.delete(:import_version)
    session.delete(:import_report)

    flash[:notice] = "Import cancelled"
    redirect_to root_path
  end

  private

  # Serialize match results for session storage
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
