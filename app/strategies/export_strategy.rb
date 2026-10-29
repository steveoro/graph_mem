# frozen_string_literal: true

# Strategy class for exporting MemoryEntity graph data to JSON format
#
# This strategy:
# - Identifies root nodes (Projects or orphan entities with no incoming part_of/depends_on relations)
# - Recursively traverses the graph from selected root nodes
# - Collects all linked children with their observations
# - Serializes to a portable JSON format with cycle detection
# - Stops recursion at nested Project entities (keeps the shallow node + relation metadata)
class ExportStrategy
  # Export format version
  FORMAT_VERSION = "1.0"

  # Entity type treated as an export boundary when reached via recursion
  PROJECT_ENTITY_TYPE = "Project"

  # Relation types that define parent-child relationships (incoming means child)
  CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  # Relation types to follow when traversing from parent to children
  PARENT_TO_CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  def initialize
    @logger = Rails.logger
  end

  # The export picker's list caps here; the picker's filter narrows by name.
  ROOT_NODES_LIMIT = 500

  # Root nodes for the export picker (and the import review's parent choice): Projects (they are
  # roots even when part of another Project), then entities with no outgoing part_of/depends_on
  # relation, each group by name. One query (NOT EXISTS), capped at `limit`.
  #
  # @param query [String, nil] keep only names containing this text
  # @param limit [Integer]
  # @return [Array<MemoryEntity>]
  def root_nodes(query: nil, limit: ROOT_NODES_LIMIT)
    children = MemoryRelation.where(relation_type: CHILD_RELATION_TYPES).where("memory_relations.from_entity_id = memory_entities.id")
    scope = MemoryEntity.where("memory_entities.entity_type = ? OR NOT EXISTS (#{children.select(1).to_sql})", PROJECT_ENTITY_TYPE)
    scope = scope.where("memory_entities.name LIKE ?", "%#{MemoryEntity.sanitize_sql_like(query.to_s.strip)}%") if query.present?
    scope.order(Arel.sql(MemoryEntity.sanitize_sql_array([ "memory_entities.entity_type = ? DESC", PROJECT_ENTITY_TYPE ])), :name)
         .limit(limit).to_a
  end

  # Export selected root nodes with all their children to JSON format
  # @param entity_ids [Array<Integer>] IDs of root entities to export
  # @return [Hash] Export data in portable JSON format
  def export(entity_ids)
    return empty_export if entity_ids.blank?

    entities = MemoryEntity.where(id: entity_ids).includes(:memory_observations)
    root_nodes_data = entities.map { |entity| build_entity_tree(entity, Set.new) }

    {
      version: FORMAT_VERSION,
      exported_at: Time.current.iso8601,
      root_nodes: root_nodes_data
    }
  end

  # Export to JSON string
  # @param entity_ids [Array<Integer>] IDs of root entities to export
  # @return [String] JSON string
  def export_json(entity_ids)
    JSON.pretty_generate(export(entity_ids))
  end

  # Export selected root nodes with progress callback support
  # @param entity_ids [Array<Integer>] IDs of root entities to export
  # @param progress_callback [Proc, nil] Optional callback called for each node processed
  # @return [Hash] Export data in portable JSON format
  def export_with_progress(entity_ids, progress_callback = nil)
    return empty_export if entity_ids.blank?

    @progress_callback = progress_callback

    entities = MemoryEntity.where(id: entity_ids).includes(:memory_observations)
    root_nodes_data = entities.map { |entity| build_entity_tree_with_progress(entity, Set.new) }

    {
      version: FORMAT_VERSION,
      exported_at: Time.current.iso8601,
      root_nodes: root_nodes_data
    }
  ensure
    @progress_callback = nil
  end

  # Export to JSON string with progress callback support
  # @param entity_ids [Array<Integer>] IDs of root entities to export
  # @param progress_callback [Proc, nil] Optional callback called for each node processed
  # @return [String] JSON string
  def export_json_with_progress(entity_ids, progress_callback = nil)
    JSON.pretty_generate(export_with_progress(entity_ids, progress_callback))
  end

  private

  def empty_export
    {
      version: FORMAT_VERSION,
      exported_at: Time.current.iso8601,
      root_nodes: []
    }
  end

  # Recursively build entity tree with children
  # @param entity [MemoryEntity] The entity to serialize
  # @param visited [Set<Integer>] Set of already visited entity IDs (for cycle detection)
  # @param relation_type [String, nil] The relation type from parent to this entity
  # @return [Hash] Entity data with nested children
  def build_entity_tree(entity, visited, relation_type = nil)
    build_entity_tree_internal(entity, visited, relation_type, false)
  end

  # Recursively build entity tree with children and progress callback
  # @param entity [MemoryEntity] The entity to serialize
  # @param visited [Set<Integer>] Set of already visited entity IDs (for cycle detection)
  # @param relation_type [String, nil] The relation type from parent to this entity
  # @return [Hash] Entity data with nested children
  def build_entity_tree_with_progress(entity, visited, relation_type = nil)
    build_entity_tree_internal(entity, visited, relation_type, true)
  end

  # Internal method for building entity tree
  # @param entity [MemoryEntity] The entity to serialize
  # @param visited [Set<Integer>] Set of already visited entity IDs (for cycle detection)
  # @param relation_type [String, nil] The relation type from parent to this entity
  # @param with_progress [Boolean] Whether to call progress callback
  # @return [Hash] Entity data with nested children
  def build_entity_tree_internal(entity, visited, relation_type, with_progress)
    # Cycle detection
    return nil if visited.include?(entity.id)

    visited.add(entity.id)

    @logger.debug "ExportStrategy: Building tree for entity #{entity.id} (#{entity.name})"

    # Call progress callback if available and requested
    if with_progress && @progress_callback
      @progress_callback.call(entity.name)
    end

    node_data = {
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      observations: serialize_observations(entity),
      children: []
    }

    if relation_type.present?
      if relation_type.is_a?(Hash)
        node_data[:relation_type] = relation_type[:relation_type]
        node_data[:relation_weight] = relation_type[:weight]
        node_data[:relation_confidence] = relation_type[:confidence]
        node_data[:relation_properties] = relation_type[:properties]
        node_data[:relation_direction] = relation_type[:direction]
      else
        node_data[:relation_type] = relation_type
      end
    end

    # Nested Projects are export boundaries: keep the node and relation metadata,
    # but do not recurse into their subgraphs. Explicit export roots still expand fully
    # because they are invoked with relation_type = nil.
    return node_data if nested_project_boundary?(entity, relation_type)

    # Find children: entities that have a "part_of" or "depends_on" relation TO this entity
    # (from_entity_id is the child, to_entity_id is the parent)
    child_relations = MemoryRelation
      .where(to_entity_id: entity.id, relation_type: PARENT_TO_CHILD_RELATION_TYPES)
      .includes(:from_entity)

    child_relations.each do |relation|
      child_entity = relation.from_entity
      next unless child_entity

      child_tree = build_entity_tree_internal(
        child_entity,
        visited.dup,
        serialize_relation(relation, direction: "child_to_parent"),
        with_progress
      )
      node_data[:children] << child_tree if child_tree
    end

    # Also include entities connected via other relation types (not part_of/depends_on)
    # These are "related" entities, not strict children
    other_relations = MemoryRelation
      .where(from_entity_id: entity.id)
      .where.not(relation_type: PARENT_TO_CHILD_RELATION_TYPES)
      .includes(:to_entity)

    other_relations.each do |relation|
      related_entity = relation.to_entity
      next unless related_entity
      next if visited.include?(related_entity.id)

      related_tree = build_entity_tree_internal(
        related_entity,
        visited.dup,
        serialize_relation(relation, direction: "parent_to_child"),
        with_progress
      )
      node_data[:children] << related_tree if related_tree
    end

    node_data
  end

  # Serialize observations for an entity
  # @param entity [MemoryEntity] The entity
  # @return [Array<Hash>] Array of observation data
  def serialize_observations(entity)
    entity.memory_observations.map do |obs|
      {
        content: obs.content,
        confidence: obs.confidence,
        source: obs.source,
        valid_from: obs.valid_from&.iso8601,
        valid_until: obs.valid_until&.iso8601,
        tags: obs.tags,
        created_at: obs.created_at.iso8601
      }
    end
  end

  def serialize_relation(relation, direction:)
    {
      relation_type: relation.relation_type,
      weight: relation.weight,
      confidence: relation.confidence,
      properties: relation.properties,
      direction: direction
    }
  end

  # True when this Project was reached via recursion (has a parent relation),
  # not as an explicit top-level export root.
  def nested_project_boundary?(entity, relation_type)
    entity.entity_type == PROJECT_ENTITY_TYPE && relation_type.present?
  end
end
