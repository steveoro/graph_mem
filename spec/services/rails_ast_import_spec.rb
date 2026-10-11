# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

# Import-side coverage for the Rails AST extractor: the producer's rescan
# bucket and the folded-A4 cross-repo edge rule (B3 in the phase-B plan).
RSpec.describe "Rails AST extractor import" do
  # These specs create real entities whose names are globally unique —
  # purge anything a previous run left behind AND clean up after so
  # unrelated specs never see these names.
  before do
    purge_fixture_names
  end

  after do
    purge_fixture_names
  end

  def purge_fixture_names
    MemoryEntity.where(name: %w[OtherApp Fixture Team Swimmer Order GogglesDb
                                GogglesDb::User RepoA RepoB ApplicationRecord]).find_each do |e|
      MemoryRelation.where(from_entity_id: e.id).or(
        MemoryRelation.where(to_entity_id: e.id)
      ).delete_all
      e.destroy!
    end
  end

  def write_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "app/models"))
    File.write(File.join(dir, "app/models/swimmer.rb"), <<~RUBY)
      class Swimmer < ApplicationRecord
        belongs_to :team
      end
    RUBY
    File.write(File.join(dir, "app/models/team.rb"), <<~RUBY)
      class Team < ApplicationRecord
        has_many :swimmers
      end
    RUBY
  end

  def import_fixture(dir, project: "Fixture", rescan: nil)
    payload = RailsAstExtractor.extract(dir, project_name: project)
    result = GraphifyImporter.new(JSON.generate(payload), project_name: project).translate
    result.import_data["rescan"] = rescan unless rescan.nil?
    match = ImportMatchingStrategy.new.match(result.import_data)
    decisions = GraphifyImporter.headless_decisions(match[:match_results])
    ImportExecutionStrategy.new.execute(result.import_data, decisions)
  end

  it "marks the payload with the producer's rescan bucket" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      payload = RailsAstExtractor.extract(dir, project_name: "Fixture")
      result = GraphifyImporter.new(JSON.generate(payload), project_name: "Fixture").translate
      expect(result.import_data["rescan"]).to eq("rails_ast_extractor")
      expect(result.import_data["relations"].map { |r| r.dig("properties", "source") }.uniq)
        .to eq([ "rails_ast_extractor" ])
      expect(result.import_data["root_nodes"].first["children"].flat_map { |f|
        Array(f["observations"]).map { |o| o["source"] }
      }.uniq).to eq([ "rails_ast_extractor" ])
    end
  end

  it "tags edges whose far endpoint lives in another project's subtree (folded A4)" do
    # Pre-seed a DIFFERENT project owning "Team"/Class. The payload's Team
    # class merges onto that entity by name+type; its stored part_of parent
    # (foreign_root) lies outside this import's subtree → excluded subtree.
    # Swimmer's belongs_to :team is then an in-subtree → foreign-endpoint
    # edge: allowed, tagged cross_repo, counted.
    foreign_root = MemoryEntity.create!(name: "OtherApp", entity_type: "Project")
    foreign_team = MemoryEntity.create!(name: "Team", entity_type: "Class")
    # part_of points child → parent (Team part_of OtherApp).
    MemoryRelation.create!(from_entity: foreign_team, to_entity: foreign_root,
                           relation_type: "part_of")
    # OtherApp OWNS Team — active provenance makes it a claimed entity,
    # so this payload's reference-only Team node bridges (not merges).
    MemoryObservation.create!(memory_entity: foreign_team,
                              content: "Defined at app/models/team.rb",
                              source: "graphify")

    Dir.mktmpdir do |dir|
      write_fixture(dir)
      # No team.rb in this repo: Swimmer's belongs_to :team resolves to a
      # reference-only stub — the only endpoint kind allowed to bridge.
      FileUtils.rm(File.join(dir, "app/models/team.rb"))
      report = import_fixture(dir)

      expect(report.errors).to be_empty
      belongs = MemoryRelation.where(relation_type: "belongs_to")
      expect(belongs.count).to eq(1)
      edge = belongs.first
      expect(edge.to_entity_id).to eq(foreign_team.id)
      expect(edge.properties["cross_repo"]).to eq(true)
      expect(report.relations_cross_repo).to eq(1)
    end
  end

  it "rescan diffs only the producer's own provenance bucket" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      first = import_fixture(dir)
      expect(first.success).to be true

      swimmer = MemoryEntity.find_by(name: "Swimmer", entity_type: "Class")
      # A foreign (non-extractor) provenance obs on the same entity must NOT
      # be touched by an extractor rescan.
      foreign_obs = swimmer.memory_observations.create!(
        content: "Defined at lib/hand_made.rb:L1", status: MemoryObservation::ACTIVE_STATUS,
        source: "graphify", confidence: 1.0
      )
      # Removing belongs_to from the file should obsolete the extractor's
      # provenance but leave graphify's untouched.
      File.write(File.join(dir, "app/models/swimmer.rb"), "class Swimmer < ApplicationRecord; end\n")

      second = import_fixture(dir)
      expect(second.success).to be true
      expect(foreign_obs.reload.status).to eq(MemoryObservation::ACTIVE_STATUS)
      # The extractor's own provenance is obsoleted; the entity itself is
      # still present in the payload so nothing is flagged for deletion.
      # The removed `belongs_to` edge is flagged for review — the rescan
      # diff really ran — while neither producer's provenance is touched.
      expect(second.rescan_relations_flagged).to be >= 1
      expect(swimmer.memory_observations.where(source: "rails_ast_extractor")
              .pluck(:status).uniq).to eq([ MemoryObservation::ACTIVE_STATUS ])
    end
  end

  it "does not propose delete_entity for an entity another producer still owns" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      first = import_fixture(dir)
      expect(first.success).to be true

      swimmer = MemoryEntity.find_by(name: "Swimmer", entity_type: "Class")
      # A different producer owns this entity too — removing the file must
      # obsolete OUR provenance but never queue a delete_entity (the other
      # producer's rescan owns that decision).
      MemoryObservation.create!(memory_entity: swimmer,
                                content: "Defined at lib/swimmer.rb:L1",
                                source: "graphify")
      FileUtils.rm(File.join(dir, "app/models/swimmer.rb"))

      second = import_fixture(dir)
      expect(second.success).to be true
      # Only the File entity is flagged — Swimmer itself is protected by
      # the graphify provenance the other producer still owns.
      expect(second.rescan_entities_flagged).to eq(1)
      rows = MaintenanceReportRow.by_report_type("scan_review")
                                 .where("JSON_EXTRACT(payload, '$.entity_id') = ?", swimmer.id)
      expect(rows.where("JSON_EXTRACT(payload, '$.kind') = 'delete_entity'")).to be_empty
    end
  end

  it "moves a claimed stub into the declaring tree so the referencer's rescan does not flap" do
    # RepoB references GogglesDb::User (reference stub under RepoB's tree).
    # RepoA then declares it: the claim must REPLACE RepoB's stub edge with
    # RepoA's real parent — otherwise RepoB's unchanged rescan diffs RepoA's
    # provenance as its own and queues delete_entity (the A→B→A flap).
    Dir.mktmpdir do |dir_b|
      FileUtils.mkdir_p(File.join(dir_b, "app/models"))
      File.write(File.join(dir_b, "app/models/order.rb"), <<~RUBY)
        class Order < ApplicationRecord
          belongs_to :user, class_name: "GogglesDb::User"
        end
      RUBY
      import_fixture(dir_b, project: "RepoB")

      stub = MemoryEntity.find_by!(name: "GogglesDb::User", entity_type: "Class")
      stub_edge = MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of")
      expect(stub_edge.properties["reference_stub"]).to eq(true)

      Dir.mktmpdir do |dir_a|
        FileUtils.mkdir_p(File.join(dir_a, "app/models"))
        File.write(File.join(dir_a, "app/models/user.rb"), <<~RUBY)
          module GogglesDb
            class User < ApplicationRecord
              def full_name; end
            end
          end
        RUBY
        import_fixture(dir_a, project: "RepoA")

        # Claimed: RepoA's parent edge replaced the stub edge, and the
        # declaring producer's provenance landed.
        new_edge = MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of")
        expect(new_edge.to_entity_id).not_to eq(stub_edge.to_entity_id)
        expect(new_edge.properties["reference_stub"]).to be_nil
        expect(stub.memory_observations.where(source: "rails_ast_extractor")
                .where(status: MemoryObservation::ACTIVE_STATUS).count).to be >= 1

        # RepoB rescan WITHOUT the reference: User lives under RepoA's
        # subtree now → not diffed → no delete flap; RepoA's obs survive.
        File.write(File.join(dir_b, "app/models/order.rb"),
                   "class Order < ApplicationRecord; end\n")
        second = import_fixture(dir_b, project: "RepoB")
        expect(second.success).to be true

        rows = MaintenanceReportRow.by_report_type("scan_review")
                                   .where("JSON_EXTRACT(payload, '$.entity_id') = ?", stub.id)
        expect(rows.where("JSON_EXTRACT(payload, '$.kind') = 'delete_entity'")).to be_empty
        expect(stub.memory_observations.where(source: "rails_ast_extractor")
                .where(status: MemoryObservation::ACTIVE_STATUS).count).to be >= 1
      end
    end
  end

  it "retires a dropped superclass through relation diffing (no contradictory facts)" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      first = import_fixture(dir)
      expect(first.success).to be true
      expect(MemoryRelation.where(relation_type: "inherits").count).to be >= 1

      File.write(File.join(dir, "app/models/swimmer.rb"), "class Swimmer; end\n")
      second = import_fixture(dir)
      expect(second.success).to be true

      # The dropped superclass surfaces as a vanished relation — reviewable,
      # and free of the "Superclass: …" text contradiction an observation
      # would leave behind forever.
      expect(second.rescan_relations_flagged).to be >= 1
      expect(MemoryObservation.where("content LIKE ?", "Superclass:%").count).to eq(0)
    end
  end
end
