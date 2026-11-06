# frozen_string_literal: true

require "rails_helper"

# Reconcile fixes found by the first real scan profile (1.73.1): one entity per name in a project
# whatever the model's type, items typed "Project" and items naming the scanned project.
RSpec.describe ProjectScanner, "reconcile" do
  include LlmSpecHelpers

  let(:root) { Dir.mktmpdir("reconcile-scan") }
  let(:items) { [] }
  let(:provider) do
    FakeProvider.new { |*| { ok: true, done_reason: "stop", prompt_tokens: 10, error: nil, latency_ms: 1.0,
                             text: { project: { name: "Gadget Project" }, architecture: items }.to_json } }
  end

  before { File.write(File.join(root, "README.md"), "# Gadget Project\n\nSynthWidget renders gadget frames.\n") }
  after { FileUtils.rm_rf(root) }

  def item(name, type, *observations, relations: [])
    { entity: { name: name, type: type }, observations: observations, relations: relations }
  end

  def scan(**options)
    with_llm_provider(provider) { described_class.new(project_root: root, project_name: "Gadget Project", **options).call }
  end

  it "keeps one entity for a name the model typed twice, with both observations and no error" do
    items.push(item("SynthWidget", "Class", "SynthWidget renders gadget frames."),
               item("synthwidget", "Component", "SynthWidget keeps a FrameBuffer."))

    result = scan

    widget = MemoryEntity.find_by!(name: "SynthWidget")
    expect(result.errors).to be_empty
    expect(MemoryEntity.where(name: "SynthWidget").count).to eq(1)
    expect(widget.entity_type).to eq("Class")
    expect(widget.memory_observations.pluck(:content)).to contain_exactly("SynthWidget renders gadget frames.", "SynthWidget keeps a FrameBuffer.")
  end

  it "reuses an entity an earlier scan made with another type" do
    project = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Module", project_id: project.id)
    items.push(item("SynthWidget", "Class", "SynthWidget renders gadget frames."))

    result = scan

    expect(result.errors).to be_empty
    expect(MemoryEntity.where(name: "SynthWidget").pluck(:entity_type)).to eq(%w[Module])
    expect(result.entities_created).to eq(0)
  end

  it "makes an item typed as a project a Component of the scanned one when no root has its name" do
    items.push(item("Gadget Engine", "repository", "Gadget Engine stores the gadget tables."),
               item("SynthWidget", "Class", "SynthWidget renders gadget frames.", relations: [ { to: "Gadget Engine", type: "depends_on" } ]))

    result = scan

    project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
    engine = MemoryEntity.find_by!(name: "Gadget Engine")
    expect(result.errors).to be_empty
    expect(MemoryEntity.where(entity_type: "Project").pluck(:name)).to eq([ "Gadget Project" ])
    expect(engine).to have_attributes(entity_type: "Component", project_id: project.id)
    expect(MemoryRelation.where(from_entity_id: MemoryEntity.find_by!(name: "SynthWidget").id, to_entity_id: engine.id, relation_type: "depends_on")).to exist
  end

  describe "an item naming another Project root" do
    let!(:engine) { MemoryEntity.create!(name: "Gadget Engine", entity_type: "Project", aliases: "GadgetEngine") }
    let!(:engine_fact) { MemoryObservation.create!(memory_entity: engine, content: "Gadget Engine stores the gadget tables.") }

    before do
      items.push(item("gadget-engine", "Gem", "Gadget Engine is a Rails engine.", relations: [ { to: "Gadget Project", type: "part_of" } ]),
                 item("SynthWidget", "Class", "SynthWidget renders gadget frames.",
                      relations: [ { to: "gadget_engine", type: "depends_on" }, { to: "GadgetEngine", type: "part_of" } ]))
    end

    def relations(from, to) = MemoryRelation.where(from_entity_id: from.id, to_entity_id: to.id).pluck(:relation_type)

    it "links the scanned root to it once, resolves the name to it, and writes nothing to the other project" do
      result = scan

      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      widget = MemoryEntity.find_by!(name: "SynthWidget")
      expect(result.errors).to be_empty
      expect(MemoryEntity.where(entity_type: "Project").pluck(:name)).to contain_exactly("Gadget Engine", "Gadget Project")
      expect(MemoryEntity.where(project_id: project.id).pluck(:name)).to eq(%w[SynthWidget])
      expect(relations(project, engine)).to eq(%w[depends_on])
      expect(relations(widget, engine)).to eq(%w[depends_on])
      expect(relations(engine, project)).to be_empty
      expect(engine.reload).to have_attributes(project_id: nil, entity_type: "Project")
      expect(engine.memory_observations.pluck(:content)).to eq([ engine_fact.content ])
      expect(widget.reload.project_id).to eq(project.id)
    end

    it "adds no second link on a rescan, nor one next to a link made by hand" do
      scan
      scan(mode: "rescan")
      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      expect(relations(project, engine)).to eq(%w[depends_on])

      other = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
      MemoryRelation.create!(from_entity_id: other.id, to_entity_id: engine.id, relation_type: "relates_to")
      items.replace([ item("Gadget Engine", "Gem", "Gadget Engine is a Rails engine.") ])
      with_llm_provider(provider) { described_class.new(project_root: root, project_name: "Alpha Service").call }
      expect(relations(other, engine)).to eq(%w[relates_to])
    end

    it "replaces a Component an earlier scan made before the root existed: the next complete scan links the root and leaves the Component missing" do
      engine_fact.destroy!
      engine.destroy!
      scan
      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      component = MemoryEntity.find_by!(name: "gadget-engine", project_id: project.id)
      root = MemoryEntity.create!(name: "Gadget Engine", entity_type: "Project")

      result = scan(mode: "rescan")

      expect(relations(project, root)).to eq(%w[depends_on])
      expect(component.reload.active_memory_observations).to be_empty
      expect(result.scan_review_items).to include(a_hash_including(kind: "delete_entity", entity_id: component.id))
    end
  end

  describe "names shared with other Project roots (Graphy #158 round 2)" do
    def relations(from, to) = MemoryRelation.where(from_entity_id: from.id, to_entity_id: to.id).pluck(:relation_type)

    it "keeps a non-project item named like another root's alias local, with its facts and no link" do
      engine = MemoryEntity.create!(name: "Gadget Engine", entity_type: "Project", aliases: "api")
      items.push(item("Api", "Class", "Api renders the gadget endpoints."))

      result = scan

      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      api = MemoryEntity.find_by!(name: "Api", project_id: project.id)
      expect(result.errors).to be_empty
      expect(api.entity_type).to eq("Class")
      expect(api.memory_observations.pluck(:content)).to eq([ "Api renders the gadget endpoints." ])
      expect(relations(project, engine)).to be_empty
    end

    it "resolves a relation to a local entity before another root of the same name" do
      engine = MemoryEntity.create!(name: "Gadget Engine", entity_type: "Project")
      items.push(item("Gadget Engine", "Component", "The local Gadget Engine wraps the renderer."),
                 item("SynthWidget", "Class", "SynthWidget renders gadget frames.", relations: [ { to: "Gadget Engine", type: "depends_on" } ]))

      scan

      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      local = MemoryEntity.find_by!(name: "Gadget Engine", project_id: project.id)
      widget = MemoryEntity.find_by!(name: "SynthWidget")
      expect(relations(widget, local)).to eq(%w[depends_on])
      expect(relations(widget, engine)).to be_empty
      expect(relations(project, engine)).to be_empty
    end

    it "links to no root when two roots share the name, and counts it in one numbers-only line" do
      dash = MemoryEntity.create!(name: "gadget-engine", entity_type: "Project")
      underscore = MemoryEntity.create!(name: "gadget_engine", entity_type: "Project")
      items.push(item("Gadget Engine", "Gem", "Gadget Engine stores the gadget tables."))
      lines = []
      allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
        lines << args.first if args.first.to_s.start_with?("[scan] ")
        original.call(*args, &block)
      end

      result = scan

      project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
      expect(result.errors).to be_empty
      expect(relations(project, dash) + relations(project, underscore)).to be_empty
      expect(lines.grep(/ambiguous_project_roots/).sole).to match(/"ambiguous_project_roots":1\}\z/)
      expect(lines.grep(/ambiguous_project_roots/).sole).not_to include("gadget")
    end
  end

  it "leaves same-named entities of other projects and the global namespace alone" do
    other = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
    foreign = MemoryEntity.create!(name: "SynthWidget", entity_type: "Module", project_id: other.id)
    global = MemoryEntity.create!(name: "synthwidget", entity_type: "Component")
    items.push(item("SynthWidget", "Class", "SynthWidget renders gadget frames."))

    result = scan

    project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
    expect(result.errors).to be_empty
    expect(MemoryEntity.find_by!(name: "SynthWidget", project_id: project.id).entity_type).to eq("Class")
    expect(foreign.reload.memory_observations).to be_empty
    expect(global.reload.memory_observations).to be_empty
    expect([ foreign.entity_type, global.entity_type ]).to eq(%w[Module Component])
  end

  it "folds an item naming the scanned project (or an alias) into its root" do
    items.push(item("gadget project", "Project", "Gadget Project renders gadget frames.", relations: [ { to: "SynthWidget", type: "depends_on" } ]),
               item("Gadget", "Project", "Gadget ships a CLI."),
               item("SynthWidget", "Class", "SynthWidget renders gadget frames."))

    result = with_llm_provider(provider) do
      described_class.new(project_root: root, project_name: "Gadget Project", aliases: "Gadget").call
    end

    project = MemoryEntity.find_by!(name: "Gadget Project", project_id: nil)
    expect(result.errors).to be_empty
    expect(MemoryEntity.where(project_id: project.id).pluck(:name)).to eq(%w[SynthWidget])
    expect(project.memory_observations.pluck(:content)).to contain_exactly("Gadget Project renders gadget frames.", "Gadget ships a CLI.")
    expect(MemoryRelation.where(from_entity_id: project.id, relation_type: "depends_on")).to exist
  end
end
