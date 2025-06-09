# frozen_string_literal: true

# MemoryObservation Resource implementation with pagination, filtering, sorting, and entity inclusion
class MemoryObservationResource < ApplicationResource
  # Templated URI with all supported query parameters
  uri "memory_observations{?page,per_page,memory_entity_id,content,created_after,created_before,updated_after,updated_before,sort_by,sort_dir,include_entity}"
  resource_name "MemoryObservations"
  description "Access memory observations with pagination, filtering, sorting and entity inclusion"
  mime_type "application/json"

  # Valid sort fields to prevent SQL injection
  VALID_SORT_FIELDS = %w[id memory_entity_id content created_at updated_at].freeze

  # Valid sort directions to prevent SQL injection
  VALID_SORT_DIRECTIONS = %w[asc desc].freeze

  def content
    # Extract pagination parameters
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i
    per_page = [ per_page, 100 ].min # Cap at 100 items per page for performance

    # Start with base query
    query = MemoryObservation
    query = apply_filters(query)
    query = apply_sorting(query)

    # Count total records for pagination
    total_count = query.count

    # Apply pagination and fetch records
    observations = query.limit(per_page).offset((page - 1) * per_page)

    # Format the response with optional entity inclusion
    formatted_observations = format_observations_with_includes(observations)

    # Build the result with pagination info and metadata
    result = {
      observations: formatted_observations,
      pagination: {
        total_observations: total_count,
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
    # Filter by memory_entity_id
    query = query.where(memory_entity_id: params[:memory_entity_id]) if params[:memory_entity_id].present?

    # Filter by content (partial match)
    query = query.where("content LIKE ?", "%#{params[:content]}%") if params[:content].present?

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
    summary[:memory_entity_id] = params[:memory_entity_id] if params[:memory_entity_id].present?
    summary[:content] = params[:content] if params[:content].present?
    summary[:created_after] = params[:created_after] if params[:created_after].present?
    summary[:created_before] = params[:created_before] if params[:created_before].present?
    summary[:updated_after] = params[:updated_after] if params[:updated_after].present?
    summary[:updated_before] = params[:updated_before] if params[:updated_before].present?

    summary
  end

  # Format observations with optional included entity
  def format_observations_with_includes(observations)
    # Get observation data as JSON first
    result = observations.as_json

    # Check if we need to include the parent entity
    include_entity = params[:include_entity] == "true"

    if include_entity
      # Process each observation for entity inclusion
      result.each_with_index do |observation_data, i|
        observation = observations[i]

        # Fetch and include the parent entity if it exists
        if observation.memory_entity_id.present?
          entity = MemoryEntity.find_by(id: observation.memory_entity_id)
          observation_data["entity"] = entity.as_json if entity.present?
        end
      end
    end

    result
  end

  # Generate a summary of the included relations for reporting
  def include_summary
    summary = {}
    summary[:include_entity] = true if params[:include_entity] == "true"
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
