# frozen_string_literal: true

# MemoryEntity Resource implementation with pagination, filtering, sorting, and relation inclusion
class MemoryEntityResource < ApplicationResource
  # Templated URI with all supported query parameters
  uri "memory_entities{?page,per_page,entity_type,name,aliases,id,created_after,created_before,updated_after,updated_before,min_observations,sort_by,sort_dir,include_observations,include_relations,or_filters}"
  resource_name "MemoryEntities"
  description "Access memory entities with pagination, filtering, sorting and relation inclusion"
  mime_type "application/json"

  # Valid sort fields to prevent SQL injection
  VALID_SORT_FIELDS = %w[id name entity_type aliases memory_observations_count created_at updated_at].freeze

  # Valid sort directions to prevent SQL injection
  VALID_SORT_DIRECTIONS = %w[asc desc].freeze

  # Boolean parameters for inclusion options
  INCLUDE_OPTIONS = %w[include_observations include_relations].freeze

  def content
    # Extract pagination parameters
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i

    # Initialize query with base model
    query = MemoryEntity

    # Apply filters if present
    query = apply_filters(query)

    # Apply OR filters if present
    query = apply_or_filters(query) if params[:or_filters].present?

    # Apply sorting if present
    query = apply_sorting(query)

    # Get the total count before pagination for accurate pagination data
    total_count = query.count

    # Apply pagination
    entities = query.limit(per_page).offset((page - 1) * per_page)

    # Format entities with optional included relations
    formatted_entities = format_entities_with_includes(entities)

    # Format the result with entities and pagination info
    result = {
      entities: formatted_entities,
      pagination: {
        total_entities: total_count,
        per_page: per_page,
        current_page: page,
        total_pages: (total_count.to_f / per_page).ceil
      },
      # Include the applied filters and sorting for reference
      applied_filters: filter_summary,
      applied_sorting: sorting_summary,
      applied_includes: include_summary
    }

    JSON.generate(result)
  end

  private

  # Apply filters based on request parameters
  def apply_filters(query)
    # Filter by entity_type
    if params[:entity_type].present?
      if params[:entity_type].is_a?(Array)
        query = query.where(entity_type: params[:entity_type])
      else
        query = query.where(entity_type: params[:entity_type])
      end
    end

    # Filter by name (partial match)
    if params[:name].present?
      query = query.where("name LIKE ?", "%#{params[:name]}%")
    end

    # Filter by aliases (partial match)
    if params[:aliases].present?
      query = query.where("aliases LIKE ?", "%#{params[:aliases]}%")
    end

    # Filter by exact ID
    if params[:id].present?
      query = query.where(id: params[:id])
    end

    # Filter by creation date range
    if params[:created_after].present?
      query = query.where("created_at >= ?", params[:created_after])
    end

    if params[:created_before].present?
      query = query.where("created_at <= ?", params[:created_before])
    end

    # Filter by update date range
    if params[:updated_after].present?
      query = query.where("updated_at >= ?", params[:updated_after])
    end

    if params[:updated_before].present?
      query = query.where("updated_at <= ?", params[:updated_before])
    end

    # Filter by having observations (minimum count)
    if params[:min_observations].present?
      query = query.where("memory_observations_count >= ?", params[:min_observations].to_i)
    end

    query
  end

  # Summarize the filters that were applied
  def filter_summary
    summary = {}
    summary[:entity_type] = params[:entity_type] if params[:entity_type].present?
    summary[:name] = params[:name] if params[:name].present?
    summary[:aliases] = params[:aliases] if params[:aliases].present?
    summary[:id] = params[:id] if params[:id].present?
    summary[:created_after] = params[:created_after] if params[:created_after].present?
    summary[:created_before] = params[:created_before] if params[:created_before].present?
    summary[:updated_after] = params[:updated_after] if params[:updated_after].present?
    summary[:updated_before] = params[:updated_before] if params[:updated_before].present?
    summary[:min_observations] = params[:min_observations] if params[:min_observations].present?
    summary
  end

  # Generate a summary of the applied sorting for reporting
  def sorting_summary
    summary = {}
    summary[:sort_by] = params[:sort_by] if params[:sort_by].present? && VALID_SORT_FIELDS.include?(params[:sort_by])
    summary[:sort_dir] = params[:sort_dir] if params[:sort_dir].present? && VALID_SORT_DIRECTIONS.include?(params[:sort_dir])
    summary
  end

  # Generate a summary of the included relations for reporting
  def include_summary
    summary = {}

    # Add boolean flags for each inclusion option
    summary[:include_observations] = true if params[:include_observations] == "true"
    summary[:include_relations] = true if params[:include_relations] == "true"

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

  # Apply OR filters for complex queries
  # Expects or_filters to be JSON encoded string containing an array of filter objects
  # Each filter object can contain the same filters as the regular params
  # Example: [{"entity_type":"Project"},{"entity_type":"Task"}]
  def apply_or_filters(query)
    return query unless params[:or_filters].present?

    begin
      # Parse the JSON string containing filter objects
      filter_objects = JSON.parse(params[:or_filters])

      # Build the OR conditions
      query = query.where(build_or_conditions(filter_objects))
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse or_filters JSON: #{e.message}"
    end

    query
  end

  # Build OR conditions from filter objects
  def build_or_conditions(filter_objects)
    # Start with empty conditions
    conditions = []
    values = []

    filter_objects.each do |filter|
      # Handle entity_type filter
      if filter["entity_type"].present?
        conditions << "entity_type = ?"
        values << filter["entity_type"]
      end

      # Handle name filter
      if filter["name"].present?
        conditions << "name LIKE ?"
        values << "%#{filter['name']}%"
      end

      # Handle aliases filter
      if filter["aliases"].present?
        conditions << "aliases LIKE ?"
        values << "%#{filter['aliases']}%"
      end

      # Handle ID filter
      if filter["id"].present?
        conditions << "id = ?"
        values << filter["id"].to_i
      end
    end

    # Combine all conditions with OR
    return [ "1=2" ] if conditions.empty? # No valid conditions, return impossible condition

    [ conditions.join(" OR ") ] + values
  end

  # Format entities with optional included relations using boolean parameters
  def format_entities_with_includes(entities)
    # Get entity data as JSON first
    result = entities.as_json

    # Determine if we should include observations and/or relations using simple boolean parameters
    include_observations = params[:include_observations] == "true"
    include_relations = params[:include_relations] == "true"

    # Early return if no includes requested
    return result unless include_observations || include_relations

    # Log inclusion options for debugging
    Rails.logger.debug "Including observations: #{include_observations}, relations: #{include_relations}"

    # Process each entity for inclusions
    result.each_with_index do |entity_data, i|
      entity = entities[i]

      # Include observations if requested
      if include_observations
        Rails.logger.debug "Including observations for entity #{entity.id}"
        if entity.memory_observations_count.to_i.positive?
          entity_data["observations"] = entity.memory_observations.as_json
        end
      end

      # Include relations if requested
      if include_relations
        Rails.logger.debug "Including relations for entity #{entity.id}"
        outgoing = MemoryRelation.where(from_entity_id: entity.id)
        incoming = MemoryRelation.where(to_entity_id: entity.id)

        entity_data["relations"] = {
          outgoing: outgoing.as_json,
          incoming: incoming.as_json
        }
      end
    end

    Rails.logger.debug "Returning #{result.size} formatted entities"
    result
  end
end
