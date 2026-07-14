# frozen_string_literal: true

class GraphTraversalService
  MAX_DEPTH = 5
  DEFAULT_MAX_DEPTH = 2
  DEFAULT_MAX_ENTITIES = 100
  MAX_ENTITIES = 1_000
  DEFAULT_DIRECTION = "both"
  DIRECTIONS = %w[both outgoing incoming].freeze

  TraversalResult = Struct.new(
    :start_entity_id, :max_depth, :direction, :visited_depth, :truncated,
    :entity_ids, :relation_ids,
    keyword_init: true
  )

  PathResult = Struct.new(
    :found, :hop_count, :direction, :entity_ids, :relation_ids,
    keyword_init: true
  )

  def expand(start_entity_id:, max_depth: DEFAULT_MAX_DEPTH, direction: DEFAULT_DIRECTION,
             relation_types: nil, max_entities: DEFAULT_MAX_ENTITIES)
    start_id = start_entity_id.to_i
    depth_limit = normalize_depth(max_depth)
    dir = normalize_direction(direction)
    cap = normalize_cap(max_entities)
    canonical_types = normalize_relation_types(relation_types)

    return nil unless MemoryEntity.exists?(id: start_id)

    visited = Set.new([ start_id ])
    entity_ids = [ start_id ]
    relation_ids = Set.new
    frontier = [ start_id ]
    visited_depth = 0
    truncated = false

    (1..depth_limit).each do |depth|
      break if frontier.empty?

      next_frontier = []

      frontier_edges(frontier, dir, canonical_types).each do |relation, neighbor_id, _source_id|
        if visited.include?(neighbor_id)
          relation_ids << relation.id
          next
        end

        if visited.size >= cap
          truncated = true
          next
        end

        visited << neighbor_id
        entity_ids << neighbor_id
        next_frontier << neighbor_id
        relation_ids << relation.id
      end

      visited_depth = depth unless next_frontier.empty?
      frontier = next_frontier
    end

    TraversalResult.new(
      start_entity_id: start_id,
      max_depth: depth_limit,
      direction: dir,
      visited_depth: visited_depth,
      truncated: truncated,
      entity_ids: entity_ids,
      relation_ids: relation_ids.to_a.sort
    )
  end

  def shortest_path(from_entity_id:, to_entity_id:, max_depth: DEFAULT_MAX_DEPTH,
                    direction: DEFAULT_DIRECTION, relation_types: nil)
    from_id = from_entity_id.to_i
    to_id = to_entity_id.to_i
    depth_limit = normalize_depth(max_depth)
    dir = normalize_direction(direction)
    canonical_types = normalize_relation_types(relation_types)

    return :missing_from unless MemoryEntity.exists?(id: from_id)
    return :missing_to unless MemoryEntity.exists?(id: to_id)

    if from_id == to_id
      return PathResult.new(found: true, hop_count: 0, direction: dir, entity_ids: [ from_id ], relation_ids: [])
    end

    visited = Set.new([ from_id ])
    parents = {}
    frontier = [ from_id ]

    (1..depth_limit).each do |_depth|
      break if frontier.empty?

      next_frontier = []

      frontier_edges(frontier, dir, canonical_types).each do |relation, neighbor_id, source_id|
        next if visited.include?(neighbor_id)

        visited << neighbor_id
        parents[neighbor_id] = [ source_id, relation.id ]

        return build_path(from_id, to_id, parents, dir) if neighbor_id == to_id

        next_frontier << neighbor_id
      end

      frontier = next_frontier
    end

    PathResult.new(found: false, hop_count: nil, direction: dir, entity_ids: [], relation_ids: [])
  end

  private

  def frontier_edges(frontier, dir, canonical_types)
    edges = []

    if dir != "incoming"
      relations_scope(canonical_types).where(from_entity_id: frontier).order(:id).each do |relation|
        edges << [ relation, relation.to_entity_id, relation.from_entity_id ]
      end
    end

    if dir != "outgoing"
      relations_scope(canonical_types).where(to_entity_id: frontier).order(:id).each do |relation|
        edges << [ relation, relation.from_entity_id, relation.to_entity_id ]
      end
    end

    edges.sort_by { |relation, _neighbor_id, _source_id| relation.id }
  end

  def relations_scope(canonical_types)
    scope = MemoryRelation.all
    scope = scope.where(relation_type: canonical_types) if canonical_types.present?
    scope
  end

  def build_path(from_id, to_id, parents, dir)
    entity_ids = [ to_id ]
    relation_ids = []
    cursor = to_id

    while cursor != from_id
      predecessor_id, relation_id = parents.fetch(cursor)
      relation_ids.unshift(relation_id)
      entity_ids.unshift(predecessor_id)
      cursor = predecessor_id
    end

    PathResult.new(
      found: true,
      hop_count: relation_ids.length,
      direction: dir,
      entity_ids: entity_ids,
      relation_ids: relation_ids
    )
  end

  def normalize_depth(value)
    depth = value.to_i
    depth = DEFAULT_MAX_DEPTH if depth <= 0
    depth = MAX_DEPTH if depth > MAX_DEPTH
    depth
  end

  def normalize_direction(value)
    normalized = value.to_s.downcase
    DIRECTIONS.include?(normalized) ? normalized : DEFAULT_DIRECTION
  end

  def normalize_cap(value)
    cap = value.to_i
    cap = DEFAULT_MAX_ENTITIES if cap <= 0
    cap = MAX_ENTITIES if cap > MAX_ENTITIES
    cap
  end

  def normalize_relation_types(relation_types)
    return nil if relation_types.blank?

    Array(relation_types)
      .map { |type| MemoryRelation.canonical_relation_type(type) }
      .compact_blank
      .uniq
  end
end
