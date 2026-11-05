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
end
