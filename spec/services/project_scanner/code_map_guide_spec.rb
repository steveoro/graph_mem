# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.75.0: a Rails project's code map between the model and the graph, part by part.
RSpec.describe ProjectScanner::CodeMapGuide do
  around do |example|
    Dir.mktmpdir("code-map-guide") do |dir|
      @map = RailsCodeMap.build(write_rails_code_map_tree(dir), reserved_names: [ "Gadget" ])
      example.run
    end
  end

  let(:guide) { described_class.new(@map) }

  def answer(*items)
    { "project" => { "name" => "Gadget" }, "architecture" => items }
  end

  def item(name, type, relations: [], aliases: nil)
    { "entity" => { "name" => name, "type" => type, "aliases" => aliases }.compact, "observations" => [ "#{name} fact." ],
      "relations" => relations }
  end

  it "lists the part's own code entities, the related ones and the gem rule" do
    found = guide.prompt_guide([ "app/models/gadget/badge.rb" ], "class Badge < ApplicationRecord")

    expect(found[:own]).to eq([ "Gadget::Badge (Model)" ])
    expect(found[:related]).to include("Gadget::Swimmer (Model)", "Gadget::Trackable (Concern)", "Gadget::ApplicationRecord (Model)")
    expect(found[:gems]).to be(true)
  end

  it "drops a bare Badge in a part that can't tell the two Badges apart, and counts it" do
    data = guide.canonicalize(answer(item("Badge", "Class"), item("Swimmer", "Class")), [ "README.md" ])

    expect(data["architecture"].map { |kept| kept.dig("entity", "name") }).to eq([ "Gadget::Swimmer" ])
    expect(guide.counts).to include(items_dropped: 1, items_mapped: 1)
  end

  it "maps a bare Badge by the part's files: the model in the model's part, the importer in the importer's" do
    model = guide.canonicalize(answer(item("Badge", "Class")), [ "app/models/gadget/badge.rb" ])
    importer = guide.canonicalize(answer(item("Badge", "Service")), [ "app/strategies/gadget/importers/badge.rb" ])

    expect(model["architecture"].sole["entity"]).to include("name" => "Gadget::Badge", "type" => "Model")
    expect(importer["architecture"].sole["entity"]).to include("name" => "Gadget::Importers::Badge", "type" => "Strategy")
  end

  it "drops the model's aliases and part_of from a mapped item and maps its relation targets" do
    relations = [ { "to" => "Gadget", "type" => "part_of" }, { "to" => "Swimmer", "type" => "belongs_to" },
                  { "to" => "Badge", "type" => "relates_to" }, { "to" => "FrameBuffer", "type" => "uses" } ]
    data = guide.canonicalize(answer(item("SwimmersController", "Route", relations: relations, aliases: [ "Swimmers" ])),
                              [ "README.md" ])

    kept = data["architecture"].sole
    expect(kept["entity"]).to eq("name" => "Gadget::SwimmersController", "type" => "Controller")
    expect(kept["relations"].map { |relation| relation["to"] }).to eq([ "Gadget::Swimmer", "FrameBuffer" ])
    expect(guide.counts[:targets_dropped]).to eq(1)
  end

  it "types an unmapped declared gem as Gem and leaves other unmapped items as the model gave them" do
    data = guide.canonicalize(answer(item("grape", "APIEndpoint"), item("Swim Meets", "Concept"), item("Gadget", "Project")),
                              [ "Gemfile" ])

    expect(data["architecture"].map { |kept| kept["entity"].values_at("name", "type") })
      .to eq([ %w[grape Gem], [ "Swim Meets", "Concept" ], %w[Gadget Project] ])
    expect(guide.counts[:gems_typed]).to eq(1)
  end

  it "passes an answer that isn't usable through unchanged" do
    expect(guide.canonicalize(nil, [])).to be_nil
    expect(guide.canonicalize({ "project" => {} }, [])).to eq({ "project" => {} })
  end
end
