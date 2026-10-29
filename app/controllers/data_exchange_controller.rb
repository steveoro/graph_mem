# frozen_string_literal: true

require_relative "../../lib/import_session"

class DataExchangeController < ApplicationController
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

  # The import endpoints the Maintenance hub used, kept until §6.D-6: they run ImportFlow (like
  # Projects::ImportsController) and redirect to the new pages; the GET pages answer 301.

  # POST /data_exchange/import_upload
  def import_upload
    upload = ImportFlow.upload(params[:file], project_name: params[:project_name])
    return redirect_to new_projects_import_path, alert: upload.error if upload.error

    session[:import_session_id] = upload.session_id
    redirect_to projects_import_path(upload.session_id)
  end

  # GET /data_exchange/import_review
  def import_review
    import_session_id = session[:import_session_id]
    target = ImportSession.exists?(import_session_id) ? projects_import_path(import_session_id) : new_projects_import_path
    redirect_to target, status: :moved_permanently
  end

  # POST /data_exchange/import_execute
  def import_execute
    import_session_id = session[:import_session_id]
    return redirect_to new_projects_import_path, alert: "No import data found. Please upload a file first." unless ImportSession.exists?(import_session_id)

    operation = ImportFlow.execute(import_session_id, params[:decisions])
    session.delete(:import_session_id)
    session[:import_operation_id] = operation.operation_id
    redirect_to report_projects_import_path(operation.operation_id)
  end

  # GET /data_exchange/import_report
  def import_report
    operation_id = session[:import_operation_id]
    redirect_to operation_id.present? ? report_projects_import_path(operation_id) : projects_imports_path, status: :moved_permanently
  end

  # DELETE /data_exchange/import_cancel
  def import_cancel
    ImportSession.cleanup(session.delete(:import_session_id))
    redirect_to projects_imports_path, notice: "Import cancelled"
  end

  # GET /data_exchange/entity_search?q=foo
  # Lightweight autocomplete endpoint for the review UI.
  def entity_search
    query = params[:q].to_s.strip
    return render json: { entities: [] } if query.blank?

    entities = MemoryEntity
      .where("name LIKE ? OR aliases LIKE ?", "%#{query}%", "%#{query}%")
      .order(:name)
      .limit(20)

    render json: {
      entities: entities.map { |e| { id: e.id, name: e.name, entity_type: e.entity_type } }
    }
  end

  # POST /data_exchange/create_relation
  # Creates a new relation between two entities
  def create_relation
    from_id = params[:from_id].to_i
    to_id = params[:to_id].to_i
    relation_type = params[:relation_type]

    if from_id.zero? || to_id.zero? || relation_type.blank?
      return render json: { error: "Invalid relation parameters" }, status: :unprocessable_content
    end

    from = MemoryEntity.find_by(id: from_id)
    to = MemoryEntity.find_by(id: to_id)

    unless from && to
      return render json: { error: "Entity not found" }, status: :not_found
    end

    relation = MemoryRelation.new(
      from_entity_id: from_id,
      to_entity_id: to_id,
      relation_type: relation_type
    )

    if RelationSemantics.hierarchical?(relation_type)
      # Every part_of write goes through the membership lock + sync — a bare
      # save would leave project_id stale until the next backfill.
      if MemoryRelation.where(from_entity_id: from_id, relation_type: "part_of").where.not(to_entity_id: to_id).exists?
        result = NodeOperationsStrategy.new.move_to_parent(from_id, to_id)
        if result[:success]
          relation = MemoryRelation.find_by(from_entity_id: from_id, to_entity_id: to_id, relation_type: "part_of")
          return render json: {
            success: true,
            relation: {
              id: relation.id,
              from_entity_id: relation.from_entity_id,
              to_entity_id: relation.to_entity_id,
              relation_type: relation.relation_type
            }
          }
        end

        return render json: { success: false, error: result[:error] }, status: :unprocessable_content
      end

      relation = nil
      ProjectMembership.with_membership_lock do
        ActiveRecord::Base.transaction do
          relation = MemoryRelation.create!(
            from_entity_id: from_id,
            to_entity_id: to_id,
            relation_type: relation_type
          )
          ProjectMembership.sync!(MemoryEntity.find(from_id))
        end
      end
      return render json: {
        success: true,
        relation: {
          id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type
        }
      }
    end

    if relation.save
      render json: {
        success: true,
        relation: {
          id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type
        }
      }
    else
      render json: { success: false, error: relation.errors.full_messages.join(", ") }, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
  rescue ActiveRecord::RecordNotUnique
    render json: { success: false, error: "That relation already exists." }, status: :unprocessable_content
  rescue ProjectMembership::LockTimeout, ProjectMembership::Collision => e
    render json: { success: false, error: membership_conflict_message(e) }, status: :unprocessable_content
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
  rescue ProjectMembership::LockTimeout, ProjectMembership::Collision => e
    render json: { success: false, error: membership_conflict_message(e) }, status: :unprocessable_content
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
    result = ChangeSet.record(kind: "maintenance.merge_node") { strategy.merge_into(source_id, target_id) }

    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_content
    end
  rescue ProjectMembership::LockTimeout, ProjectMembership::Collision => e
    render json: { success: false, error: membership_conflict_message(e) }, status: :unprocessable_content
  end

  # DELETE /data_exchange/delete_node
  # Delete a node
  def delete_node
    node_id = params[:node_id].to_i

    if node_id.zero?
      return render json: { error: "Invalid node ID" }, status: :unprocessable_content
    end

    strategy = NodeOperationsStrategy.new
    result = strategy.delete_node(node_id, reason: params[:reason])

    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_content
    end
  rescue ProjectMembership::LockTimeout, ProjectMembership::Collision => e
    render json: { success: false, error: membership_conflict_message(e) }, status: :unprocessable_content
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

    begin
      Current.deletion_reason = "duplicate"
      ActiveRecord::Base.transaction do
        duplicates.each do |dup|
          relation = MemoryRelation.find_by(id: dup[:delete][:id])
          if relation
            relation.destroy!
            deleted_count += 1
          end
        end
      end
    ensure
      Current.deletion_reason = nil
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

    begin
      Current.deletion_reason = params[:reason]
      relation.destroy!
    ensure
      Current.deletion_reason = nil
    end

    render json: {
      success: true,
      message: "Deleted relation: #{from_name} -[#{relation_type}]-> #{to_name}"
    }
  rescue ActiveRecord::RecordNotDestroyed => e
    render json: { success: false, error: e.message }, status: :unprocessable_content
  end

  private

  # LockTimeout is transient — a concurrent import/backfill/merge holds the
  # advisory lock, so "retry shortly" is the honest hint. Collision is a
  # name conflict in the destination scope: retrying changes nothing, the
  # entity must be renamed or re-parented elsewhere.
  def membership_conflict_message(error)
    hint = error.is_a?(ProjectMembership::LockTimeout) ? "retry shortly" : "rename the entity or pick another parent"
    "#{error.message} — #{hint}."
  end

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
end
