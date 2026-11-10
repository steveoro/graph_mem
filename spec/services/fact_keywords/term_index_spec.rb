# frozen_string_literal: true

require "rails_helper"

# 1.77.0: a fact's keyword path: project, own entity, then the project entities it mentions in order.
RSpec.describe FactKeywords::TermIndex do
  let(:root) { MemoryEntity.create!(name: "gadget_db", entity_type: "Project") }

  def entity(name, aliases = nil, type: "Model", parent: root)
    MemoryEntity.create!(name: name, entity_type: type, project_id: root.id, aliases: aliases).tap do |created|
      MemoryRelation.create!(from_entity_id: created.id, to_entity_id: parent.id, relation_type: "part_of")
    end
  end

  let!(:badge) { entity("Gadget::Badge", "Badge,gadget/badge") }
  let!(:importer) { entity("Gadget::Importers::Badge", "Badge,gadget/importers/badge", type: "Strategy") }
  let!(:swimmer) { entity("Gadget::Swimmer", "Swimmer,gadget/swimmer") }
  let!(:season) { entity("Gadget::Season", "Season") }
  let!(:team) { entity("Gadget::Team", "Team") }
  let(:index) { described_class.new(root) }

  def path(text, owner) = index.path_for(text, owner: owner).path

  it "orders the path: project, own entity, then each mention in the order the text first names it" do
    text = "A Swimmer should only have a single Badge for a single Season, because it can be registered only to 1 Team per Season."

    expect(path(text, badge)).to eq([ "gadget_db", "Gadget::Badge", "Gadget::Swimmer", "Gadget::Season", "Gadget::Team" ])
    expect(path("Team before Swimmer, then Team again.", season)).to eq([ "gadget_db", "Gadget::Season", "Gadget::Team", "Gadget::Swimmer" ])
  end

  it "reads a short name the own entity shares as the own entity, and leaves out one other entities share" do
    expect(path("Badge belongs to a Swimmer.", badge)).to eq([ "gadget_db", "Gadget::Badge", "Gadget::Swimmer" ])
    result = index.path_for("Every Badge has a Team.", owner: swimmer)

    expect(result.path).to eq([ "gadget_db", "Gadget::Swimmer", "Gadget::Team" ])
    expect(result.ambiguous).to eq(1)
  end

  it "matches qualified names, path aliases, plurals, any case and separator, and multi-word names" do
    meet = entity("Swim Meet")

    expect(path("Gadget::Importers::Badge reads gadget/swimmer rows.", team)).to eq([ "gadget_db", "Gadget::Team", "Gadget::Importers::Badge", "Gadget::Swimmer" ])
    expect(path("Teams join swim meets; a SWIM_MEET has teams.", swimmer)).to eq([ "gadget_db", "Gadget::Swimmer", "Gadget::Team", "Swim Meet" ])
    expect(path("swimmeet", team)).to eq([ "gadget_db", "Gadget::Team", meet.name ])
  end

  it "never adds the project, a term under three characters or a name twice" do
    entity("UI")

    expect(path("gadget_db keeps UI state for each Team and Team.", season)).to eq([ "gadget_db", "Gadget::Season", "Gadget::Team" ])
  end

  it "holds at most MAX_PATH names" do
    names = (1..15).map { |i| entity("Widget#{i}").name }

    expect(path(names.join(" "), team).size).to eq(described_class::MAX_PATH)
  end

  it "starts at the entity for a fact on the project root, and has no mentions without a project" do
    loose = MemoryEntity.create!(name: "Loose Note", entity_type: "Concept")

    expect(path("The Team list.", root)).to eq([ "gadget_db", "Gadget::Team" ])
    expect(described_class.new(nil).path_for("The Team list.", owner: loose).path).to eq([ "Loose Note" ])
  end
end
