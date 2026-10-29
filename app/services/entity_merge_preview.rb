# frozen_string_literal: true

# What merging `source` into `target` would do (UI-4b W6), read-only, with the same lookups as
# NodeOperationsStrategy#merge_into_once / #merge_locked!: the observations that move (any
# status), the relations re-pointed to the target, the ones dropped (duplicates of a target
# triple, and A↔B edges), the aliases the target gains, the part_of children re-parented and
# the entities that change project. `digest` fingerprints all of that, so EntityMergeService can
# refuse a merge that would do more than the operator saw.
#
#   preview = EntityMergePreview.new(source_id, target_id).call
#   preview.blockers           # => [] or ["Cannot merge entities of different types: …"]
#   preview.observation_count  # => 3
#   preview.digest             # => "9f86d0…" (nil when either entity is missing)
#   EntityMergePreview.new(source_id, target_id).digest # the digest alone (what the merge lock checks)
class EntityMergePreview
  SAMPLE = 5
  SUBTREE_CAP = 2_000

  Relation = Data.define(:id, :label, :relation_type, :direction)
  # count stops at SUBTREE_CAP + 1; count_label then reads "2,000+".
  ProjectMove = Data.define(:from_name, :to_name, :count) do
    def count_label
      count > SUBTREE_CAP ? "#{ActiveSupport::NumberHelper.number_to_delimited(SUBTREE_CAP)}+" : count.to_s
    end
  end

  Result = Struct.new(:source, :target, :blockers, :observation_count, :observation_sample, :repointed, :dropped,
                      :aliases_gained, :children, :project_moves, :review_row_count, :survivor_hint, :digest,
                      keyword_init: true) do
    def blocked? = blockers.any?
  end

  # @param source_id [Integer, String] the entity that would be merged away
  # @param target_id [Integer, String] the survivor
  def initialize(source_id, target_id)
    @source_id = source_id.to_i
    @target_id = target_id.to_i
  end

  # @return [Result]
  def call
    source = MemoryEntity.find_by(id: @source_id)
    target = MemoryEntity.find_by(id: @target_id)
    blockers = blockers_for(source, target)
    return Result.new(source: source, target: target, blockers: blockers, digest: nil) unless source && target && @source_id != @target_id

    build(source, target, blockers)
  end

  # Only what the digest covers, with no samples, counts or subtree walks: EntityMergeService runs
  # this inside the merge's membership and row locks, so it stays short.
  #
  # @return [String, nil] nil when either entity is missing or they are the same
  def digest
    source = MemoryEntity.find_by(id: @source_id)
    target = MemoryEntity.find_by(id: @target_id)
    return nil unless source && target && source.id != target.id

    repointed, dropped, child_ids = relation_effects(source, target, labels: false)
    digest_of(source.memory_observations.pluck(:id), repointed, dropped, child_ids, source, target)
  end

  private

  def blockers_for(source, target)
    return [ "Source node not found" ] unless source
    return [ "Target node not found" ] unless target
    return [ "Cannot merge a node into itself" ] if source.id == target.id

    blockers = []
    blockers << NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR if [ source, target ].any? { |entity| root?(entity) }
    if source.entity_type != target.entity_type
      blockers << "Cannot merge entities of different types: '#{source.entity_type}' into '#{target.entity_type}'"
    end
    blockers
  end

  def build(source, target, blockers)
    observations = source.memory_observations.order(:id)
    repointed, dropped, child_ids = relation_effects(source, target)
    children = MemoryEntity.where(id: child_ids).order(:id).to_a
    gained = aliases_gained(source, target)
    observation_ids = observations.pluck(:id)

    Result.new(
      source: source, target: target, blockers: blockers,
      observation_count: observation_ids.size, observation_sample: observations.limit(SAMPLE).to_a,
      repointed: repointed, dropped: dropped, aliases_gained: gained, children: children,
      project_moves: project_moves(children, target), review_row_count: MaintenanceReportRow.where(status: "active", anchor_entity_id: source.id).count,
      survivor_hint: EntityMergeEvidence.pick_survivor(source, target).last == target ? :target : :source,
      digest: digest_of(observation_ids, repointed, dropped, child_ids, source, target)
    )
  end

  # Mirrors reassign_outgoing_relations!, reassign_incoming_relations! and the A↔B cleanup.
  def relation_effects(source, target, labels: true)
    target_out = MemoryRelation.where(from_entity_id: target.id).pluck(:to_entity_id, :relation_type).to_set
    target_in = MemoryRelation.where(to_entity_id: target.id).pluck(:from_entity_id, :relation_type).to_set
    repointed = []
    dropped = []
    child_ids = []

    outgoing = MemoryRelation.where(from_entity_id: source.id).order(:id)
    incoming = MemoryRelation.where(to_entity_id: source.id).order(:id)
    outgoing = outgoing.includes(:to_entity) if labels
    incoming = incoming.includes(:from_entity) if labels
    outgoing.each do |relation|
      entry = relation_entry(relation, :outgoing, source, labels)
      if relation.to_entity_id == target.id then dropped << entry
      elsif target_out.include?([ relation.to_entity_id, relation.relation_type ]) then dropped << entry
      else repointed << entry
      end
    end
    incoming.each do |relation|
      entry = relation_entry(relation, :incoming, source, labels)
      next dropped << entry if relation.from_entity_id == target.id

      child_ids << relation.from_entity_id if relation.relation_type == "part_of"
      (target_in.include?([ relation.from_entity_id, relation.relation_type ]) ? dropped : repointed) << entry
    end
    [ repointed, dropped, child_ids.uniq ]
  end

  def relation_entry(relation, direction, source, labels)
    label = if !labels then nil
    elsif direction == :outgoing
      "#{source.name} #{relation.relation_type} #{relation.to_entity&.name}"
    else
      "#{relation.from_entity&.name} #{relation.relation_type} #{source.name}"
    end
    Relation.new(id: relation.id, label: label, relation_type: relation.relation_type, direction: direction)
  end

  def aliases_gained(source, target)
    before = split_aliases(target.aliases)
    split_aliases(NodeOperationsStrategy.new.merged_aliases(source, target)) - before
  end

  def split_aliases(value)
    value.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
  end

  # Re-parented children take the target's project, and their subtrees with them.
  def project_moves(children, target)
    moving = children.reject { |child| child.project_id == target.project_id }
    return [] if moving.empty?

    names = MemoryEntity.where(id: (moving.map(&:project_id) + [ target.project_id ]).compact.uniq).pluck(:id, :name).to_h
    moving.group_by(&:project_id).map do |project_id, group|
      ProjectMove.new(from_name: names[project_id], to_name: names[target.project_id], count: subtree_size(group.map(&:id)))
    end
  end

  # One part_of walk down from all of `root_ids` together, stopping past SUBTREE_CAP.
  def subtree_size(root_ids)
    seen = root_ids.uniq
    frontier = seen
    while frontier.any? && seen.size <= SUBTREE_CAP
      children = MemoryRelation.where(relation_type: "part_of", to_entity_id: frontier)
                               .limit(SUBTREE_CAP + 2 - seen.size).pluck(:from_entity_id)
      frontier = children.uniq - seen
      seen += frontier
    end
    [ seen.size, SUBTREE_CAP + 1 ].min
  end

  # The source's name and aliases count too: they decide the aliases the target gains.
  def digest_of(observation_ids, repointed, dropped, child_ids, source, target)
    Digest::SHA256.hexdigest({
      observations: observation_ids.sort, repointed: repointed.map(&:id).sort, dropped: dropped.map(&:id).sort,
      children: child_ids.sort, target_aliases: target.aliases.to_s,
      source_name: source.name.to_s, source_aliases: source.aliases.to_s
    }.to_json)
  end

  def root?(entity)
    entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
  end
end
