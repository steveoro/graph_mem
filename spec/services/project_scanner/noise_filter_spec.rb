# frozen_string_literal: true

require "rails_helper"

# F-3b step N: each noise rule on a synthetic extraction, and no rule drops an expected synth entity.
RSpec.describe ProjectScanner::NoiseFilter do
  def item(name, type = "Class", observations: [], relations: [], aliases: [])
    { "entity" => { "name" => name, "type" => type, "aliases" => aliases, "description" => nil },
      "observations" => observations, "relations" => relations }
  end

  def rel(to, type = "uses") = { "to" => to, "type" => type, "confidence" => 0.9 }

  def names(data) = data["architecture"].map { |entry| entry.dig("entity", "name") }

  def filter(*items) = described_class.call({ "project" => { "name" => "Gadget Project" }, "architecture" => items })

  it "lists every rule, in one constant, with a zero count when nothing is dropped" do
    data, dropped = filter(item("SynthWidget", observations: [ "SynthWidget renders gadget frames." ], relations: [ rel("FrameBuffer") ]))

    expect(described_class::RULES.keys).to eq(%w[duplicate_observations self_relations generic_items empty_items])
    expect(dropped).to eq(described_class::RULES.keys.index_with(0))
    expect(names(data)).to eq(%w[SynthWidget])
  end

  it "drops an observation equal to an earlier one ignoring case, punctuation and spacing (duplicate_observations)" do
    data, dropped = filter(item("AlphaService", observations: [ "AlphaService schedules SynthWidget renders.", "alphaservice  schedules synthwidget renders",
                                                                 "AlphaService schedules FrameBuffer flushes." ]))

    expect(data["architecture"].sole["observations"]).to eq([ "AlphaService schedules SynthWidget renders.", "AlphaService schedules FrameBuffer flushes." ])
    expect(dropped["duplicate_observations"]).to eq(1)
  end

  it "drops a relation to the item itself, by name or alias, keeping the others (self_relations)" do
    data, dropped = filter(item("AlphaService", observations: [ "AlphaService schedules renders." ], aliases: [ "Alpha Service" ],
                                                relations: [ rel("alphaservice"), rel("Alpha Service"), rel("SynthWidget", "depends_on") ]))

    expect(data["architecture"].sole["relations"].map { |relation| relation["to"] }).to eq(%w[SynthWidget])
    expect(dropped["self_relations"]).to eq(2)
  end

  it "drops an extension-only or generic name with at most one observation, and keeps one with more (generic_items)" do
    data, dropped = filter(item(".rb", "File", observations: [ "A Ruby file." ]), item("md", "File"),
                           item("Utils", "Module", observations: [ "Utils holds shared helpers." ]),
                           item("Config", "Module", observations: [ "Config reads gadget.yml.", "Config falls back to defaults." ]),
                           item("SynthWidget", observations: [ "SynthWidget renders gadget frames." ]))

    expect(names(data)).to eq(%w[Config SynthWidget])
    expect(dropped["generic_items"]).to eq(3)
  end

  it "drops an item with no observations and no relations that nothing relates to (empty_items)" do
    data, dropped = filter(item("Gadget Notes", "Concept"), item("FrameBuffer"),
                           item("SynthWidget", observations: [ "SynthWidget renders gadget frames." ], relations: [ rel("framebuffer") ]),
                           item("Rack", "Library", relations: [ rel("Gadget Project", "used_by") ]))

    expect(names(data)).to eq(%w[FrameBuffer SynthWidget Rack])
    expect(dropped["empty_items"]).to eq(1)
  end

  it "counts an item emptied by the other rules as empty" do
    _, dropped = filter(item("Gadget Notes", "Concept", relations: [ rel("Gadget Notes") ]))

    expect(dropped).to include("self_relations" => 1, "empty_items" => 1)
  end

  it "keeps the project and everything that isn't an item list" do
    data, = described_class.call({ "project" => { "name" => "Gadget Project", "description" => "Renders gadget frames." } })

    expect(data).to eq("project" => { "name" => "Gadget Project", "description" => "Renders gadget frames." }, "architecture" => [])
  end

  %w[docs code].each do |profile|
    it "drops no expected #{profile} entity of the synth repo, and drops its planted noise" do
      merger = ProjectScanner::ExtractionMerger.new
      Dir.mktmpdir("noise-filter-spec") do |dir|
        GraphMem::ScanProfile::SynthRepo.write(dir)
        files = GraphMem::ScanProfile::Workspace.resolved_files(dir, GraphMem::ScanProfile::SynthRepo::PROFILES.fetch(profile))
        files.each { |rel| merger.add(JSON.parse(GraphMem::ScanProfile::SynthRepo.stub_answer("--- FILE: #{rel}\n")[:text])) }
      end

      data, dropped = described_class.call(merger.result)

      expect(names(data)).to include(*GraphMem::ScanProfile::SynthRepo.expected(profile)[:entities])
      expect(names(data)).not_to include("Utils", "Helper", ".md", "Gadget Notes")
      expect(dropped.values.sum).to be_positive
    end
  end
end
