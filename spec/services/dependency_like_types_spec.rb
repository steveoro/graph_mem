# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the dependency-like types setting and its matcher.
RSpec.describe DependencyLikeTypes do
  describe "the default list" do
    subject(:types) { described_class.current }

    it "is Framework, Gem, Tool, SoftwareLibrary, TestFramework, matched with the vocabulary's aliases, case-insensitively" do
      expect(AppSettings.dependency_like_types_list).to eq("Framework, Gem, Tool, SoftwareLibrary, TestFramework")
      expect(types.types).to eq(%w[Framework Gem Tool SoftwareLibrary TestFramework])
      %w[Framework framework frameworks lib library LIBRARY Gem gem gems rubygem Tool tool tools SoftwareLibrary
         softwarelibrary TestFramework].each do |type|
        expect(types.match?(type)).to be(true), type
      end
    end

    it "matches no other type, and never a Project" do
      [ "Service", "Component", "Project", "repo", "Class", "", nil ].each do |type|
        expect(types.match?(type)).to be(false), type.inspect
      end
    end
  end

  it "canonicalizes the listed types too, so an alias in the list stands for its canonical type" do
    types = described_class.new("library, RUBYGEM")

    expect(types.match?("Framework")).to be(true)
    expect(types.match?("lib")).to be(true)
    expect(types.match?("Gem")).to be(true)
    expect(types.match?("Tool")).to be(false)
  end

  it "keeps a type the vocabulary doesn't know, matched case-insensitively" do
    types = described_class.new("SynthPlugin")

    expect(types.match?("synthplugin")).to be(true)
    expect(types.match?("SynthPlug")).to be(false)
  end

  it "reads the setting uncached, and a blank list matches nothing" do
    AppSettings.dependency_like_types = ""

    expect(described_class.current).to be_empty
    expect(described_class.current.match?("Gem")).to be(false)

    AppSettings.dependency_like_types = "Service"
    expect(described_class.current.match?("service")).to be(true)
  end

  it "tells a dependency-like entity from a Project or another type" do
    types = described_class.current
    gem = MemoryEntity.create!(name: "SynthLib #{SecureRandom.hex(3)}", entity_type: "rubygem")
    service = MemoryEntity.create!(name: "SynthService #{SecureRandom.hex(3)}", entity_type: "Service")
    project = MemoryEntity.create!(name: "SynthApp #{SecureRandom.hex(3)}", entity_type: "Project")

    expect(gem.entity_type).to eq("Gem")
    expect([ gem, service, project, nil ].map { |entity| types.entity?(entity) }).to eq([ true, false, false, false ])
  end

  it "lists the stored spellings that match, for queries" do
    MemoryEntity.create!(name: "SynthLib #{SecureRandom.hex(3)}", entity_type: "Gem")
    raw = MemoryEntity.create!(name: "SynthFramework #{SecureRandom.hex(3)}", entity_type: "Framework")
    raw.update_column(:entity_type, "library") # a spelling stored before the save canonicalized it
    MemoryEntity.create!(name: "SynthService #{SecureRandom.hex(3)}", entity_type: "Service")

    expect(described_class.current.stored_types).to contain_exactly("Gem", "library")
  end

  describe ".check (the Settings validator)" do
    it "normalizes the list it accepts" do
      expect(described_class.check(" gem ,Tool,, GEM\nSynth Plugin-2 ")).to eq([ [], "gem, Tool, Synth Plugin-2" ])
      expect(described_class.check("")).to eq([ [], "" ])
    end

    it "refuses Project and its aliases, odd characters, long entries and long lists" do
      expect(described_class.check("Gem, Project, repo").first).to eq(%w[Project repo])
      expect(described_class.check("Gem; Tool").first).to eq([ "Gem; Tool" ])
      expect(described_class.check("x" * 65).first).to eq([ "x" * 65 ])
      expect(described_class.check((1..21).map { |i| "Type#{i}" }.join(",")).first).to eq([ "more than 20 types" ])
    end
  end
end
