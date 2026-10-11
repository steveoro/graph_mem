# frozen_string_literal: true

# Cross-repo / project-scope lookup and stub-claim helpers for
# ImportExecutionStrategy (extracted to keep each file under the 500-line
# rule). All methods are private on the including strategy.
module ImportExecutionStrategy::Claims
  private

  # resolve DB-wide, so without this an edge in the payload could still be
  # written between entities of the excluded project. Remember the matched
  # entity and its whole part_of subtree.
  def record_excluded_subtree(node)
    entity = ImportEntityResolver.find_by_name_and_type(
      node[:name] || node["name"], node[:entity_type] || node["entity_type"]
    )
    return unless entity

    record_excluded_entity(entity)
  end

  def record_excluded_entity(entity)
    @excluded_entity_ids.add(entity.id)
    @excluded_entity_ids.merge(RelationSemantics.descendant_ids(entity.id))
  end

  # Unclaimed reference stub: parked in the global namespace (project_id
  # NULL — stubs are the only cross-project objects) and still carrying
  # the stub-tagged part_of edge an earlier referencing import emitted.
  def reference_stub_entity?(entity)
    return false unless entity.project_id.nil?

    MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of")
      .where("JSON_UNQUOTE(JSON_EXTRACT(properties, '$.reference_stub')) = 'true'").exists?
  end

  # Handle add_relation action - entity exists but needs relation to new parent
  # Add observations if they don't exist, relation will be created by caller
  # @param node [Hash] Import node data
  # @param parent_id [Integer, nil] The new parent entity ID

  def find_entity_by_name_and_type(name, entity_type, project_id: nil)
    ImportEntityResolver.find_by_name_and_type(name, entity_type, project_id: project_id)
  end

  # Typed scoped lookup plus the Class-Module sibling fallbacks (same
  # scope first, then global) — mirrors ImportMatchingStrategy's
  # resolution so a `skip`/`add_relation` decision lands on the same
  # entity the matcher chose. Reference nodes resolve against the WHOLE
  # graph instead (stored edge target → single declarer → global stub),
  # same as match, so a re-import lands on the claimed entity rather than
  # minting a second stub.
  def find_declared_or_stub(name, entity_type, reference: false, referrer_id: nil)
    if reference
      return ImportEntityResolver.find_reference(name, entity_type,
                                                 project_id: @import_project_id,
                                                 parent_entity_id: referrer_id)
    end
    find_entity_by_name_and_type(name, entity_type, project_id: @import_project_id) ||
      ImportEntityResolver.class_module_collision(name, entity_type, project_id: @import_project_id) ||
      ImportEntityResolver.class_module_collision(name, entity_type, project_id: nil)
  end

  # A declaring node that resolves onto an entity of a sibling type claims
  # it: retype the stub (or the same-project v1.49 leftover) so the
  # declared Class-Module wins. Reference nodes never retype — they do
  # not own.
  def retype_on_claim(entity, raw_type, node)
    return if node[:reference] == true || node["reference"] == true

    canonical = ImportEntityResolver.canonical_type(raw_type)
    return if entity.entity_type == canonical
    return unless reference_stub_entity?(entity) || entity.project_id == @import_project_id

    @logger.info "ImportExecutionStrategy: Retyping '#{entity.name}' " \
                 "#{entity.entity_type} -> #{canonical} on claim"
    entity.update!(entity_type: canonical)
  end

  # True when another project (not this import's, not the global
  # namespace) already declares this name+type — mirrors the matcher's
  # declared_elsewhere? so a `create` decision never claims a stub two
  # projects both want.
  def other_declarers?(name, entity_type)
    scope = MemoryEntity.where(name: name, entity_type: ImportEntityResolver.canonical_type(entity_type))
                        .where.not(project_id: nil)
    scope = scope.where.not(project_id: @import_project_id) if @import_project_id
    scope.exists?
  end
end
