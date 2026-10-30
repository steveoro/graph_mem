# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanner::ExtractionMerger do
  subject(:merger) { described_class.new }

  def item(name, type, observations: [], relations: [], aliases: [], description: nil)
    { "entity" => { "name" => name, "type" => type, "aliases" => aliases, "description" => description },
      "observations" => observations, "relations" => relations }
  end

  it "merges the same entity from two parts: aliases, observations and relations unioned" do
    merger.add("project" => { "name" => "Gadget Project", "description" => "Synthetic gadgets.", "aliases" => [ "gadget" ] },
               "architecture" => [
                 item("SynthWidget", "Class", aliases: [ "Widget" ], description: "",
                                              observations: [ "SynthWidget renders gadgets.", " Shared fact. " ],
                                              relations: [ { "to" => "Gadget Project", "type" => "part_of", "confidence" => 0.6 } ])
               ])
    merger.add("project" => { "name" => "Other name", "description" => "Later.", "aliases" => [ "GADGET", "gp" ] },
               "architecture" => [
                 item("synthwidget ", "class", aliases: [ "widget", "SW" ], description: "Renders gadgets.",
                                               observations: [ "Shared fact.", "SynthWidget caches frames." ],
                                               relations: [ { "to" => "gadget project", "type" => "part_of", "confidence" => 0.9 },
                                                            { "to" => "Alpha Service", "type" => "depends_on", "confidence" => 0.7 } ])
               ])

    result = merger.result

    expect(result["project"]).to eq("name" => "Gadget Project", "description" => "Synthetic gadgets.", "aliases" => %w[gadget gp])
    expect(result["architecture"].size).to eq(1)
    widget = result["architecture"].first
    expect(widget["entity"]).to eq("name" => "SynthWidget", "type" => "Class", "aliases" => %w[Widget SW], "description" => "Renders gadgets.")
    expect(widget["observations"]).to eq([ "SynthWidget renders gadgets.", "Shared fact.", "SynthWidget caches frames." ])
    expect(widget["relations"]).to contain_exactly(
      { "to" => "gadget project", "type" => "part_of", "confidence" => 0.9 },
      { "to" => "Alpha Service", "type" => "depends_on", "confidence" => 0.7 }
    )
  end

  it "keeps the same name with two types as two items" do
    merger.add("architecture" => [ item("Alpha Service", "Service") ])
    merger.add("architecture" => [ item("Alpha Service", "Module") ])

    expect(merger.result["architecture"].map { |entry| entry["entity"]["type"] }).to eq(%w[Service Module])
  end

  it "skips malformed parts and items" do
    expect(merger.add(nil)).to be false
    expect(merger.add("project" => { "name" => "No architecture" })).to be false
    expect(merger.add("architecture" => "not a list")).to be false
    expect(merger.add("architecture" => [ "text", { "entity" => "text" }, item("", "Class"), item("SynthWidget", "Class") ])).to be true

    expect(merger.result).to eq("project" => { "name" => nil, "aliases" => [], "description" => nil },
                                "architecture" => [ item("SynthWidget", "Class") ])
  end

  it "lists the names most mentioned first, then in first-seen order" do
    merger.add("architecture" => [
                 item("Alpha Service", "Service"), item("SynthWidget", "Class"),
                 item("Gadget Store", "Component", relations: [ { "to" => "SynthWidget", "type" => "depends_on" } ])
               ])

    expect(merger.names(limit: 50)).to eq([ "SynthWidget", "Alpha Service", "Gadget Store" ])
    expect(merger.names(limit: 1)).to eq([ "SynthWidget" ])
  end
end
