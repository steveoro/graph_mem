# frozen_string_literal: true

# What Explore's "Move under…" confirm card shows (UI-4b W4), read-only: how many entities move
# (the node's part_of subtree, counted up to the canvas cap) and which project they end up in.
#
#   card = ExploreMoveCard.new(widget, gadget_project)
#   card.subtree_label   # => "3" (or "2,000+")
#   card.project_change? # => true when the subtree changes project
#   card.blocker         # => nil, or why the move can't run ("Project roots can't be moved.")
class ExploreMoveCard
  attr_reader :node, :parent

  # @param node [MemoryEntity]
  # @param parent [MemoryEntity]
  def initialize(node, parent)
    @node = node
    @parent = parent
  end

  # @return [String, nil]
  def blocker
    return ExploreEdits::ROOT_MOVE if root?(node)
    return "An entity can't be moved under itself." if node.id == parent.id
    return "'#{node.name}' is already under '#{parent.name}'." if MemoryRelation.exists?(from_entity_id: node.id, to_entity_id: parent.id, relation_type: "part_of")

    "That would put '#{parent.name}' inside its own subtree." if RelationSemantics.would_create_cycle?(node.id, parent.id)
  end

  # @return [String] the node plus its descendants, "2,000+" past the canvas cap
  def subtree_label
    subtree.truncated? ? "#{ActiveSupport::NumberHelper.number_to_delimited(cap)}+" : subtree.entity_ids.size.to_s
  end

  # @return [MemoryEntity, nil] the project the node is in now (nil: global)
  def current_project
    node.project
  end

  # @return [MemoryEntity, nil] the project it moves into: the parent if it is a root, else the parent's
  def new_project
    root?(parent) ? parent : parent.project
  end

  # @return [Boolean]
  def project_change?
    current_project&.id != new_project&.id
  end

  private

  def cap = Api::V1::GraphDataController::MAX_NODES

  def subtree
    @subtree ||= ProjectSubtree.resolve(node.id, max_entities: cap)
  end

  # The same rule as NodeOperationsStrategy and ExploreEdits: any Project entity is a root.
  def root?(entity)
    entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
  end
end
