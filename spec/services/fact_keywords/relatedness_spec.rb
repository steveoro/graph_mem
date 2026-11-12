# frozen_string_literal: true

require "rails_helper"

# 1.78.0: two facts compared by their keyword paths (project › own entity › mentions).
RSpec.describe FactKeywords::Relatedness do
  def compare(first_path, second_path)
    described_class.compare_paths(first_path, first_path[1], second_path, second_path[1])
  end

  it "relates facts that share a mention, strongly when it is their first" do
    result = compare(%w[goggles_db AdminGrant User Team], %w[goggles_db AdminGrant User])

    expect(result).to have_attributes(subject: :related, strong: true, shared: %w[User])
    expect(compare(%w[goggles_db AdminGrant Team User], %w[goggles_db AdminGrant User])).to have_attributes(subject: :related, strong: false)
  end

  it "relates facts on two entities when one mentions the other's own entity" do
    expect(compare(%w[goggles_db Badge Swimmer], %w[goggles_db Swimmer Season]))
      .to have_attributes(subject: :related, shared: %w[Swimmer])
  end

  it "tells unrelated, one-sided and unknown pairs apart" do
    expect(compare(%w[goggles_db AdminGrant User], %w[goggles_db AdminGrant Team]).subject).to eq(:unrelated)
    expect(compare(%w[goggles_db AdminGrant User], %w[goggles_db AdminGrant]).subject).to eq(:one_sided)
    expect(compare(%w[goggles_db AdminGrant], %w[goggles_db AdminGrant]).subject).to eq(:unknown)
  end

  # 1.80.0: siblings, two entities of one parent that the paths don't connect, are unrelated.
  def compare_owned(first_path, first_owner, second_path, second_owner)
    described_class.compare_paths(first_path, first_owner, second_path, second_owner)
  end

  it "calls facts on two entities the paths don't connect unrelated, mentions or not (1.80.0)" do
    expect(compare(%w[gadget_mcp Rework], %w[gadget_mcp ServerRules]).subject).to eq(:unrelated)
    expect(compare(%w[gadget_mcp Rework Session], %w[gadget_mcp ServerRules]).subject).to eq(:unrelated)
    expect(compare(%w[gadget_mcp Rework Session], %w[gadget_mcp ServerRules Profile]).subject).to eq(:unrelated)
    expect(compare(%w[gadget_mcp Rework Session], %w[gadget_mcp ServerRules Session]).subject).to eq(:related)
    expect(compare(%w[gadget_mcp Rework ServerRules], %w[gadget_mcp ServerRules]).subject).to eq(:related)
  end

  it "never calls a fact held by its project root, or by an entity with no project, a sibling" do
    expect(compare_owned(%w[gadget_mcp], "gadget_mcp", %w[gadget_mcp ServerRules], "ServerRules").subject).to eq(:unknown)
    expect(compare_owned(%w[gadget_mcp Session], "gadget_mcp", %w[gadget_mcp ServerRules], "ServerRules").subject).to eq(:one_sided)
    expect(compare_owned(%w[LooseNote], "LooseNote", %w[gadget_mcp ServerRules], "ServerRules").subject).to eq(:unknown)
  end

  it "never calls a stale path a sibling: an owner or a project root renamed since it was computed" do
    expect(compare_owned(%w[gadget_mcp OldRework], "Rework", %w[gadget_mcp ServerRules], "ServerRules").subject).to eq(:unknown)
    expect(compare_owned(%w[old_mcp], "gadget_mcp", %w[old_mcp ServerRules], "ServerRules").subject).to eq(:unknown)
  end

  it "never calls two entities a relation joins directly siblings" do
    expect(described_class.compare_paths(%w[gadget_mcp Deployment], "Deployment", %w[gadget_mcp Infrastructure], "Infrastructure",
                                         connected: true).subject).to eq(:unknown)

    root = MemoryEntity.create!(name: "gadget_mcp", entity_type: "Project")
    deployment, infrastructure, rules = %w[Deployment Infrastructure ServerRules].map do |name|
      MemoryEntity.create!(name: name, entity_type: "Component", project_id: root.id)
    end
    MemoryRelation.create!(from_entity: deployment, to_entity: infrastructure, relation_type: "part_of")
    facts = { deployment => "We deploy with Kamal.", infrastructure => "We deploy with Capistrano.", rules => "Never deploy on Fridays." }
              .to_h do |entity, content|
      observation = MemoryObservation.create!(memory_entity: entity, content: content)
      observation.update_columns(keywords: [ root.name, entity.name ], keywords_at: Time.current)
      [ entity.name, observation ]
    end

    expect(described_class.compare(facts["Infrastructure"], facts["Deployment"]).subject).to eq(:unknown)
    expect(described_class.compare(facts["Deployment"], facts["ServerRules"]).subject).to eq(:unrelated)
  end

  it "compares observations by their stored paths and owners" do
    root = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    grant = MemoryEntity.create!(name: "AdminGrant", entity_type: "Model", project_id: root.id)
    first = MemoryObservation.create!(memory_entity: grant, content: "It belongs to a User.")
    second = MemoryObservation.create!(memory_entity: grant, content: "It names a Team.")
    first.update_columns(keywords: [ "Gadget Project", "AdminGrant", "User" ], keywords_at: Time.current)

    expect(described_class.computed?(first, second)).to be(false)
    second.update_columns(keywords: [ "Gadget Project", "AdminGrant", "Team" ], keywords_at: Time.current)
    expect(described_class.compare(first, second).subject).to eq(:unrelated)
  end

  # 1.84.0: "the same own entity" is the same record, not the same name (two projects' SynthWidget).
  it "compares LLM words only for two facts on the same entity record" do
    facts = [ "Gadget Project", "Other Project" ].map do |project|
      root = MemoryEntity.create!(name: project, entity_type: "Project")
      widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Class", project_id: root.id)
      MemoryObservation.create!(memory_entity: widget, content: "Validates presence of name.").tap do |fact|
        fact.update_columns(keywords: [ project, "SynthWidget" ], keywords_at: Time.current, llm_keywords: %w[name presence],
                            llm_keywords_at: Time.current)
      end
    end
    twin = MemoryObservation.create!(memory_entity: facts.first.memory_entity, content: "Checks that a name is present.")
    twin.update_columns(keywords: [ "Gadget Project", "SynthWidget" ], keywords_at: Time.current, llm_keywords: %w[name presence],
                        llm_keywords_at: Time.current)

    expect(described_class.compare(facts.first, twin)).to have_attributes(by_words: true, same_subject: true)
    expect(described_class.compare(*facts).by_words).to be(false)
  end
end
