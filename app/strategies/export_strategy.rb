# frozen_string_literal: true

# Strategy class for exporting MemoryEntity graph data to JSON format
#
# This strategy:
# - Identifies root nodes (Projects or orphan entities with no incoming part_of/depends_on relations)
# - Recursively traverses the graph from selected root nodes
# - Collects all linked children with their observations
# - Serializes to a portable JSON format with cycle detection
class ExportStrategy
  # Export format version
  FORMAT_VERSION = "1.0"

  # Relation types that define parent-child relationships (incoming means child)
  CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  # Relation types to follow when traversing from parent to children
  PARENT_TO_CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  def initialize
    @logger = Rails.logger
  end

  # Get all root nodes for selection in the export UI
  # Returns Projects first (sorted by name), then other orphan nodes (sorted by name)
  # @return [Array<MemoryEntity>] Array of root entities
  def root_nodes
    # Find entities that have no incoming "part_of" or "depends_on" relations
    child_entity_ids = MemoryRelation
      .where(relation_type: CHILD_RELATION_TYPES)
      .pluck(:from_entity_id)
      .uniq

    root_entities = MemoryEntity.where.not(id: child_entity_ids)

    # Separate Projects from other entities
    projects = root_entities.where(entity_type: "Project").order(:name)
    others = root_entities.where.not(entity_type: "Project").order(:name)

    # Projects first, then others
    projects.to_a + others.to_a
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
    # Cycle detection
    return nil if visited.include?(entity.id)

    visited.add(entity.id)

    @logger.debug "ExportStrategy: Building tree for entity #{entity.id} (#{entity.name})"

    node_data = {
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      observations: serialize_observations(entity),
      children: []
    }

    # Add relation_type if this is a child node
    node_data[:relation_type] = relation_type if relation_type.present?

    # Find children: entities that have a "part_of" or "depends_on" relation TO this entity
    # (from_entity_id is the child, to_entity_id is the parent)
    child_relations = MemoryRelation
      .where(to_entity_id: entity.id, relation_type: PARENT_TO_CHILD_RELATION_TYPES)
      .includes(:from_entity)

    child_relations.each do |relation|
      child_entity = relation.from_entity
      next unless child_entity

      child_tree = build_entity_tree(child_entity, visited.dup, relation.relation_type)
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

      related_tree = build_entity_tree(related_entity, visited.dup, relation.relation_type)
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
        created_at: obs.created_at.iso8601
      }
    end
  end
end
