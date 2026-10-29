# frozen_string_literal: true

# Synthetic fixtures for fact supersede specs: "Gadget Project" (the fact's project) and
# "Legacy Gadget" (another project still running on the old stack).
module FactSupersedeHelpers
  OPERATOR_ACTOR = "operator:synth@127.0.0.1"
  AGENT_ACTOR = "api:synth-agent"

  # @return [MemoryEntity] a Project root
  def fs_project!(name)
    MemoryEntity.create!(name: name, entity_type: "Project")
  end

  # @return [MemoryEntity] a member of `project` (project_id and the part_of edge)
  def fs_member!(project, name, entity_type = "Component")
    MemoryEntity.create!(name: name, entity_type: entity_type, project_id: project.id).tap do |member|
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")
    end
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
