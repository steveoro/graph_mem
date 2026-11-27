# frozen_string_literal: true

require "rails_helper"

# What a graph_mem-sql export carries (SqlExport::Scope), with Dream State R1b's one hop of
# depends_on: a Project's script carries its global libraries as rows, with their own part_of
# subtrees, and not their other dependents. Real rows, no doubles.
RSpec.describe SqlExport::Scope do
  let!(:app) { fs_project!("SynthApp") }
  let!(:widget) { fs_member!(app, "SynthWidget", "Component") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:notes) { fs_member!(library, "SynthLib Notes", "Documentation") }
  let!(:uses) { MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on") }
  let!(:other) { fs_project!("OtherPrj") }
  let!(:other_uses) { MemoryRelation.create!(from_entity: other, to_entity: library, relation_type: "depends_on") }

  def relation_pairs(scope)
    MemoryRelation.where(id: scope.relation_ids).map { |relation| [ relation.from_entity.name, relation.relation_type, relation.to_entity.name ] }
  end

  it "carries each global non-Project target of the Project's depends_on as rows, with its part_of subtree, in the global scope" do
    scope = described_class.new([ app.id ])

    expect(scope.entity_roots).to eq(app.id => nil, widget.id => app.id, library.id => nil, notes.id => nil)
    expect(scope.dependency_ids).to contain_exactly(library.id, notes.id)
    expect(relation_pairs(scope)).to contain_exactly([ "SynthWidget", "part_of", "SynthApp" ], [ "SynthApp", "depends_on", "SynthLib" ],
                                                     [ "SynthLib Notes", "part_of", "SynthLib" ])
    expect(scope.ref_ids).to be_empty
  end

  it "keeps the library's facts and leaves out its other dependents, while its own edges travel with a reference" do
    fact = fs_observe!(library, "SynthLib parses the feeds.")
    core = MemoryEntity.create!(name: "SynthCore", entity_type: "Gem")
    MemoryRelation.create!(from_entity: library, to_entity: core, relation_type: "depends_on")
    other_member = fs_member!(other, "OtherService", "Service")
    MemoryRelation.create!(from_entity: other_member, to_entity: notes, relation_type: "relates_to")

    scope = described_class.new([ app.id ])

    expect(scope.observation_ids).to include(fact.id)
    expect(relation_pairs(scope)).to include([ "SynthLib", "depends_on", "SynthCore" ])
    expect(relation_pairs(scope).map(&:first)).not_to include("OtherPrj", "OtherService")
    expect(scope.ref_ids).to eq([ core.id ]) # one hop only: SynthCore is a reference, not a row
  end

  it "names no other project through the library: its and its child's edges out to another project, and that project's scan facts on it, stay out" do
    secret_widget = fs_member!(other, "SecretWidget", "Component")
    secret_service = fs_member!(other, "SecretService", "Service")
    MemoryRelation.create!(from_entity: library, to_entity: secret_widget, relation_type: "relates_to")
    MemoryRelation.create!(from_entity: notes, to_entity: secret_service, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: library, to_entity: other, relation_type: "relates_to")
    core = MemoryEntity.create!(name: "SynthCore", entity_type: "Gem")
    MemoryRelation.create!(from_entity: library, to_entity: core, relation_type: "depends_on")
    theirs = fs_observe!(library, "SynthLib renders the secret reports.", source: "project_scan:s1:dependency:#{other.id}")
    mine = fs_observe!(library, "SynthLib parses the feeds.", source: "project_scan:s2:dependency:#{app.id}")
    manual = fs_observe!(library, "SynthLib is pinned to 2.x.")

    scope = described_class.new([ app.id ])

    names = relation_pairs(scope).flatten
    expect(names).not_to include("OtherPrj", "SecretWidget", "SecretService")
    expect(relation_pairs(scope)).to include([ "SynthLib", "depends_on", "SynthCore" ]) # a global library stays a reference
    expect(scope.ref_ids).to eq([ core.id ])
    expect(scope.observation_ids).to include(mine.id, manual.id)
    expect(scope.observation_ids).not_to include(theirs.id)

    alone = described_class.new([ library.id ]) # the library as a root of its own: every fact, every project a reference
    expect(alone.observation_ids).to include(theirs.id, mine.id, manual.id)
  end

  it "keeps a depends_on to a Project or to a member of another project as a reference" do
    platform = fs_project!("SynthPlatform")
    service = fs_member!(other, "OtherService", "Service")
    MemoryRelation.create!(from_entity: app, to_entity: platform, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: app, to_entity: service, relation_type: "depends_on")

    scope = described_class.new([ app.id ])

    expect(scope.entity_roots.keys).not_to include(platform.id, service.id)
    expect(scope.ref_ids).to contain_exactly(platform.id, service.id)
  end

  it "follows only the Project's own depends_on, not a member's" do
    helper = MemoryEntity.create!(name: "SynthHelperGem", entity_type: "Gem")
    MemoryRelation.create!(from_entity: widget, to_entity: helper, relation_type: "depends_on")

    scope = described_class.new([ app.id ])

    expect(scope.entity_roots.keys).not_to include(helper.id)
    expect(scope.ref_ids).to eq([ helper.id ])
  end

  it "applies the hop to each exported Project, nested ones included, and with NESTED=0 to the roots only" do
    nested = fs_member!(app, "SynthSubApp", "Project")
    tool = MemoryEntity.create!(name: "SynthTool", entity_type: "Tool")
    MemoryRelation.create!(from_entity: nested, to_entity: tool, relation_type: "depends_on")

    expect(described_class.new([ app.id ]).dependency_ids).to contain_exactly(library.id, notes.id, tool.id)
    expect(described_class.new([ app.id ], include_nested: false).dependency_ids).to contain_exactly(library.id, notes.id)
  end

  it "exports the library alone with its subtree, every dependent Project only as a reference" do
    scope = described_class.new([ library.id ])

    expect(scope.entity_roots).to eq(library.id => nil, notes.id => nil)
    expect(scope.dependency_ids).to be_empty
    expect(relation_pairs(scope)).to contain_exactly([ "SynthApp", "depends_on", "SynthLib" ], [ "OtherPrj", "depends_on", "SynthLib" ],
                                                     [ "SynthLib Notes", "part_of", "SynthLib" ])
    expect(scope.ref_ids).to contain_exactly(app.id, other.id)
  end

  it "keeps a library that is also a root a root: its other dependents travel as references" do
    scope = described_class.new([ app.id, library.id ])

    expect(scope.dependency_ids).to be_empty
    expect(relation_pairs(scope)).to include([ "OtherPrj", "depends_on", "SynthLib" ])
    expect(scope.ref_ids).to eq([ other.id ])
  end

  it "carries a library two exported Projects use once" do
    scope = described_class.new([ app.id, other.id ])

    expect(scope.entity_roots.keys.count(library.id)).to eq(1)
    expect(relation_pairs(scope)).to include([ "SynthApp", "depends_on", "SynthLib" ], [ "OtherPrj", "depends_on", "SynthLib" ])
    expect(scope.ref_ids).to be_empty
  end
end
