# frozen_string_literal: true

require "rails_helper"

# F-3b step M: the noise metrics, on a synthetic graph.
RSpec.describe GraphMem::ScanProfile::Metrics do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }

  def entity(name, type = "Class", observations: [])
    MemoryEntity.create!(name: name, entity_type: type, project_id: project.id).tap do |record|
      observations.each { |text| MemoryObservation.create!(memory_entity: record, content: text) }
    end
  end

  def relate(from, to, type = "uses")
    MemoryRelation.create!(from_entity_id: from.id, to_entity_id: to.id, relation_type: type)
  end

  before do
    widget = entity("SynthWidget", observations: [ "SynthWidget renders gadget frames.", "synthwidget renders gadget frames" ])
    service = entity("AlphaService", "Service", observations: [ "AlphaService schedules SynthWidget renders.", "Fast." ])
    entity("Utils", "Module", observations: [ "Utils holds shared helpers." ])
    entity(".rb", "File", observations: [ "A Ruby file." ])
    entity("Gadget Notes", "Concept")
    report = entity("ReportBuilder", observations: [ "ReportBuilder writes one report section per frame." ])
    relate(service, widget, "depends_on")
    relate(report, project, "part_of")
  end

  it "counts empty entities, short and duplicate observations, generic and file names, root-only and isolated entities, and types" do
    metrics = described_class.call(project)

    expect(metrics).to include("entities" => 6, "entities_without_observations" => 1, "observations" => 7, "short_observations" => 2,
                               "duplicate_observations" => 1, "generic_names" => 1, "filename_names" => 1,
                               "root_only_entities" => 1, "isolated_entities" => 3)
    expect(metrics["types"]).to eq("Class" => 2, "Concept" => 1, "File" => 1, "Module" => 1, "Service" => 1)
    expect(metrics).not_to include("recall")
  end

  it "measures recall and precision against an expected list (synth)" do
    expected = { entities: %w[SynthWidget AlphaService FrameBuffer], relations: [ %w[AlphaService depends_on SynthWidget], %w[SynthWidget uses FrameBuffer] ] }

    metrics = described_class.call(project, expected: expected)

    expect(metrics["recall"]).to eq("entities" => 0.667, "relations" => 0.5)
    expect(metrics["precision"]).to eq("entities" => 0.333, "relations" => 1.0)
    expect(metrics["missed"]).to eq(%w[FrameBuffer])
    expect(metrics["unexpected"]).to eq([ ".rb", "Gadget Notes", "ReportBuilder", "Utils" ])
  end

  it "sums a rescan's churn, and has none without a rescan" do
    rescan = { "entities_created" => 1, "observations_created" => 2, "observations_obsoleted" => 3, "relations_created" => 0,
               "relations_deleted" => 1, "entities_updated" => 9 }

    expect(described_class.churn(rescan)).to eq(7)
    expect(described_class.churn(nil)).to be_nil
  end

  it "knows bare file names and generic words" do
    expect(%w[.rb md user.rb README.md Gemfile package.json].map { |name| described_class.filename?(name) }).to all(be(true))
    expect(%w[SynthWidget AlphaService Utils Gadget\ Project].map { |name| described_class.filename?(name) }).to all(be(false))
    expect(described_class.generic?(" utils ")).to be(true)
    expect(described_class.generic?("SynthWidget")).to be(false)
  end
end
