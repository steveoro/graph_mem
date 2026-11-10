# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.75.0: a Rails project's scan writes its code map as the skeleton and hands it to the model; the
# model's names are mapped back to the skeleton's (spec/support/rails_code_map_tree.rb).
RSpec.describe ProjectScanner, "Rails code map" do
  include LlmSpecHelpers

  let(:root) { write_rails_code_map_tree(Dir.mktmpdir("code-map-scan")) }
  let(:globs) { %w[README.md Gemfile app/models/**/*.rb app/strategies/**/*.rb] }
  # The model's items per file: a bare Badge in the README, the model's Badge by its full name, the
  # importer by a trailing name, a gem typed as a framework. The small files share one part, which
  # defines both Badges, so the bare one is ambiguous. Narrowing a part by its own files:
  # chunked_extraction_spec.
  let(:answers) do
    {
      "README.md" => [ item("Badge", "Concept", "A Badge belongs to a Swimmer."), item("Gadget", "Project", "Gadget is an engine.") ],
      "Gemfile" => [ item("grape", "Framework", "Grape serves the API.") ],
      "app/models/gadget/badge.rb" => [ item("Gadget::Badge", "Class", "Badge belongs to a swimmer.",
                                             relations: [ { to: "Gadget", type: "part_of" }, { to: "Swimmer", type: "belongs_to" } ]) ],
      "app/strategies/gadget/importers/badge.rb" => [ item("Importers::Badge", "Service", "Importers::Badge imports badges.") ]
    }
  end
  let(:provider) do
    FakeProvider.new do |prompt, **|
      files = prompt.to_s.scan(/^--- FILE: (\S+)/).flatten.uniq
      { ok: true, done_reason: "stop", prompt_tokens: 10, error: nil, latency_ms: 1.0,
        text: { project: { name: "Gadget" }, architecture: files.flat_map { |file| answers.fetch(file, []) } }.to_json }
    end
  end

  after { FileUtils.rm_rf(root) }

  def item(name, type, *observations, relations: [])
    { entity: { name: name, type: type }, observations: observations, relations: relations }
  end

  def scan(scan_provider = provider, **options)
    with_llm_provider(scan_provider) do
      described_class.new(project_root: root, project_name: "Gadget", file_globs: globs, **options).call
    end
  end

  def project = MemoryEntity.find_by!(name: "Gadget", entity_type: "Project")

  def entity(name) = MemoryEntity.find_by!(name: name, project_id: project.id)

  it "writes the skeleton, maps the model's names onto it and drops the ambiguous bare Badge" do
    result = scan

    expect(result.errors).to be_empty
    expect(entity("Gadget::Badge").entity_type).to eq("Model")
    expect(entity("Gadget::Badge").memory_observations.active.pluck(:content))
      .to contain_exactly("Defined at app/models/gadget/badge.rb:L2", "Badge belongs to a swimmer.")
    expect(entity("Gadget::Importers::Badge")).to have_attributes(entity_type: "Strategy")
    expect(entity("Gadget::Importers::Badge").memory_observations.active.pluck(:content)).to include("Importers::Badge imports badges.")
    expect(MemoryEntity.where(name: "Badge")).to be_empty
    expect(entity("grape").entity_type).to eq("Gem")
    expect(project.memory_observations.pluck(:content)).to include("Gadget is an engine.")
    expect(MemoryRelation.exists?(from_entity_id: entity("Gadget::Badge").id, to_entity_id: entity("Gadget::Swimmer").id,
                                  relation_type: "belongs_to")).to be(true)
    expect(result.code_map).to include(entities: 15, views: 3, complete: true, items_mapped: 2, items_dropped: 1, gems_typed: 1,
                                       entities_created: 15)
    expect(result.to_h[:code_map]).to eq(result.code_map)
  end

  it "drops a bare Badge a README-only part can't tell apart, and counts it" do
    globs.replace(%w[README.md Gemfile])

    result = scan

    expect(result.errors).to be_empty
    expect(MemoryEntity.where(name: "Badge")).to be_empty
    expect(entity("Gadget::Badge").memory_observations.active.pluck(:content)).to eq([ "Defined at app/models/gadget/badge.rb:L2" ])
    expect(result.code_map).to include(items_dropped: 1, items_mapped: 0)
  end

  it "puts the code map in each part's prompt, and logs its counts on one numbers-only line" do
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first if args.first.to_s.start_with?("[scan] ")
      original.call(*args, &block)
    end

    scan

    expect(provider.calls.map(&:prompt).join).to include("Gadget::Badge (Model)")
    line = lines.grep(/code_map/).sole
    expect(line).to include('"entities":15')
    expect(line).not_to include("Badge")
  end

  it "creates nothing on a second scan and keeps the skeleton's facts and relations through validation" do
    scan
    counts = [ MemoryEntity.count, MemoryRelation.count ]

    result = scan

    expect(result.code_map).to include(entities_created: 0, relations_created: 0, observations_obsoleted: 0)
    expect([ MemoryEntity.count, MemoryRelation.count ]).to eq(counts)
    expect(entity("Gadget::Swimmer").memory_observations.active.where(source: RailsCodeMap::SOURCE).count).to eq(1)
    expect(result.scan_review_items.map { |item| item[:kind] }).not_to include("delete_relation")
  end

  it "writes the skeleton when the scan falls back without a model" do
    result = scan(FakeProvider.new(available: false))

    expect(result.fallback).to be(true)
    expect(entity("Gadget::SwimmersController").entity_type).to eq("Controller")
    expect(result.code_map).to include(entities_created: 15)
  end

  it "writes nothing in a dry run" do
    result = scan(dry_run: true)

    expect(MemoryEntity.where(name: "Gadget::Badge")).to be_empty
    expect(result.code_map).to include(entities: 15)
    expect(result.code_map).not_to have_key(:entities_created)
  end

  it "adds nothing for a project that isn't a Rails project" do
    FileUtils.rm_rf(File.join(root, "app"))

    result = scan

    expect(result.code_map).to eq({})
    expect(provider.calls.map(&:prompt).join).not_to include("Code entities defined")
  end

  it "doesn't bind a target the map doesn't know to a class whose path alias contains it" do
    answers["app/models/gadget/badge.rb"] = [ item("Gadget::Badge", "Class", "Badge belongs to a swimmer.",
                                                   relations: [ { to: "Swimmers", type: "relates_to" }, { to: "Importer", type: "relates_to" } ]) ]

    scan

    badge = entity("Gadget::Badge")
    expect(MemoryRelation.where(from_entity_id: badge.id, relation_type: "relates_to")).to be_empty
  end

  it "keeps a code entity's earlier scan fact that doesn't name it through a rescan's validation" do
    answers["app/models/gadget/swimmer.rb"] = [ item("Swimmer", "Class", "Not meant to be instantiated directly.") ]
    # A non-code entity in the project's tree keeps today's rule.
    answers["README.md"] << item("Swim Meet", "Concept", "Gathers the season's results.", relations: [ { to: "Gadget", type: "part_of" } ])
    scan
    swimmer_fact = entity("Gadget::Swimmer").memory_observations.find_by!(content: "Not meant to be instantiated directly.")
    meet_fact = entity("Swim Meet").memory_observations.find_by!(content: "Gathers the season's results.")
    # The rescan states another fact, so the first one isn't restated (a restated fact is left alone, 1.76.0).
    answers["README.md"][-1] = item("Swim Meet", "Concept", "Swim Meets close the season.", relations: [ { to: "Gadget", type: "part_of" } ])

    scan

    expect(swimmer_fact.reload.status).to eq("active")
    expect(meet_fact.reload.status).to eq("obsolete")
  end

  it "keeps a code entity's earlier scan fact that names another class where the scan filed it" do
    answers["app/models/gadget/badge.rb"] = [ item("Gadget::Badge", "Class", "It belongs to a Swimmer.") ]
    scan
    fact = entity("Gadget::Badge").memory_observations.find_by!(content: "It belongs to a Swimmer.")

    result = scan

    expect(fact.reload).to have_attributes(status: "active", memory_entity_id: entity("Gadget::Badge").id)
    expect(entity("Gadget::Swimmer").memory_observations.where(content: "It belongs to a Swimmer.")).to be_empty
    expect(result.observations_moved).to eq(0)
  end
end
