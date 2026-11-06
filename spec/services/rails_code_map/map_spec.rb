# frozen_string_literal: true

require "rails_helper"

# 1.75.0: RailsCodeMap::Map's name resolution and part guide, on hand-built entries.
RSpec.describe RailsCodeMap::Map do
  def entry(name, type, file)
    short = name.split("::").last
    path = file.split("/").drop(2).join("/").delete_suffix(".rb")
    RailsCodeMap::Entry.new(name: name, type: type, kind: "Class", files: [ file ], facts: [], aliases: [ short, path ],
                            keys: [ name, short, path, file ].map { |text| RailsCodeMap.lookup_key(text) }.uniq, superclass: nil)
  end

  let(:model) { entry("Gadget::Badge", "Model", "app/models/gadget/badge.rb") }
  let(:importer) { entry("Gadget::Importers::Badge", "Strategy", "app/strategies/gadget/importers/badge.rb") }
  let(:swimmer) { entry("Gadget::Swimmer", "Model", "app/models/gadget/swimmer.rb") }
  let(:runner) { entry("Gadget::Importers::Runner", "Strategy", "app/strategies/gadget/importers/runner.rb") }
  let(:map) do
    described_class.new(entries: [ model, importer, swimmer, runner ],
                        edges: [ RailsCodeMap::Edge.new(from: "Gadget::Swimmer", to: "Gadget::Badge", relation: "has_many") ],
                        gems: Set["goggles-db"])
  end

  it "resolves an exact name in any case, and a unique short name or path; a spaced name does not cross a namespace" do
    expect(map.resolve("gadget::badge").entry).to eq(model)
    expect(map.resolve("Swimmer").entry).to eq(swimmer)
    expect(map.resolve("gadget/swimmer").entry).to eq(swimmer)
    expect(map.resolve("gadget swimmer").status).to eq(:none)
    expect(map.resolve("Gadget Swimmer").status).to eq(:none)
    expect(map.resolve("runner").entry).to eq(runner)
  end

  it "answers :ambiguous for a short name two entries share, with no file to narrow it" do
    found = map.resolve("Badge", files: [ "README.md" ])

    expect(found.status).to eq(:ambiguous)
    expect(found.candidates).to contain_exactly("Gadget::Badge", "Gadget::Importers::Badge")
  end

  it "narrows a shared short name by the part's files, its related entries, then its namespace" do
    expect(map.resolve("Badge", files: [ "app/strategies/gadget/importers/badge.rb" ]).entry).to eq(importer)
    expect(map.resolve("Badge", files: [ "app/models/gadget/swimmer.rb" ]).entry).to eq(model)
    expect(map.resolve("Badge", files: [ "app/strategies/gadget/importers/runner.rb" ]).entry).to eq(importer)
  end

  it "answers :ambiguous in a part that defines both, whatever its related entries" do
    found = map.resolve("Badge", files: [ "app/models/gadget/badge.rb", "app/strategies/gadget/importers/badge.rb",
                                          "app/models/gadget/swimmer.rb" ])

    expect(found.status).to eq(:ambiguous)
  end

  it "answers :none for a name it doesn't hold" do
    expect(map.resolve("FrameBuffer").status).to eq(:none)
    expect(map.resolve("  ").status).to eq(:none)
  end

  it "guides a part with its own entries, the related ones and the ones its text names" do
    guide = map.guide_for([ "app/models/gadget/swimmer.rb" ], text: "Swimmer uses Runner; a Badge too.")

    expect(guide[:own]).to eq([ swimmer ])
    expect(guide[:related]).to eq([ model, runner ])
  end

  it "matches gem names with dashes, underscores and spaces alike" do
    expect(map.gem?("goggles_db")).to be(true)
    expect(map.gem?("Goggles DB")).to be(true)
  end

  it "has an empty, complete, frozen EMPTY map" do
    expect(described_class::EMPTY).to be_frozen.and(be_empty).and(be_complete)
    expect(described_class::EMPTY.resolve("Badge").status).to eq(:none)
  end
end
