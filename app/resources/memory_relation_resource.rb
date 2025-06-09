# frozen_string_literal: true

# MemoryRelation Resource implementation with pagination, filtering, sorting, and entity inclusion
class MemoryRelationResource < ApplicationResource
  # Templated URI with all supported query parameters
  uri "memory_relations{?page,per_page,from_entity_id,to_entity_id,relation_type,created_after,created_before,updated_after,updated_before,sort_by,sort_dir,include_from_entity,include_to_entity}"
  resource_name "MemoryRelations"
  description "Access memory relations with pagination, filtering, sorting and entity inclusion"
  mime_type "application/json"

  # Valid sort fields to prevent SQL injection
  VALID_SORT_FIELDS = %w[id from_entity_id to_entity_id relation_type created_at updated_at].freeze

  # Valid sort directions to prevent SQL injection
  VALID_SORT_DIRECTIONS = %w[asc desc].freeze

  def content
    # Extract pagination parameters
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i
    per_page = [ per_page, 100 ].min # Cap at 100 items per page for performance

    # Start with base query
    query = MemoryRelation
    query = apply_filters(query)
    query = apply_sorting(query)

    # Count total records for pagination
    total_count = query.count

    # Apply pagination and fetch records
    relations = query.limit(per_page).offset((page - 1) * per_page)

    # Format the response with optional entity inclusions
    formatted_relations = format_relations_with_includes(relations)

    # Build the result with pagination info and metadata
    result = {
      relations: formatted_relations,
      pagination: {
        total_relations: total_count,
        per_page: per_page,
        current_page: page,
        total_pages: (total_count.to_f / per_page).ceil
      },
      applied_filters: filter_summary,
      applied_sorting: sorting_summary,
      applied_includes: include_summary
    }

    # Return the JSON response
    JSON.generate(result)
  end

  private

  # Apply filters based on query parameters
  def apply_filters(query)
    # Filter by from_entity_id
    query = query.where(from_entity_id: params[:from_entity_id]) if params[:from_entity_id].present?

    # Filter by to_entity_id
    query = query.where(to_entity_id: params[:to_entity_id]) if params[:to_entity_id].present?

    # Filter by relation_type (exact match)
    query = query.where(relation_type: params[:relation_type]) if params[:relation_type].present?

    # Date range filters for created_at
    query = query.where("created_at >= ?", Time.zone.parse(params[:created_after])) if params[:created_after].present?
    query = query.where("created_at <= ?", Time.zone.parse(params[:created_before])) if params[:created_before].present?

    # Date range filters for updated_at
    query = query.where("updated_at >= ?", Time.zone.parse(params[:updated_after])) if params[:updated_after].present?
    query = query.where("updated_at <= ?", Time.zone.parse(params[:updated_before])) if params[:updated_before].present?

    query
  end

  # Generate a summary of applied filters for the response
  def filter_summary
    summary = {}

    # Add each filter that was applied
    summary[:from_entity_id] = params[:from_entity_id] if params[:from_entity_id].present?
    summary[:to_entity_id] = params[:to_entity_id] if params[:to_entity_id].present?
    summary[:relation_type] = params[:relation_type] if params[:relation_type].present?
    summary[:created_after] = params[:created_after] if params[:created_after].present?
    summary[:created_before] = params[:created_before] if params[:created_before].present?
    summary[:updated_after] = params[:updated_after] if params[:updated_after].present?
    summary[:updated_before] = params[:updated_before] if params[:updated_before].present?

    summary
  end

  # Format relations with optional included entities
  def format_relations_with_includes(relations)
    # Get relation data as JSON first
    result = relations.as_json

    # Check if we need to include the from_entity and/or to_entity
    include_from_entity = params[:include_from_entity] == "true"
    include_to_entity = params[:include_to_entity] == "true"

    if include_from_entity || include_to_entity
      # Process each relation for entity inclusions
      result.each_with_index do |relation_data, i|
        relation = relations[i]

        # Include from_entity if requested
        if include_from_entity && relation.from_entity_id.present?
          from_entity = MemoryEntity.find_by(id: relation.from_entity_id)
          relation_data["from_entity"] = from_entity.as_json if from_entity.present?
        end

        # Include to_entity if requested
        if include_to_entity && relation.to_entity_id.present?
          to_entity = MemoryEntity.find_by(id: relation.to_entity_id)
          relation_data["to_entity"] = to_entity.as_json if to_entity.present?
        end
      end
    end

    result
  end

  # Generate a summary of the included relations for reporting
  def include_summary
    summary = {}
    summary[:include_from_entity] = true if params[:include_from_entity] == "true"
    summary[:include_to_entity] = true if params[:include_to_entity] == "true"
    summary
  end

  # Apply sorting to the query based on params
  def apply_sorting(query)
    sort_by = params[:sort_by]
    sort_dir = params[:sort_dir]&.downcase

    # Only apply sorting if valid field and direction are provided
    if sort_by.present? && VALID_SORT_FIELDS.include?(sort_by)
      # Default to ascending if not specified or invalid
      direction = (sort_dir.present? && VALID_SORT_DIRECTIONS.include?(sort_dir)) ? sort_dir : "asc"
      query = query.order(sort_by => direction)
      Rails.logger.debug "Applied sorting by #{sort_by} #{direction}"
    else
      # Default sort by ID ascending if no valid sort specified
      query = query.order(id: :asc)
    end

    query
  end

  # Generate a summary of the applied sorting for reporting
  def sorting_summary
    summary = {}
    summary[:sort_by] = params[:sort_by] if params[:sort_by].present? && VALID_SORT_FIELDS.include?(params[:sort_by])
    summary[:sort_dir] = params[:sort_dir] if params[:sort_dir].present? && VALID_SORT_DIRECTIONS.include?(params[:sort_dir])
    summary
  end
end
