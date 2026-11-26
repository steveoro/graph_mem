# frozen_string_literal: true

require "rails_helper"

# Dream State R1c: which edges a removal fact is looked for on, and which facts count.
RSpec.describe RemovalEvidence do
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:uses) { MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on") }
  let!(:widget) { fs_member!(app, "SynthWidget", "Component") }
  let!(:tool) { fs_member!(app, "SynthCli", "Tool") } # a library not swapped yet
  let(:held) { MemoryRelation.find_by!(from_entity_id: tool.id, relation_type: "part_of") }

  def part_of(entity) = MemoryRelation.find_by!(from_entity_id: entity.id, relation_type: "part_of")

  describe ".edges" do
    it "reads a Project root's depends_on and the part_of edges into it from dependency-like entities, by id, after the cursor" do
      deep = fs_member!(tool, "SynthCli Helper", "Tool")
      MemoryRelation.create!(from_entity: widget, to_entity: library, relation_type: "depends_on")
      other = fs_project!("OtherPrj")
      nested = fs_member!(other, "SynthSubPrj", "Project")
      MemoryRelation.create!(from_entity: nested, to_entity: library, relation_type: "depends_on") # a nested Project is no root
      gem = fs_member!(other, "SynthGem", "rubygem") # dependency-like by its canonical type

      edges = described_class.edges(after_id: 0, limit: 50)

      expect(edges.map(&:id)).to eq([ uses.id, held.id, part_of(gem).id ])
      expect(edges.map(&:id)).not_to include(part_of(widget).id, part_of(deep).id, part_of(nested).id)
      expect(described_class.edges(after_id: uses.id, limit: 50).map(&:id)).to eq([ held.id, part_of(gem).id ])
      expect(described_class.edges(after_id: 0, limit: 1).map(&:id)).to eq([ uses.id ])
    end

    it "reads no part_of edge when the dependency-like types setting is blank, and follows a changed list" do
      expect(described_class.edges(after_id: 0, limit: 50, types: DependencyLikeTypes.new("")).map(&:id)).to eq([ uses.id ])
      expect(described_class.edges(after_id: 0, limit: 50, types: DependencyLikeTypes.new("Component")).map(&:id))
        .to eq([ uses.id, part_of(widget).id ])
    end

    it "gives the Project and the entity of each edge" do
      expect(described_class.ends(uses)).to eq([ app, library ])
      expect(described_class.ends(held)).to eq([ app, tool ])
    end
  end

  describe ".facts" do
    it "finds a project fact that names the entity with a removal phrase, on the root or on a member" do
      on_root = fs_observe!(app, "SynthApp replaced SynthLib with SynthParser in 2.0.")
      on_member = fs_observe!(widget, "We no longer use synthlib here; it was dropped.")
      fs_observe!(app, "SynthApp uses SynthLib to parse its feeds.") # no removal phrase
      fs_observe!(app, "Removed the old cache.") # removal, but not of SynthLib
      fs_observe!(app, "SynthLibrary was removed.") # another name: not a word match

      expect(described_class.facts(uses)).to eq([ on_root, on_member ])
    end

    it "reads the keyword path as well as the text" do
      fact = fs_observe!(app, "The parser gem was ripped out.")
      fact.update_columns(keywords: %w[SynthApp SynthLib], keywords_at: Time.current)
      pathless = fs_observe!(app, "SynthLib got removed.")
      pathless.update_columns(keywords: %w[SynthApp], keywords_at: Time.current) # a global library is in no project's path

      expect(described_class.facts(uses)).to eq([ fact, pathless ])
    end

    it "leaves out a global library's own facts and other projects' facts, and inactive ones" do
      fs_observe!(library, "SynthLib dropped Ruby 2 support.")
      other = fs_project!("OtherPrj")
      fs_observe!(other, "OtherPrj removed SynthLib.")
      fs_observe!(app, "SynthApp removed SynthLib.").mark_obsolete!(reason: "synthetic retire")

      expect(described_class.facts(uses)).to be_empty
    end

    it "counts a held library's own facts, since it is the project's" do
      fact = fs_observe!(tool, "SynthCli was removed from the build.")

      expect(described_class.facts(held)).to eq([ fact ])
    end

    it "matches each phrase of the list, case-insensitively" do
      described_class::PHRASES.each do |phrase|
        expect(described_class::REMOVAL_PATTERN).to match("We #{phrase.sub('…', 'SynthLib').upcase} SynthParser."), phrase
      end
      expect(described_class::REMOVAL_PATTERN).not_to match("SynthLib was replaced.") # "replaced" needs by/with
      expect(described_class::REMOVAL_PATTERN).not_to match("We replaced one two three four with SynthParser.") # at most three words between
    end
  end
end
