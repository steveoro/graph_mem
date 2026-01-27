# frozen_string_literal: true

# Strategy class for matching orphan nodes to potential parent Projects
#
# This strategy:
# - Identifies orphan nodes (entities with no incoming part_of/depends_on relations, excluding Projects)
# - Tokenizes each orphan node's name
# - Matches tokens against Project names and aliases
# - Returns orphans with suggested parent matches for the Clean-up UI
class OrphanMatchingStrategy
  # Relation types that define parent-child relationships
  CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  def initialize
    @logger = Rails.logger
  end

  # Get all orphan nodes (root nodes that are not Projects)
  # @return [Array<MemoryEntity>] Array of orphan entities
  def orphan_nodes
    # Find entities that have no incoming "part_of" or "depends_on" relations
    child_entity_ids = MemoryRelation
      .where(relation_type: CHILD_RELATION_TYPES)
      .pluck(:from_entity_id)
      .uniq

    # Orphans are entities that:
    # 1. Have no incoming part_of/depends_on relations, AND
    # 2. Are NOT of type "Project"
    MemoryEntity
      .where.not(id: child_entity_ids)
      .where.not(entity_type: "Project")
      .order(:name)
  end

  # Get all orphan nodes with their potential parent Project matches
  # @return [Array<Hash>] Array of orphan data with matches
  def orphans_with_matches
    orphans = orphan_nodes
    projects = all_projects

    orphans.map do |orphan|
      matches = match_to_projects(orphan, projects)

      {
        id: orphan.id,
        name: orphan.name,
        entity_type: orphan.entity_type,
        observations_count: orphan.memory_observations_count,
        children_count: count_children(orphan.id),
        suggested_parents: matches.map do |match|
          {
            id: match[:project].id,
            name: match[:project].name,
            score: match[:score],
            matched_tokens: match[:matched_tokens]
          }
        end
      }
    end
  end

  # Match a single node to potential parent Projects
  # @param node [MemoryEntity] The orphan node
  # @param projects [Array<MemoryEntity>] All projects (optional, will be fetched if nil)
  # @return [Array<Hash>] Matches sorted by score (descending)
  def match_to_projects(node, projects = nil)
    projects ||= all_projects
    tokens = tokenize(node.name)

    return [] if tokens.empty?

    matches = []

    projects.each do |project|
      score, matched_tokens = calculate_match_score(tokens, project)

      if score > 0
        matches << {
          project: project,
          score: score,
          matched_tokens: matched_tokens
        }
      end
    end

    # Sort by score descending
    matches.sort_by { |m| -m[:score] }
  end

  private

  # Get all Project entities
  # @return [Array<MemoryEntity>]
  def all_projects
    MemoryEntity.where(entity_type: "Project").order(:name).to_a
  end

  # Tokenize a name into searchable tokens
  # @param name [String] The name to tokenize
  # @return [Array<String>] Array of lowercase tokens
  def tokenize(name)
    return [] if name.blank?

    # Split on common separators and normalize
    name
      .to_s
      .split(/[\s_\-\.]+/)  # Split on spaces, underscores, hyphens, dots
      .map(&:downcase)
      .map(&:strip)
      .reject(&:blank?)
      .reject { |t| t.length < 2 }  # Ignore very short tokens
      .uniq
  end

  # Calculate match score between tokens and a project
  # @param tokens [Array<String>] Tokens from the orphan node name
  # @param project [MemoryEntity] The project to match against
  # @return [Array<Integer, Array<String>>] Score and matched tokens
  def calculate_match_score(tokens, project)
    score = 0
    matched_tokens = []

    project_name_lower = project.name.to_s.downcase
    project_aliases_lower = project.aliases.to_s.downcase

    # Also tokenize the project name and aliases for exact token matching
    project_name_tokens = tokenize(project.name)
    project_alias_tokens = project.aliases.to_s.split(/[,|;]/).flat_map { |a| tokenize(a) }

    tokens.each do |token|
      token_matched = false

      # Exact token match in project name tokens (highest score)
      if project_name_tokens.include?(token)
        score += 10
        token_matched = true
      # Substring match in project name
      elsif project_name_lower.include?(token)
        score += 5
        token_matched = true
      # Exact token match in project alias tokens
      elsif project_alias_tokens.include?(token)
        score += 8
        token_matched = true
      # Substring match in project aliases
      elsif project_aliases_lower.include?(token)
        score += 3
        token_matched = true
      end

      matched_tokens << token if token_matched
    end

    [ score, matched_tokens ]
  end

  # Count the number of direct children for a node
  # @param entity_id [Integer] The entity ID
  # @return [Integer] Number of direct children
  def count_children(entity_id)
    MemoryRelation
      .where(to_entity_id: entity_id, relation_type: CHILD_RELATION_TYPES)
      .count
  end
end
