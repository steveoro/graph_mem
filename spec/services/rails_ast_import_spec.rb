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
    names = %w[OtherApp Fixture Team Swimmer Order GogglesDb
               GogglesDb::User RepoA RepoB ApplicationRecord
               Shared::Base Post Article Thing ExternalBase
               OtherBase Vendor Admin Admin::Admin Admin::Admin#inner
               Billing Notifiable admin.rb billing.rb notifiable.rb
               post.rb Foo Foo#a Foo#b foo.rb foo_ext.rb]
    # Destroy member rows BEFORE unclaiming: with project-scoped names a
    # member and a global may share a name, and moving the member to
    # scope 0 would trip UNIQUE(project_scope, name).
    MemoryEntity.where(name: names).where.not(entity_type: "Project").find_each do |e|
      MemoryRelation.where(from_entity_id: e.id).or(
        MemoryRelation.where(to_entity_id: e.id)
      ).delete_all
      e.destroy!
    end
    MemoryEntity.where(name: names, entity_type: "Project").find_each do |e|
      MemoryEntity.where(project_id: e.id).find_each do |member|
        member.update!(project_id: nil) unless MemoryEntity.exists?(name: member.name, project_id: nil)
      end
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
    foreign_team = MemoryEntity.create!(name: "Team", entity_type: "Class", project_id: foreign_root.id)
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
      # 2: belongs_to → foreign-owned Team AND inherits → the global
      # ApplicationRecord stub — both leave this project's namespace.
      expect(report.relations_cross_repo).to eq(2)
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

  it "does not ping-pong a shared reference stub between two referencing repos" do
    # RepoA and RepoB both reference Shared::Base but neither declares it:
    # a reference-only payload must NOT claim the stub — otherwise the edge
    # flips between repos on every alternating import and each unchanged
    # re-import writes 1–2 relations (#100's idempotency contract).
    Dir.mktmpdir do |dir_a|
      FileUtils.mkdir_p(File.join(dir_a, "app/models"))
      File.write(File.join(dir_a, "app/models/post.rb"),
                 "class Post < Shared::Base; end\n")
      Dir.mktmpdir do |dir_b|
        FileUtils.mkdir_p(File.join(dir_b, "app/models"))
        File.write(File.join(dir_b, "app/models/article.rb"),
                   "class Article < Shared::Base; end\n")

        import_fixture(dir_a, project: "RepoA")
        stub = MemoryEntity.find_by!(name: "Shared::Base", entity_type: "Class")
        parent_id = MemoryRelation
                    .find_by(from_entity_id: stub.id, relation_type: "part_of").to_entity_id

        # RepoB only references the stub too: no claim, parent unchanged.
        import_fixture(dir_b, project: "RepoB")
        expect(MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of").to_entity_id)
          .to eq(parent_id)

        # Alternating unchanged re-imports write nothing and keep the parent.
        expect(import_fixture(dir_a, project: "RepoA").relations_created).to eq(0)
        expect(import_fixture(dir_b, project: "RepoB").relations_created).to eq(0)
        expect(MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of").to_entity_id)
          .to eq(parent_id)
      end
    end
  end

  it "retires producer edges to reference stubs when the reference drops out of the payload" do
    # Edges to undeclared constants are the common case for the extractor:
    # `Thing inherits ExternalBase` and `Thing belongs_to Vendor` both end
    # at stubs with no provenance. Dropping the references must flag the
    # stored edges for review (never auto-delete).
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/thing.rb"), <<~RUBY)
        class Thing < ExternalBase
          belongs_to :vendor
        end
      RUBY
      first = import_fixture(dir)
      expect(first.success).to be true

      File.write(File.join(dir, "app/models/thing.rb"), "class Thing < OtherBase; end\n")
      second = import_fixture(dir)
      expect(second.success).to be true
      expect(second.rescan_relations_flagged).to be >= 2
    end
  end

  it "module + same-named nested class imports without a NameTaken collision" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/admin.rb"), <<~RUBY)
        module Admin
          class Admin
            def inner; end
          end
        end
      RUBY
      report = import_fixture(dir)
      expect(report.success).to be true
      expect(MemoryEntity.find_by(name: "Admin", entity_type: "Module")).to be_present
      expect(MemoryEntity.find_by(name: "Admin::Admin", entity_type: "Class")).to be_present
      expect(MemoryEntity.find_by(name: "Admin", entity_type: "Class")).to be_nil
    end
  end

  it "v1.49 upgrade: a stored Class entity inside this project subtree retypes to Module on re-import", :with_test_embeddings do
    # v1.49 emitted every declaration as Class. Databases holding such an
    # import hit 'Name has already been taken' on the next rails_ast:import —
    # the executor retypes a Class↔Module collision ONLY when the stored
    # entity already lives inside THIS import's subtree (same-repo leftover).
    project = MemoryEntity.create!(name: "Fixture", entity_type: "Project")
    legacy = MemoryEntity.create!(name: "Billing", entity_type: "Class", project_id: project.id)
    MemoryRelation.create!(from_entity: legacy, to_entity: project, relation_type: "part_of")
    MemoryObservation.create!(memory_entity: legacy,
                              content: "Defined at app/models/billing.rb",
                              source: "rails_ast_extractor")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/billing.rb"), "module Billing; end\n")
      report = import_fixture(dir)
      expect(report.success).to be true
      expect(legacy.reload.entity_type).to eq("Module")
      expect(MemoryEntity.where(name: "Billing").count).to eq(1)
    end
  end

  it "match is read-only: a Module payload must not retype a stored Class during preview" do
    # The upload runs matching before the operator confirms anything —
    # writing here would let a cancelled upload rewrite entity_type.
    legacy = MemoryEntity.create!(name: "Billing", entity_type: "Class")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/billing.rb"), "module Billing; end\n")
      payload = RailsAstExtractor.extract(dir, project_name: "Fixture")
      import_data = GraphifyImporter.new(JSON.generate(payload), project_name: "Fixture").translate.import_data
      ImportMatchingStrategy.new.match(import_data)
      expect(legacy.reload.entity_type).to eq("Class")
    end
  end

  it "conflicting real declarations keep their type — no cross-repo ping-pong" do
    # RepoA declares `class Foo`; RepoB declares `module Foo`. The stored
    # entity is a real declaration in ANOTHER project's subtree, so B's
    # colliding subtree is skipped — re-importing either side never flips
    # entity_type back and forth.
    Dir.mktmpdir do |dir_a|
      FileUtils.mkdir_p(File.join(dir_a, "app/models"))
      File.write(File.join(dir_a, "app/models/foo.rb"), "class Foo\n  def a; end\nend\n")
      expect(import_fixture(dir_a, project: "RepoA").success).to be true
      foo = MemoryEntity.find_by(name: "Foo")
      expect(foo.entity_type).to eq("Class")

      Dir.mktmpdir do |dir_b|
        FileUtils.mkdir_p(File.join(dir_b, "app/models"))
        # Distinct basename on purpose: with `foo.rb` on both sides the
        # same-file collision rule would pre-empt the Class↔Module check and
        # this spec couldn't go red with `retype_allowed?` forced to true.
        File.write(File.join(dir_b, "app/models/foo_ext.rb"), "module Foo\n  def b; end\nend\n")
        report = import_fixture(dir_b, project: "RepoB")
        expect(report.success).to be true
        # Scoped names let both declarations coexist: RepoA's Class stays
        # Class, RepoB gets its own Module Foo with its own subtree.
        expect(foo.reload.entity_type).to eq("Class")
        foo_b = MemoryEntity.find_by(name: "Foo#b")
        expect(foo_b).to be_present
        expect(foo_b.project_id).to eq(MemoryEntity.find_by(name: "RepoB").id)
        foos = MemoryEntity.where(name: "Foo", entity_type: %w[Class Module])
        expect(foos.count).to eq(2)
        expect(foos.find_by(entity_type: "Module").project_id).to eq(foo_b.project_id)
      end

      expect(import_fixture(dir_a, project: "RepoA").success).to be true
      expect(foo.reload.entity_type).to eq("Class")
    end
  end

  it "a Class declaration claims a same-named Module reference stub (stub retype branch)" do
    # RepoB only references Foo via `include` → Module-typed reference stub.
    # RepoA then declares `class Foo` — the Class↔Module collision is allowed
    # to retype precisely because the stored entity is an unclaimed stub.
    Dir.mktmpdir do |dir_b|
      FileUtils.mkdir_p(File.join(dir_b, "app/models"))
      File.write(File.join(dir_b, "app/models/post.rb"), "class Post\n  include Foo\nend\n")
      expect(import_fixture(dir_b, project: "RepoB").success).to be true
      stub = MemoryEntity.find_by(name: "Foo")
      expect(stub&.entity_type).to eq("Module")

      Dir.mktmpdir do |dir_a|
        FileUtils.mkdir_p(File.join(dir_a, "app/models"))
        File.write(File.join(dir_a, "app/models/foo.rb"), "class Foo\n  def a; end\nend\n")
        expect(import_fixture(dir_a, project: "RepoA").success).to be true
        expect(stub.reload.entity_type).to eq("Class")
        expect(MemoryEntity.where(name: "Foo").count).to eq(1)
        # Claimed by the declaring repo: Foo#a materialized under RepoA's Foo.
        expect(MemoryEntity.find_by(name: "Foo#a")).to be_present
      end

      expect(MemoryRelation.exists?(from_entity: MemoryEntity.find_by(name: "Post"),
                                    to_entity_id: stub.id, relation_type: "mixes_in")).to be true
    end
  end

  it "cross-repo mixin stub claims the Module in both import orders" do
    # repo2 only references Notifiable → Module-typed reference stub; repo1
    # declares it → claims the stub (declared nodes may claim, references not).
    Dir.mktmpdir do |dir2|
      FileUtils.mkdir_p(File.join(dir2, "app/models"))
      File.write(File.join(dir2, "app/models/post.rb"), "class Post\n  include Notifiable\nend\n")
      expect(import_fixture(dir2, project: "RepoB").success).to be true
      stub = MemoryEntity.find_by(name: "Notifiable")
      expect(stub&.entity_type).to eq("Module")
      stub_edge = MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of")
      repo_b_parent = stub_edge&.to_entity_id

      Dir.mktmpdir do |dir1|
        FileUtils.mkdir_p(File.join(dir1, "app/models"))
        File.write(File.join(dir1, "app/models/notifiable.rb"), "module Notifiable\n  def notify; end\nend\n")
        expect(import_fixture(dir1, project: "RepoA").success).to be true
        expect(MemoryEntity.where(name: "Notifiable").count).to eq(1)
        # Claimed: the stub edge is replaced by the declaring tree's parent.
        expect(MemoryRelation.find_by(from_entity_id: stub.id, relation_type: "part_of").to_entity_id)
          .not_to eq(repo_b_parent)
      end
      expect(MemoryRelation.exists?(from_entity: MemoryEntity.find_by(name: "Post"),
                                    to_entity_id: stub.id, relation_type: "mixes_in")).to be true
    end
  end

  it "declared-first order: a later referencing repo still links its mixin edge" do
    # The reverse order: repo1 declares Notifiable first, then repo2 imports
    # `include Notifiable` — the payload node is reference-only, so the
    # declared entity keeps its RepoA parent while Post's edge still lands.
    Dir.mktmpdir do |dir1|
      FileUtils.mkdir_p(File.join(dir1, "app/models"))
      File.write(File.join(dir1, "app/models/notifiable.rb"), "module Notifiable\n  def notify; end\nend\n")
      expect(import_fixture(dir1, project: "RepoA").success).to be true
      declared = MemoryEntity.find_by(name: "Notifiable")
      repo_a_parent = MemoryRelation.find_by(from_entity_id: declared.id,
                                           relation_type: "part_of").to_entity_id

      Dir.mktmpdir do |dir2|
        FileUtils.mkdir_p(File.join(dir2, "app/models"))
        File.write(File.join(dir2, "app/models/post.rb"), "class Post\n  include Notifiable\nend\n")
        expect(import_fixture(dir2, project: "RepoB").success).to be true
        expect(MemoryEntity.where(name: "Notifiable").count).to eq(1)
        # Still parented under RepoA — a mere reference never steals the edge.
        expect(MemoryRelation.find_by(from_entity_id: declared.id,
                                      relation_type: "part_of").to_entity_id).to eq(repo_a_parent)
        expect(MemoryRelation.exists?(from_entity: MemoryEntity.find_by(name: "Post"),
                                      to_entity_id: declared.id, relation_type: "mixes_in")).to be true
      end
    end
  end
end
