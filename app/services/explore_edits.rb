# frozen_string_literal: true

# Explore's edits (UI-4b): each wraps an existing service or model call in its own `explore.*`
# change set, with the operator as actor (Current.actor), so it appears in Recent activity and
# can be undone. Explore's own rules (project roots: rename only, and they can't move) live
# here, not in GraphEditService or NodeOperationsStrategy, so the MCP tools keep their behaviour.
#
#   result = ExploreEdits.new.update_entity(entity, name: "SynthWidget 2")
#   result # => { success: true, status: :ok, message: "Saved 'SynthWidget 2'.", entity_id: 42,
#          #      changed: [42], removed: [], change_set_uuid: "…", undoable: true, not_undoable_reason: nil }
#   ExploreEdits.new.move(root, parent) # => { success: false, status: :unprocessable_content, error: "Project roots can't be moved." }
#
# Every method returns that hash; failures carry `error` and write nothing.
class ExploreEdits
  include ExploreEdits::Observations
  include ExploreEdits::Relations
  include ExploreEdits::Proposals

  ROOT_RENAME_ONLY = "Project roots can only be renamed."
  ROOT_MOVE = "Project roots can't be moved."
  NO_NEW_ROOTS = "An entity can't become a project root from Explore."
  NOTHING_CHANGED = "Nothing changed."
  MAX_NAME_LENGTH = 255
  MAX_REASON_LENGTH = 500
  ENTITY_FIELDS = %i[name entity_type aliases description].freeze

  # Name, type, aliases and description; a project root takes only name and description, and no
  # entity can be retyped to Project here (it would be a root that keeps its parent).
  #
  # @param entity [MemoryEntity]
  # @param attributes [Hash] any of ENTITY_FIELDS (strings)
  # @return [Hash]
  def update_entity(entity, attributes)
    changes = entity_changes(entity, attributes.to_h.symbolize_keys.slice(*ENTITY_FIELDS))
    return refused(ROOT_RENAME_ONLY) if project_root?(entity) && changes.keys.intersect?(%i[entity_type aliases])
    return refused(NO_NEW_ROOTS) if changes[:entity_type].to_s.casecmp?(NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
    return refused(NOTHING_CHANGED) if changes.empty?
    return refused("Name can't be blank.") if changes.key?(:name) && changes[:name].blank?
    return refused("Name is too long (at most #{MAX_NAME_LENGTH} characters).") if changes[:name].to_s.length > MAX_NAME_LENGTH

    record("explore.entity_edit", entity, "edited '#{entity.name}'") do
      GraphEditService.execute_one("update_entity", changes.merge(entity_id: entity.id))
      done("Saved '#{entity.reload.name}'.", entity)
    end
  rescue GraphMem::InvalidArgumentsError => e
    refused(e.message)
  end

  # Moves `node` (and its subtree) under `parent`, replacing its part_of edge.
  #
  # @param node [MemoryEntity]
  # @param parent [MemoryEntity]
  # @return [Hash]
  def move(node, parent)
    return refused(ROOT_MOVE) if project_root?(node)

    record("explore.move", node, "moved '#{node.name}' under '#{parent.name}'") do
      result = NodeOperationsStrategy.new.move_to_parent(node.id, parent.id)
      next refused(result[:error]) unless result[:success]

      done("Moved '#{node.name}' under '#{parent.name}'.", node, changed: [ node.id, parent.id ])
    end
  end

  private

  def entity_changes(entity, attributes)
    attributes = attributes.transform_values { |value| value.to_s.strip }
    attributes[:aliases] = GraphMutationBatch.normalize_aliases(attributes[:aliases]).to_s if attributes.key?(:aliases)
    attributes.reject { |field, value| value == entity.public_send(field).to_s }
  end

  def project_root?(entity)
    entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
  end

  # Runs the block in a new `kind` change set; a success gains the set's undo handle.
  def record(kind, subject, summary)
    ChangeSet.record(kind: kind, subject: subject, summary: summary.truncate(255)) do |context|
      result = yield
      result[:success] ? result.merge(context.undo_handle) : result
    end
  rescue ActiveRecord::RecordInvalid => e
    refused(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue ActiveRecord::RecordNotFound, McpGraphMemErrors::ResourceNotFound => e
    refused(e.message, status: :not_found)
  rescue GraphMem::InvalidArgumentsError, McpGraphMemErrors::Error, RelationSemantics::ValidationError,
         MemoryObservation::InactiveObservationError, ProjectMembership::Collision => e
    refused(e.message)
  end

  # @param entity [MemoryEntity] the panel to show after the edit
  def done(message, entity, changed: [ entity.id ], removed: [], **extra)
    { success: true, status: :ok, message: message, entity_id: entity.id, changed: changed, removed: removed, **extra }
  end

  def refused(error, status: :unprocessable_content, **extra)
    { success: false, status: status, error: error, **extra }
  end
end
