# frozen_string_literal: true

require "rails_helper"

# Dream State R1b (Steve's answer on scans): an item of a dependency-like type whose name a global
# entity of a dependency-like type holds is that entity: no project copy, no part_of, the
# project's depends_on it, and its facts on it, covered by the project's scan validation.
RSpec.describe ProjectScanner, "global dependencies" do
  include LlmSpecHelpers

  let(:root) { Dir.mktmpdir("dependency-scan") }
  let(:items) { [] }
  let(:provider) do
    FakeProvider.new { |*| { ok: true, done_reason: "stop", prompt_tokens: 10, error: nil, latency_ms: 1.0,
                             text: { project: { name: "Gadget Project" }, architecture: items }.to_json } }
  end
  let(:operator) { "operator:synth@127.0.0.1" }

  before { File.write(File.join(root, "README.md"), "# Gadget Project\n\nGadget Project parses feeds with SynthLib.\n") }
  after { FileUtils.rm_rf(root) }

  def item(name, type, *observations, relations: [])
    { entity: { name: name, type: type }, observations: observations, relations: relations }
  end

  def scan(*scan_items)
    items.replace(scan_items)
    with_llm_provider(provider) { described_class.new(project_root: root, project_name: "Gadget Project").call }
  end

  def project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)

  def libraries = MemoryEntity.where(name: "SynthLib")

  def swap!(library)
    relation = MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of")
    names = { library.id => library.name, relation.to_entity_id => project.name }
    row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [
      CompactionReviewApplier::RelationRetypeDependency.swap_item(relation, names, evidence: { entity_type: library.entity_type, facts: [] })
    ]).sole
    expect(Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid) }).to include(success: true)
  end

  def dependency_source?(fact) = ProjectScanner::GlobalDependencies.fact_source?(fact.source, project.id)

  it "after a swap, a rescan finds the global library: no copy, no part_of, the depends_on kept, its facts updated" do
    scan(item("SynthLib", "Gem", "SynthLib parses the feeds."))
    library = libraries.sole
    expect(library.project_id).to eq(project.id)
    swap!(library)

    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      scan(item("SynthLib", "rubygem", "SynthLib parses the feeds.", "SynthLib caches the parsed feeds.",
                relations: [ { to: "Gadget Project", type: "part_of" } ]))
    end

    expect(result.errors).to be_empty
    expect(libraries.pluck(:id, :project_id)).to eq([ [ library.id, nil ] ])
    expect(result.entities_created).to eq(0)
    expect(MemoryRelation.where(from_entity_id: library.id, relation_type: "part_of")).not_to exist
    expect(MemoryRelation.where(from_entity_id: project.id, to_entity_id: library.id, relation_type: "depends_on").count).to eq(1)
    facts = library.active_memory_observations.order(:id).to_a
    expect(facts.map(&:content)).to eq([ "SynthLib parses the feeds.", "SynthLib caches the parsed feeds." ])
    expect(dependency_source?(facts.last)).to be(true)
    expect(ProjectIdBackfill.new(out: StringIO.new).run.changed).to eq(0)
    expect(sql.grep(/GET_LOCK/)).to be_empty # no part_of was written for it, so nothing to sync

    scan(item("SynthWidget", "Class", "SynthWidget renders gadget frames."))

    expect(facts.last.reload.status).to eq("obsolete")
    expect(facts.first.reload.status).to eq("active") # written before the swap: not attributed to this project's dependency
    expect(MemoryRelation.where(from_entity_id: project.id, to_entity_id: library.id, relation_type: "depends_on")).to exist
    expect(library.reload.project_id).to be_nil
  end

  it "links a global library another project depends_on, and writes the scan's facts onto it" do
    other = fs_project!("Other Project")
    library = MemoryEntity.create!(name: "SynthLib", entity_type: "Framework")
    MemoryRelation.create!(from_entity: other, to_entity: library, relation_type: "depends_on")
    other_fact = fs_observe!(library, "SynthLib renders the reports.", source: "project_scan:earlier:dependency:#{other.id}")

    result = scan(item("SynthLib", "library", "SynthLib parses the feeds."))

    expect(result.errors).to be_empty
    expect(libraries.pluck(:id)).to eq([ library.id ])
    expect(library.reload.project_id).to be_nil
    expect(MemoryRelation.where(to_entity_id: library.id, relation_type: "depends_on").pluck(:from_entity_id)).to contain_exactly(other.id, project.id)
    expect(MemoryRelation.where(from_entity_id: library.id)).not_to exist
    expect(library.active_memory_observations.pluck(:content)).to contain_exactly("SynthLib renders the reports.", "SynthLib parses the feeds.")
    expect(other_fact.reload.status).to eq("active")
  end

  it "keeps the project's own item in the project when the model puts it part_of a global library" do
    other = fs_project!("Other Project")
    library = MemoryEntity.create!(name: "SynthLib", entity_type: "Framework")
    MemoryRelation.create!(from_entity: other, to_entity: library, relation_type: "depends_on")
    MemoryEntity.create!(name: "SynthCodec", entity_type: "Gem") # global, not named as an item in the scan

    result = scan(item("SynthLib", "Framework", "SynthLib parses the feeds."),
                  item("SynthWidget", "Class", "SynthWidget renders gadget frames.", relations: [ { to: "SynthLib", type: "part_of" } ]),
                  item("SynthPanel", "Class", "SynthPanel shows the codec output.", relations: [ { to: "SynthCodec", type: "part_of" } ]))

    expect(result.errors).to be_empty
    %w[SynthWidget SynthPanel].each do |name|
      entity = MemoryEntity.find_by!(name: name, project_id: project.id)
      expect(MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ project.id ]), name
    end
    expect(MemoryRelation.where(to_entity_id: library.id, relation_type: "part_of")).not_to exist
    expect(library.reload.project_id).to be_nil
    expect(ProjectIdBackfill.new(out: StringIO.new).run.changed).to eq(0)
  end

  it "makes a project copy as before when the namesake or the item isn't dependency-like" do
    MemoryEntity.create!(name: "SynthLib", entity_type: "Service")
    MemoryEntity.create!(name: "SynthGem", entity_type: "Gem")

    result = scan(item("SynthLib", "Gem", "SynthLib parses the feeds."), item("SynthGem", "Class", "SynthGem wraps the gem."))

    expect(result.errors).to be_empty
    expect(MemoryEntity.where(name: %w[SynthLib SynthGem], project_id: project.id).count).to eq(2)
    expect(MemoryRelation.where(from_entity_id: project.id, relation_type: "depends_on")).not_to exist
  end

  it "validates only this project's facts on the global library" do
    other = fs_project!("Other Project")
    library = MemoryEntity.create!(name: "SynthLib", entity_type: "Gem")
    MemoryRelation.create!(from_entity: other, to_entity: library, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: MemoryEntity.create!(name: "Gadget Project", entity_type: "Project"), to_entity: library,
                           relation_type: "depends_on")
    mine = fs_observe!(library, "Feeds are parsed in batches of ten.", source: "project_scan:earlier:dependency:#{project.id}")
    theirs = fs_observe!(library, "Reports are rendered nightly.", source: "project_scan:earlier:dependency:#{other.id}")
    manual = fs_observe!(library, "Upgraded last spring.")

    result = scan(item("SynthLib", "Gem", "SynthLib parses the feeds."))

    expect(result.errors).to be_empty
    expect(mine.reload.status).to eq("obsolete")
    expect([ theirs, manual ].map { |fact| fact.reload.status }).to eq(%w[active active])
    expect(result.scan_review_items.map { |review| review[:observation_id] }).not_to include(manual.id, theirs.id)
  end
end
