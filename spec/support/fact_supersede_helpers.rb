# frozen_string_literal: true

# Synthetic fixtures for fact supersede specs: "Gadget Project" (the fact's project) and
# "Legacy Gadget" (another project still running on the old stack).
#
# `fs_member!` is also the suite's one way to put an entity in a project's tree with consistent
# membership (the part_of edge, and project_id as ProjectMembership derives it), which the
# membership drift guard (spec/support/membership_drift_guard.rb) checks after each example:
#
#   alpha = fs_project!("Alpha Project")
#   widget = fs_member!(alpha, "SynthWidget")             # a new member, directly under the root
#   gadget = fs_member!(widget, "SynthGadget", "Class")   # a new member under another member
#   fs_member!(alpha, MemoryEntity.create!(name: "Beta Service", entity_type: "Service")) # attach one
module FactSupersedeHelpers
  OPERATOR_ACTOR = "operator:synth@127.0.0.1"
  AGENT_ACTOR = "api:synth-agent"

  # @return [MemoryEntity] a Project root
  def fs_project!(name)
    MemoryEntity.create!(name: name, entity_type: "Project")
  end

  # Puts an entity under `parent` (a Project root, or an entity in a project's tree or a global
  # one): a part_of edge to it, then ProjectMembership.sync!, so the entity (and the subtree it
  # already has) takes the parent's project.
  #
  # @param parent [MemoryEntity]
  # @param member [String, MemoryEntity] a name (the entity is created) or an existing entity
  # @param entity_type [String] for a created entity
  # @param attributes [Hash] more columns for a created entity (aliases:, description:, ...)
  # @param relation [Hash] more columns for the edge (properties:, weight:, ...)
  # @return [MemoryEntity] the member
  def fs_member!(parent, member, entity_type = "Component", relation: {}, **attributes)
    if member.is_a?(MemoryEntity)
      entity = member
    else
      entity = MemoryEntity.create!(name: member, entity_type: entity_type,
                                    project_id: ProjectMembership.project_id_for_parent(parent), **attributes)
    end
    MemoryRelation.create!(from_entity: entity, to_entity: parent, relation_type: "part_of", **relation)
    ProjectMembership.sync!(entity)
    entity.reload # sync! writes with update_all: the caller's object (and associations holding it) see the stamp
  end

  # @return [MemoryObservation] a source fact written by `actor`
  def fs_fact!(entity, content = "The MCP server uses the official mcp gem.", actor: OPERATOR_ACTOR, tags: [])
    Current.set(actor: actor) do
      MemoryObservation.create!(memory_entity: entity, content: content, source: "docs:README.md", tags: [ SourceFact::SOURCE_FACT_TAG, *tags ])
    end
  end

  # @return [MemoryObservation]
  def fs_observe!(entity, content, **attributes)
    MemoryObservation.create!(memory_entity: entity, content: content, **attributes)
  end
end

RSpec.configure do |config|
  config.include FactSupersedeHelpers
end
