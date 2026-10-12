# frozen_string_literal: true

# Node-level write actions for ImportExecutionStrategy — skip / exclude /
# add_relation / merge / create / observation import (extracted for the
# 500-line rule).
module ImportExecutionStrategy::EntityWrites
  private

  def handle_skip_action(node)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]

    existing = find_declared_or_stub(name, entity_type, node,
                                     reference: node[:reference] == true || node["reference"] == true)

    if existing.nil? && (node[:reference] == true || node["reference"] == true)
      # A reference-only child marked skip resolved to another project's
      # declaration — nothing exists in OUR scopes and nothing should be
      # created (a reference never owns a project-scoped copy).
      return nil
    end

    if existing
      @logger.info "ImportExecutionStrategy: Skipping entity '#{name}' (already exists with same parent)"
      retype_on_claim(existing, entity_type, node)

      # Import any missing observations
      import_observations(node, existing.id)

      # Update counter cache if observations were added
      existing.update_column(:memory_observations_count, existing.memory_observations.count)

      @entities_skipped += 1
      existing.id
    else
      @logger.warn "ImportExecutionStrategy: Skip action but entity '#{name}' not found, creating instead"
      create_new_entity(node)
    end
  end

  def handle_exclude_action(node)
    name = node[:name] || node["name"]
    @logger.info "ImportExecutionStrategy: Excluding '#{name}' (foreign subtree, left untouched)"
    @entities_skipped += 1
    record_excluded_subtree(node)
    nil
  end

  # Left untouched means untouched by the relations pass too: endpoints
  # resolve DB-wide, so without this an edge in the payload could still be
  # written between entities of the excluded project. Remember the matched

  def handle_add_relation_action(node, parent_id)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]

    existing = find_declared_or_stub(name, entity_type, node,
                                     reference: node[:reference] == true || node["reference"] == true)

    unless existing
      @logger.warn "ImportExecutionStrategy: Add relation action but entity '#{name}' not found, creating instead"
      return create_new_entity(node)
    end

    retype_on_claim(existing, entity_type, node)

    @logger.info "ImportExecutionStrategy: Adding relation for entity '#{name}' (#{existing.id}) to parent #{parent_id}"

    # Add observations if not duplicates
    import_observations(node, existing.id)

    # Update counter cache
    existing.update_column(:memory_observations_count, existing.memory_observations.count)

    @entities_merged += 1
    existing.id
  end

  def merge_into_existing(node, target_id)
    target_entity = MemoryEntity.find_by(id: target_id)
    unless target_entity
      @errors << "Target entity #{target_id} not found for merge"
      return nil
    end

    @logger.info "ImportExecutionStrategy: Merging into entity #{target_id} (#{target_entity.name})"

    # Merge aliases
    import_aliases = (node[:aliases] || node["aliases"]).to_s
    if import_aliases.present?
      existing_aliases = target_entity.aliases.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
      new_aliases = import_aliases.split(/[,|;]/).map(&:strip).reject(&:blank?)
      merged_aliases = (existing_aliases + new_aliases).uniq.join(",")
      target_entity.update!(aliases: merged_aliases)
    end

    # Add observations
    import_observations(node, target_entity.id)

    # Update counter cache
    target_entity.update_column(:memory_observations_count, target_entity.memory_observations.count)

    @entities_merged += 1
    target_entity.id
  rescue ActiveRecord::RecordInvalid => e
    @errors << "Failed to merge into entity #{target_id}: #{e.message}"
    nil
  end

  # Create a new entity from import data
  # @param node [Hash] Import node data

  # Create a new entity from import data
  # @param node [Hash] Import node data
  # @return [Integer, nil] The new entity ID on success
  def create_new_entity(node)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]
    aliases = node[:aliases] || node["aliases"]

    @logger.info "ImportExecutionStrategy: Creating new entity '#{name}' (#{entity_type})"

    # Check if entity with same name and type already exists. Reference
    # nodes create GLOBAL stubs (project_id NULL — claimable by whichever
    # repo declares the constant) — but only when NOTHING resolves them:
    # the stored edge's current target and a single declarer (Class↔Module
    # included, a claim may have retyped the stub) win first, so an
    # unchanged re-import no-ops instead of minting a duplicate stub +
    # duplicate edge. Declared nodes resolve inside this import's project,
    # then the global namespace.
    reference_node = node[:reference] == true || node["reference"] == true
    node_project_id = reference_node ? nil : @import_project_id
    existing = if reference_node
                 ImportEntityResolver.find_reference(name, entity_type,
                                                     project_id: @import_project_id,
                                                     referrer_ids: reference_referrer_ids(node),
                                                     relation_types: reference_relation_types(node))
    else
                 find_entity_by_name_and_type(name, entity_type, project_id: node_project_id)
    end
    if existing && node[:reference] != true && node["reference"] != true && reference_stub_entity?(existing)
      # A `create` decision that resolves to an unclaimed stub means the
      # matcher refused the claim (another project declares the name too).
      # Merging would attach this declared subtree onto the shared stub —
      # create the project-scoped copy instead.
      existing = nil
    end
    if existing
      @logger.warn "ImportExecutionStrategy: Entity '#{name}' already exists, merging instead"
      return merge_into_existing(node, existing.id)
    end

    # Class-Module same-name collision — same scope first (a stored
    # counterpart is always a same-project leftover, e.g. v1.49 stored
    # `module Billing` as `Class:Billing`), then the global namespace: a
    # global collision is only claimable when it is an unclaimed reference
    # stub AND no other project declares this name+type (the matcher
    # refuses multi-declarer claims by handing down a `create`).
    collision = ImportEntityResolver.class_module_collision(name, entity_type, project_id: node_project_id)
    collision ||= ImportEntityResolver.class_module_collision(name, entity_type, project_id: nil)
    if collision && (collision.project_id == node_project_id ||
                     (reference_stub_entity?(collision) && !other_declarers?(name, entity_type)))
      @logger.info "ImportExecutionStrategy: Retyping '#{name}' #{collision.entity_type} -> " \
                   "#{entity_type} (same-scope leftover or claimed stub)"
      collision.update!(entity_type: ImportEntityResolver.canonical_type(entity_type))
      return merge_into_existing(node, collision.id)
    end

    entity = MemoryEntity.create!(
      name: name,
      entity_type: entity_type,
      aliases: aliases,
      project_id: node_project_id
    )

    # Second-declarer case: another project already holds this name+type
    # with cross-project edges pointing at it — queue one "re-point?"
    # proposal per edge (never rewired automatically).
    collect_repoint_proposals(entity) if node_project_id.present?

    # Add observations
    import_observations(node, entity.id)

    # Update counter cache
    entity.update_column(:memory_observations_count, entity.memory_observations.count)

    @entities_created += 1
    entity.id
  rescue ActiveRecord::RecordInvalid => e
    @errors << "Failed to create entity '#{name}': #{e.message}"
    nil
  end

  def import_observations(node, entity_id)
    observations = node[:observations] || node["observations"] || []
    entity = MemoryEntity.find(entity_id)
    contents_seen = Set.new
    observations_to_create = observations.filter do |obs_data|
      content = obs_data[:content] || obs_data["content"]
      next false if content.blank? || contents_seen.include?(content)

      contents_seen.add(content)
      !@observation_duplicate_detector.find_duplicate(entity: entity, content: content).duplicate
    end

    observations_to_create.each do |obs_data|
      content = obs_data[:content] || obs_data["content"]

      MemoryObservation.create!(
        memory_entity_id: entity_id,
        content: content,
        confidence: obs_data[:confidence] || obs_data["confidence"],
        source: obs_data[:source] || obs_data["source"],
        valid_from: obs_data[:valid_from] || obs_data["valid_from"],
        valid_until: obs_data[:valid_until] || obs_data["valid_until"],
        tags: obs_data[:tags] || obs_data["tags"] || []
      )
      @observations_created += 1
    rescue ActiveRecord::RecordInvalid => e
      @errors << "Failed to create observation for entity #{entity_id}: #{e.message}"
    end
  end

  # Apply name+type-addressed relations after the entity tree exists.
  # Edges whose endpoints cannot be resolved are skipped and counted — never
  # fatal — so a partially-resolvable graph still imports cleanly.
  #
  # Design decisions (PR #96 review):
  # - Endpoints resolve against the WHOLE database, not just this import's
  #   accepted tree nodes. Name+type-addressed edges are meant to cross
  #   import boundaries: a file imported today must link onto entities
  #   imported in earlier runs, so "not in this payload" is not "missing".
  #   Only genuinely absent endpoints count as unresolved.
  # - A skipped tree node still receives its imported edges: `skip` means
  #   "entity already exists with this parent" — the entity stays part of
  #   the processed tree, so upserting its relations is the intended
  #   rescan behaviour, not an operator exclusion.
  # @param relations [Array<Hash>, nil] {from_name, from_type, to_name, to_type,
end
