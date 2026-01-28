# frozen_string_literal: true

require_relative "../../lib/import_session"

class DataExchangeController < ApplicationController
  # Skip CSRF for API-like endpoints (file download and JSON responses)
  skip_before_action :verify_authenticity_token, only: [
    :export, :export_async, :move_node, :merge_node, :delete_node,
    :delete_duplicate_relations, :update_relation, :delete_relation
  ]

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
  # Root node decisions come from form params, child decisions from stored matches
  def import_execute
    import_session_id = session[:import_session_id]

    unless ImportSession.exists?(import_session_id)
      flash[:error] = "No import data found. Please upload a file first."
      return redirect_to root_path
    end

    import_data = ImportSession.load_data(import_session_id)
    stored_matches = ImportSession.load_matches(import_session_id)

    # Merge root decisions from form with child decisions from stored matches
    decisions = build_merged_decisions(params[:decisions], stored_matches)

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

  # GET /data_exchange/duplicate_relations
  # Returns count and list of duplicate relation pairs (A→B and B→A with same type)
  def duplicate_relations
    duplicates = find_duplicate_relations

    render json: {
      count: duplicates.length,
      duplicates: duplicates
    }
  end

  # DELETE /data_exchange/delete_duplicate_relations
  # Deletes the newer relation from each duplicate pair (keeps the older one by ID)
  def delete_duplicate_relations
    duplicates = find_duplicate_relations
    deleted_count = 0

    ActiveRecord::Base.transaction do
      duplicates.each do |dup|
        relation = MemoryRelation.find_by(id: dup[:delete][:id])
        if relation
          relation.destroy!
          deleted_count += 1
        end
      end
    end

    render json: {
      success: true,
      deleted_count: deleted_count,
      message: "Deleted #{deleted_count} duplicate relations"
    }
  rescue ActiveRecord::RecordNotDestroyed => e
    render json: { success: false, error: "Failed to delete relations: #{e.message}" }, status: :unprocessable_content
  end

  # PATCH /data_exchange/update_relation
  # Updates a relation's type
  def update_relation
    relation_id = params[:id].to_i

    if relation_id.zero?
      return render json: { error: "Invalid relation ID" }, status: :unprocessable_content
    end

    relation = MemoryRelation.find_by(id: relation_id)

    unless relation
      return render json: { error: "Relation not found" }, status: :not_found
    end

    new_type = params[:relation_type]

    if new_type.blank?
      return render json: { error: "Relation type is required" }, status: :unprocessable_content
    end

    relation.update!(relation_type: new_type)

    render json: {
      success: true,
      relation: {
        id: relation.id,
        from_entity_id: relation.from_entity_id,
        to_entity_id: relation.to_entity_id,
        relation_type: relation.relation_type
      }
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.message }, status: :unprocessable_content
  end

  # DELETE /data_exchange/delete_relation
  # Deletes a single relation
  def delete_relation
    relation_id = params[:id].to_i

    if relation_id.zero?
      return render json: { error: "Invalid relation ID" }, status: :unprocessable_content
    end

    relation = MemoryRelation.find_by(id: relation_id)

    unless relation
      return render json: { error: "Relation not found" }, status: :not_found
    end

    from_name = relation.from_entity&.name
    to_name = relation.to_entity&.name
    relation_type = relation.relation_type

    relation.destroy!

    render json: {
      success: true,
      message: "Deleted relation: #{from_name} -[#{relation_type}]-> #{to_name}"
    }
  rescue ActiveRecord::RecordNotDestroyed => e
    render json: { success: false, error: e.message }, status: :unprocessable_content
  end

  private

  # Find duplicate relation pairs (A→B and B→A with same type)
  # Returns the older relation (lower ID) to keep and newer to delete
  # @return [Array<Hash>] Array of duplicate pairs
  def find_duplicate_relations
    duplicates = []
    seen_pairs = Set.new

    MemoryRelation.includes(:from_entity, :to_entity).find_each do |rel|
      # Create a normalized key for this pair (sorted IDs + type)
      pair_key = [ [ rel.from_entity_id, rel.to_entity_id ].sort, rel.relation_type ].flatten

      next if seen_pairs.include?(pair_key)

      # Check for reverse relation
      reverse = MemoryRelation.find_by(
        from_entity_id: rel.to_entity_id,
        to_entity_id: rel.from_entity_id,
        relation_type: rel.relation_type
      )

      if reverse
        # Mark this pair as seen
        seen_pairs.add(pair_key)

        # Keep the older one (lower ID), delete the newer one
        keep_rel, delete_rel = [ rel, reverse ].sort_by(&:id)

        duplicates << {
          keep: {
            id: keep_rel.id,
            from_entity_id: keep_rel.from_entity_id,
            from_name: keep_rel.from_entity&.name,
            to_entity_id: keep_rel.to_entity_id,
            to_name: keep_rel.to_entity&.name
          },
          delete: {
            id: delete_rel.id,
            from_entity_id: delete_rel.from_entity_id,
            from_name: delete_rel.from_entity&.name,
            to_entity_id: delete_rel.to_entity_id,
            to_name: delete_rel.to_entity&.name
          },
          relation_type: rel.relation_type
        }
      end
    end

    duplicates
  end

  # Serialize match results for file storage
  def serialize_match_results(results)
    results.map(&:to_h)
  end

  # Build merged decisions array from form params (root nodes) and stored matches (child nodes)
  # @param root_decisions_params [ActionController::Parameters, Hash] Form params for root decisions
  # @param stored_matches [Array<Hash>] Stored match results containing child decisions
  # @return [Array<Hash>] Complete decisions array for all nodes
  def build_merged_decisions(root_decisions_params, stored_matches)
    # Build lookup of submitted root decisions by node_path
    submitted_decisions = build_submitted_decisions_lookup(root_decisions_params)

    decisions = []

    stored_matches.each do |match|
      is_child = match[:is_child] || match["is_child"] || false
      node_path = match[:node_path] || match["node_path"]

      if is_child
        # Child nodes: use pre-computed decision from stored match
        decisions << build_child_decision(match)
      else
        # Root nodes: use operator's decision from form params
        submitted = submitted_decisions[node_path]
        decisions << build_root_decision(match, submitted)
      end
    end

    decisions
  end

  # Build lookup hash of submitted decisions by node_path
  # @param root_decisions_params [ActionController::Parameters, Hash] Form params
  # @return [Hash] Map of node_path => decision hash
  def build_submitted_decisions_lookup(root_decisions_params)
    return {} if root_decisions_params.blank?

    lookup = {}
    root_decisions_params.each do |_index, decision|
      node_path = decision[:node_path] || decision["node_path"]
      next if node_path.blank?

      lookup[node_path] = {
        action: decision[:action] || decision["action"] || "create",
        target_id: (decision[:target_id] || decision["target_id"]).presence&.to_i,
        parent_id: (decision[:parent_id] || decision["parent_id"]).presence&.to_i
      }
    end
    lookup
  end

  # Build decision for a child node from stored match data
  # @param match [Hash] Stored match data
  # @return [Hash] Decision for this child node
  def build_child_decision(match)
    node_path = match[:node_path] || match["node_path"]
    child_action = match[:child_action] || match["child_action"] || "create"
    exact_match = match[:exact_match] || match["exact_match"]

    target_id = if exact_match
      exact_match[:entity_id] || exact_match["entity_id"]
    end

    {
      node_path: node_path,
      action: child_action,
      child_action: child_action,
      target_id: target_id&.to_i
    }
  end

  # Build decision for a root node from submitted form data
  # @param match [Hash] Stored match data (for defaults)
  # @param submitted [Hash, nil] Submitted form data
  # @return [Hash] Decision for this root node
  def build_root_decision(match, submitted)
    node_path = match[:node_path] || match["node_path"]

    if submitted
      {
        node_path: node_path,
        action: submitted[:action] || "create",
        target_id: submitted[:target_id],
        parent_id: submitted[:parent_id]
      }
    else
      # No submitted decision - use default from match
      selected_match_id = match[:selected_match_id] || match["selected_match_id"]
      {
        node_path: node_path,
        action: selected_match_id.present? ? "merge" : "create",
        target_id: selected_match_id&.to_i,
        parent_id: nil
      }
    end
  end
end
