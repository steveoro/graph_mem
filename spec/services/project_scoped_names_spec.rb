# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "json"

# Project-scoped entity names (round-6 spec, use-cases 2/4/6/7/8/10):
# name uniqueness is (project_scope, name), cross-repo references resolve
# own → single-declarer → global stub, and MCP writes land in context.
RSpec.describe "project-scoped entity names" do
  # Self-created data only — mirrors rails_ast_import_spec's purge (runner
  # debug scripts and fixture rows can leave committed leftovers behind).
  PURGED_NAMES = %w[RepoA RepoB RepoC StableRepo ProjA ProjB CtxProj ScopeProj
                    BackProj ReA ReB Notifiable Notifiable#notify notifiable.rb
                    post.rb account.rb Account Account#a Account#b swimmer.rb
                    Swimmer team.rb Team Thing OnlyB SharedGlobal CtxEntity
                    NewRoot GlobalOne BackChild BackGrand BackOrphan ReChild
                    Bar Foo bar.rb foo.rb RepoD Lone PA InnerProj InnerMember
                    StubRef EdgeTarget n1.rb n2.rb n3.rb SwimProj
                    ApplicationRecord app_record.rb].freeze

  before { purge_fixture_names }
  after { purge_fixture_names }

  def purge_fixture_names
    # Members first: unclaiming before their destroy would collide a
    # member's name with an existing global (UNIQUE project_scope,name).
    MemoryEntity.where(name: PURGED_NAMES).where.not(entity_type: "Project").find_each do |e|
      MemoryRelation.where(from_entity_id: e.id).or(
        MemoryRelation.where(to_entity_id: e.id)
      ).delete_all
      e.destroy!
    end
    MemoryEntity.where(name: PURGED_NAMES, entity_type: "Project").find_each do |e|
      MemoryEntity.where(project_id: e.id).find_each do |member|
        member.update!(project_id: nil) unless MemoryEntity.exists?(name: member.name, project_id: nil)
      end
      MemoryRelation.where(from_entity_id: e.id).or(
        MemoryRelation.where(to_entity_id: e.id)
      ).delete_all
      e.destroy!
    end
  end

  def import_payload(dir, project:)
    payload = RailsAstExtractor.extract(dir, project_name: project)
    result = GraphifyImporter.new(JSON.generate(payload), project_name: project).translate
    match = ImportMatchingStrategy.new.match(result.import_data)
    decisions = GraphifyImporter.headless_decisions(match[:match_results])
    ImportExecutionStrategy.new.execute(result.import_data, decisions)
  end

  def write_models(dir, files)
    FileUtils.mkdir_p(File.join(dir, "app/models"))
    files.each { |name, body| File.write(File.join(dir, "app/models/#{name}"), body) }
  end

  describe "use-case 2: same basename in two projects" do
    it "two account.rb files coexist as project-scoped entities" do
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "account.rb" => "class Account\n  def a; end\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "account.rb" => "class Account\n  def b; end\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end

      files = MemoryEntity.where(name: "account.rb", entity_type: "File")
      classes = MemoryEntity.where(name: "Account", entity_type: "Class")
      expect(files.count).to eq(2)
      expect(classes.count).to eq(2)
      expect(files.map(&:project_id).uniq.size).to eq(2)
      expect(MemoryEntity.find_by(name: "Account#a")).to be_present
      expect(MemoryEntity.find_by(name: "Account#b")).to be_present
    end
  end

  describe "use-case 4: multi-declarer stub stays global" do
    it "keeps the stub and queues re-point proposals on the second declaration" do
      # RepoB references first → global stub.
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      stub = MemoryEntity.find_by!(name: "Notifiable")
      expect(stub.project_id).to be_nil

      # RepoA declares → single declarer at this point: claim moves the
      # stub into RepoA's project.
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "notifiable.rb" => "module Notifiable\n  def notify; end\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      expect(stub.reload.project_id).to eq(MemoryEntity.find_by(name: "RepoA").id)

      # RepoC now ALSO declares Notifiable: a project-scoped copy is
      # created (the stub stays with its claimant), and each cross-project
      # edge pointing at the claimed entity queues a re-point proposal.
      Dir.mktmpdir do |dir_c|
        write_models(dir_c, "notifiable.rb" => "module Notifiable\n  def notify2; end\nend\n")
        expect(import_payload(dir_c, project: "RepoC").success).to be true
      end

      declared = MemoryEntity.where(name: "Notifiable", entity_type: "Module").order(:id)
      expect(declared.count).to eq(2)
      expect(declared.map(&:project_id).compact.size).to eq(2)

      repoint = MaintenanceReportRow.where(kind: "relationship_proposal")
                                    .where("payload LIKE ?", "%re-point%")
      expect(repoint.count).to be >= 1
      expect(repoint.flat_map { |r| Array(r.payload["candidates"]) }.uniq.size).to eq(2)
    end
  end

  describe "use-case 6: scoped name resolution + MCP writes" do
    it "prefers the context project, falls back to global, raises on ambiguity" do
      project_a = MemoryEntity.create!(name: "ProjA", entity_type: "Project")
      project_b = MemoryEntity.create!(name: "ProjB", entity_type: "Project")
      in_a = MemoryEntity.create!(name: "Thing", entity_type: "Component", project_id: project_a.id)
      in_b = MemoryEntity.create!(name: "Thing", entity_type: "Component", project_id: project_b.id)
      global = MemoryEntity.create!(name: "SharedGlobal", entity_type: "Component")

      expect(ImportEntityResolver.find_by_name("Thing", project_id: project_a.id)).to eq(in_a)
      expect(ImportEntityResolver.find_by_name("SharedGlobal", project_id: project_a.id)).to eq(global)
      # Same name declared by two projects, no context → ambiguous, never guessed.
      expect { ImportEntityResolver.find_by_name("Thing") }
        .to raise_error(McpGraphMemErrors::AmbiguousReference)
      # A name only one project declares resolves through it.
      MemoryEntity.create!(name: "OnlyB", entity_type: "Component", project_id: project_b.id)
      expect(ImportEntityResolver.find_by_name("OnlyB", project_id: project_a.id).project_id).to eq(project_b.id)
    end

    it "graph_write creates entities inside the context project" do
      project = MemoryEntity.create!(name: "CtxProj", entity_type: "Project")
      payload = GraphWriteService.execute_one("create_entity",
                                            { "name" => "CtxEntity", "entity_type" => "Component" },
                                            project_id: project.id)
      expect(payload[:name]).to eq("CtxEntity")
      expect(MemoryEntity.find_by!(name: "CtxEntity").project_id).to eq(project.id)
      # …while a Project-typed create always lands in the global scope.
      GraphWriteService.execute_one("create_entity",
                                    { "name" => "NewRoot", "entity_type" => "Project" },
                                    project_id: project.id)
      expect(MemoryEntity.find_by!(name: "NewRoot").project_id).to be_nil
    end
  end

  describe "use-case 7: uniqueness" do
    it "rejects a duplicate global name at validation and at the unique index" do
      MemoryEntity.create!(name: "GlobalOne", entity_type: "Component")
      expect(MemoryEntity.new(name: "GlobalOne", entity_type: "Component")).not_to be_valid
      expect do
        MemoryEntity.insert!({ name: "GlobalOne", entity_type: "Component",
                               memory_observations_count: 0,
                               created_at: Time.current, updated_at: Time.current })
      end.to raise_error(ActiveRecord::RecordNotUnique)
      # …but the same name in a project scope is legal.
      project = MemoryEntity.create!(name: "ScopeProj", entity_type: "Project")
      expect(MemoryEntity.create!(name: "GlobalOne", entity_type: "Component",
                                  project_id: project.id)).to be_persisted
    end
  end

  describe "use-case 8: same repo twice" do
    it "produces identical entity/relation/observation counts" do
      Dir.mktmpdir do |dir|
        write_models(dir,
                     "swimmer.rb" => "class Swimmer < ApplicationRecord\n  belongs_to :team\nend\n",
                     "team.rb" => "class Team < ApplicationRecord\n  has_many :swimmers\nend\n")
        first = import_payload(dir, project: "StableRepo")
        counts = [ MemoryEntity.count, MemoryRelation.count, MemoryObservation.count ]
        second = import_payload(dir, project: "StableRepo")
        expect(second.success).to be true
        expect(second.entities_created).to eq(0)
        expect([ MemoryEntity.count, MemoryRelation.count, MemoryObservation.count ]).to eq(counts)
        # Content check: no duplicate provenance or dangling stub edges.
        expect(MemoryEntity.where(name: "StableRepo").count).to eq(1)
        expect(first.success).to be true
      end
    end
  end

  describe "use-case 10: backfill" do
    it "stamps members per tree, leaves unrooted NULL, and is idempotent" do
      project = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      child = MemoryEntity.create!(name: "BackChild", entity_type: "Task")
      grandchild = MemoryEntity.create!(name: "BackGrand", entity_type: "Task")
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")
      MemoryRelation.create!(from_entity: grandchild, to_entity: child, relation_type: "part_of")
      unrooted = MemoryEntity.create!(name: "BackOrphan", entity_type: "Task")

      report = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(report.changed).to be >= 2
      expect(child.reload.project_id).to eq(project.id)
      expect(grandchild.reload.project_id).to eq(project.id)
      expect(unrooted.reload.project_id).to be_nil
      expect(report.per_project[project.id]).to eq(2)

      second = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(second.changed).to eq(0)

      dry = ProjectIdBackfill.new(out: ->(_l) { }).run(dry_run: true)
      expect(dry.changed).to eq(0)
    end

    it "moves a member when its tree is re-parented under another project" do
      proj_a = MemoryEntity.create!(name: "ReA", entity_type: "Project")
      proj_b = MemoryEntity.create!(name: "ReB", entity_type: "Project")
      child = MemoryEntity.create!(name: "ReChild", entity_type: "Task", project_id: proj_a.id)
      MemoryRelation.create!(from_entity: child, to_entity: proj_b, relation_type: "part_of")

      ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(child.reload.project_id).to eq(proj_b.id)
    end

    it "does not stamp reference stubs through stub-tagged part_of edges" do
      # A stub-tagged edge parks the target in the global namespace — the
      # referencing project does NOT own it, so the walk must not claim it.
      project = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      member = MemoryEntity.create!(name: "BackChild", entity_type: "File")
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")
      stub = MemoryEntity.create!(name: "StubRef", entity_type: "Class")
      MemoryRelation.create!(from_entity: stub, to_entity: member, relation_type: "part_of",
                             properties: { "reference_stub" => true })

      report = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(member.reload.project_id).to eq(project.id)
      expect(stub.reload.project_id).to be_nil
      expect(report.per_project[project.id]).to eq(1)
    end

    it "does not stamp nested Projects or their members into the outer project" do
      # Nested Projects start their own scope (nearest-Project wins, like
      # project_id_for_parent): Inner stays NULL, its members take ITS id.
      outer = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      inner = MemoryEntity.create!(name: "InnerProj", entity_type: "Project")
      inner_member = MemoryEntity.create!(name: "InnerMember", entity_type: "File")
      MemoryRelation.create!(from_entity: inner, to_entity: outer, relation_type: "part_of")
      MemoryRelation.create!(from_entity: inner_member, to_entity: inner, relation_type: "part_of")

      report = ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(inner.reload.project_id).to be_nil
      expect(inner_member.reload.project_id).to eq(inner.id)
      expect(report.per_project[outer.id]).to be_nil
      expect(report.per_project[inner.id]).to eq(1)
    end

    it "reports dry_run counts on unstamped data without writing" do
      project = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      member = MemoryEntity.create!(name: "BackChild", entity_type: "File")
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")

      dry = ProjectIdBackfill.new(out: ->(_l) { }).run(dry_run: true)
      expect(dry.per_project[project.id]).to eq(1)
      expect(member.reload.project_id).to be_nil
    end

    it "clears project_id on rows no part_of chain reaches (unrooted)" do
      project = MemoryEntity.create!(name: "BackProj", entity_type: "Project")
      stale = MemoryEntity.create!(name: "StaleStamp", entity_type: "File",
                                   project_id: project.id) # stamped but no edge
      member = MemoryEntity.create!(name: "BackChild2", entity_type: "File")
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")

      ProjectIdBackfill.new(out: ->(_l) { }).run
      expect(member.reload.project_id).to eq(project.id)
      expect(stale.reload.project_id).to be_nil
    end
  end

  describe "down migration guard" do
    it "raises IrreversibleMigration when a name exists in two scopes" do
      MemoryEntity.create!(name: "DupProj", entity_type: "Project")
      MemoryEntity.create!(name: "DupName", entity_type: "File")
      proj = MemoryEntity.find_by!(name: "DupProj")
      MemoryEntity.create!(name: "DupName", entity_type: "File", project_id: proj.id)

      require Rails.root.join("db/migrate/20261012000000_add_project_scope_to_memory_entities")
      migration = AddProjectScopeToMemoryEntities.new
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /DupName/)
    end
  end

  describe "use-case 1 (both orders): Bar -mixes_in-> Foo" do
    it "reference-first then declaration claims the stub" do
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "bar.rb" => "class Bar\n  include Foo\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      expect(MemoryEntity.find_by!(name: "Foo").project_id).to be_nil

      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "foo.rb" => "class Foo\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      foo = MemoryEntity.find_by!(name: "Foo")
      proj_b = MemoryEntity.find_by!(name: "RepoB")
      expect(foo.project_id).to eq(proj_b.id)
      bar = MemoryEntity.find_by!(name: "Bar")
      expect(MemoryRelation.exists?(from_entity: bar, to_entity: foo,
                                    relation_type: "mixes_in")).to be true
    end

    it "declaration-first resolves the reference straight to the declarer" do
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "foo.rb" => "class Foo\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "bar.rb" => "class Bar\n  include Foo\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      expect(MemoryEntity.where(name: "Foo").count).to eq(1)
      foo = MemoryEntity.find_by!(name: "Foo")
      bar = MemoryEntity.find_by!(name: "Bar")
      expect(MemoryRelation.exists?(from_entity: bar, to_entity: foo,
                                    relation_type: "mixes_in")).to be true
    end

    it "the referencer's own declaration wins over foreign declarers (two Foos, Bar in B)" do
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "foo_a.rb" => "class Foo\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_b|
        write_models(dir_b,
                     "foo_b.rb" => "class Foo\nend\n",
                     "bar.rb" => "class Bar\n  include Foo\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      foos = MemoryEntity.where(name: "Foo").index_by(&:project_id)
      bar = MemoryEntity.find_by!(name: "Bar")
      proj_b = MemoryEntity.find_by!(name: "RepoB")
      # Bar's edge binds B's OWN Foo — the same-scope step wins over the
      # foreign declarer and over the global namespace, no stub minted.
      expect(MemoryRelation.exists?(from_entity: bar, to_entity: foos[proj_b.id],
                                    relation_type: "mixes_in")).to be true
      expect(MemoryEntity.find_by(name: "Foo", project_id: nil)).to be_nil
    end
  end

  describe "use-case 4 first half: reference under two declarers" do
    it "keeps a fresh global stub and queues an AMBIGUOUS proposal" do
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "n1.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_c|
        write_models(dir_c, "n2.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_c, project: "RepoC").success).to be true
      end
      proposals_before = MaintenanceReportRow.where(kind: "relationship_proposal").count

      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end

      stub = MemoryEntity.where(name: "Notifiable", project_id: nil)
      expect(stub.count).to eq(1)
      post = MemoryEntity.find_by!(name: "Post")
      expect(MemoryRelation.exists?(from_entity: post, to_entity: stub.first,
                                    relation_type: "mixes_in")).to be true
      expect(MaintenanceReportRow.where(kind: "relationship_proposal").count)
        .to be > proposals_before
    end

    it "does not let a later declarer claim a stub when others already declared" do
      # Multi-declarer claim guard (`!other_declarers?`): with a stub parked
      # globally and two declaring projects, a third declaration gets its
      # own scoped copy — the stub stays claimable-by-none.
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "n1.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_c|
        write_models(dir_c, "n2.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_c, project: "RepoC").success).to be true
      end
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      Dir.mktmpdir do |dir_d|
        write_models(dir_d, "n3.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_d, project: "RepoD").success).to be true
      end

      names = MemoryEntity.where(name: "Notifiable")
      expect(names.count).to eq(4) # RepoA, RepoC, RepoD + the parked stub
      stub = names.where(project_id: nil).sole
      expect(MemoryEntity.find_by!(name: "RepoD").project_id).to be_nil

      # The parked stub keeps its id and stays global — it was never
      # claimed (two declarers), so Post's edge still points AT it.
      post = MemoryEntity.find_by!(name: "Post")
      expect(MemoryRelation.exists?(from_entity: post, to_entity: stub,
                                    relation_type: "mixes_in")).to be true
      %w[RepoA RepoC RepoD].each do |repo|
        scoped = names.joins("INNER JOIN memory_entities p ON memory_entities.project_id = p.id")
                      .find_by(p: { name: repo })
        expect(scoped).to be_present
      end
    end

    it "re-importing the referrer still no-ops after a second declarer appears (S3c)" do
      # d1 declares, the referrer points at the claimed stub, d3 declares
      # too — the unchanged re-import must keep pointing at its stored
      # edge target, not mint a fresh global stub + a duplicate edge.
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "n1.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      Dir.mktmpdir do |dir_d|
        write_models(dir_d, "n3.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_d, project: "RepoD").success).to be true
      end
      claimed = MemoryEntity.find_by!(name: "Notifiable",
                                    project_id: MemoryEntity.find_by!(name: "RepoA").id)
      entities_before = MemoryEntity.count

      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        report = import_payload(dir_b, project: "RepoB")
        expect(report.success).to be true
        expect(report.entities_created).to eq(0)
      end
      expect(MemoryEntity.count).to eq(entities_before)
      post = MemoryEntity.find_by!(name: "Post")
      expect(MemoryRelation.where(from_entity: post, relation_type: "mixes_in")
                           .pluck(:to_entity_id)).to eq([ claimed.id ])
    end

    it "resolves a same-project declaration before foreign declarers (S11)" do
      # graphify:import then rails_ast:import of the SAME project: the
      # second import's `Swimmer < ApplicationRecord` reference must bind
      # to SwimProj's own ApplicationRecord, never a fresh global stub.
      Dir.mktmpdir do |dir|
        write_models(dir, "app_record.rb" => "class ApplicationRecord\nend\n")
        expect(import_payload(dir, project: "SwimProj").success).to be true
      end
      Dir.mktmpdir do |dir|
        write_models(dir, "swimmer.rb" => "class Swimmer < ApplicationRecord\nend\n")
        report = import_payload(dir, project: "SwimProj")
        expect(report.success).to be true
      end
      swim = MemoryEntity.find_by!(name: "SwimProj")
      records = MemoryEntity.where(name: "ApplicationRecord")
      expect(records.count).to eq(1)
      expect(records.first.project_id).to eq(swim.id)
      expect(MemoryRelation.exists?(from_entity: MemoryEntity.find_by!(name: "Swimmer"),
                                    to_entity: records.first,
                                    relation_type: "inherits")).to be true
    end

    it "re-importing the referrer no-ops against the stored edge target" do
      # After a claim, the referrer's stored edge still points at the
      # claimed entity — an unchanged re-import must not mint a second
      # stub plus a duplicate edge.
      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        expect(import_payload(dir_b, project: "RepoB").success).to be true
      end
      Dir.mktmpdir do |dir_a|
        write_models(dir_a, "n1.rb" => "module Notifiable\nend\n")
        expect(import_payload(dir_a, project: "RepoA").success).to be true
      end
      claimed = MemoryEntity.find_by!(name: "Notifiable")
      expect(claimed.project_id).to eq(MemoryEntity.find_by!(name: "RepoA").id)

      Dir.mktmpdir do |dir_b|
        write_models(dir_b, "post.rb" => "class Post\n  include Notifiable\nend\n")
        report = import_payload(dir_b, project: "RepoB")
        expect(report.success).to be true
        expect(report.entities_created).to eq(0)
      end
      expect(MemoryEntity.where(name: "Notifiable").count).to eq(1)
      post = MemoryEntity.find_by!(name: "Post")
      expect(MemoryRelation.where(from_entity: post, to_entity: claimed,
                                  relation_type: "mixes_in").count).to eq(1)
    end
  end

  describe "use-case 5: v1.49 upgrade → backfill → re-import" do
    it "re-import after stamping writes nothing new" do
      Dir.mktmpdir do |dir|
        write_models(dir, "swimmer.rb" => "class Swimmer\nend\n")
        expect(import_payload(dir, project: "StableRepo").success).to be true
      end
      # Simulate pre-1.50 rows: stamps removed, edges intact.
      MemoryEntity.where.not(entity_type: "Project").update_all(project_id: nil)

      report = ProjectIdBackfill.new(out: ->(_l) { }).run
      stable = MemoryEntity.find_by!(name: "StableRepo")
      expect(report.per_project[stable.id]).to be >= 2
      expect(MemoryEntity.find_by!(name: "Swimmer").project_id).to eq(stable.id)

      Dir.mktmpdir do |dir|
        write_models(dir, "swimmer.rb" => "class Swimmer\nend\n")
        again = import_payload(dir, project: "StableRepo")
        expect(again.success).to be true
        expect(again.entities_created).to eq(0)
        expect(again.relations_created).to eq(0)
      end
    end
  end

  describe "use-case 8: unchanged re-import checksum" do
    it "second run of the same payload writes nothing" do
      Dir.mktmpdir do |dir|
        write_models(dir, "swimmer.rb" => "class Swimmer\n  def x; end\nend\n")
        expect(import_payload(dir, project: "StableRepo").success).to be true
      end
      entity_ids = MemoryEntity.order(:id).pluck(:id)
      relation_ids = MemoryRelation.order(:id).pluck(:id)
      observation_ids = MemoryObservation.order(:id).pluck(:id)
      proposal_ids = MaintenanceReportRow.order(:id).pluck(:id)

      Dir.mktmpdir do |dir|
        write_models(dir, "swimmer.rb" => "class Swimmer\n  def x; end\nend\n")
        again = import_payload(dir, project: "StableRepo")
        expect(again.success).to be true
        expect(again.entities_created).to eq(0)
        expect(again.relations_created).to eq(0)
      end
      expect(MemoryEntity.order(:id).pluck(:id)).to eq(entity_ids)
      expect(MemoryRelation.order(:id).pluck(:id)).to eq(relation_ids)
      expect(MemoryObservation.order(:id).pluck(:id)).to eq(observation_ids)
      expect(MaintenanceReportRow.order(:id).pluck(:id)).to eq(proposal_ids)
    end
  end

  describe "use-case 10: DB-level scoped uniqueness" do
    it "allows same name across projects but rejects it inside one scope" do
      proj_a = MemoryEntity.create!(name: "ProjA", entity_type: "Project")
      proj_b = MemoryEntity.create!(name: "ProjB", entity_type: "Project")
      MemoryEntity.create!(name: "EdgeTarget", entity_type: "Class", project_id: proj_a.id)
      dup = MemoryEntity.new(name: "EdgeTarget", entity_type: "Class", project_id: proj_b.id)
      expect { dup.save!(validate: false) }.not_to raise_error

      clash = MemoryEntity.new(name: "EdgeTarget", entity_type: "Class", project_id: proj_a.id)
      expect { clash.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The real `down` invocation lives in the "down migration guard"
    # describe block above — it raises IrreversibleMigration on this
    # exact two-scope layout.
  end

  describe "MCP write scoping" do
    it "create_relation part_of re-syncs the child's project" do
      project = MemoryEntity.create!(name: "PA", entity_type: "Project")
      lone = MemoryEntity.create!(name: "Lone", entity_type: "Class")

      GraphWriteService.call(
        operations: [ { type: "create_relation", from_entity_id: lone.id,
                        to_entity_id: project.id, relation_type: "part_of" } ],
        project_id: nil
      )
      expect(lone.reload.project_id).to eq(project.id)
    end

    it "create_entity under context attaches part_of and stamps project_id" do
      project = MemoryEntity.create!(name: "PA", entity_type: "Project")
      GraphWriteService.call(
        operations: [ { type: "create_entity", name: "Lone", entity_type: "Class" } ],
        project_id: project.id
      )
      entity = MemoryEntity.find_by!(name: "Lone")
      expect(entity.project_id).to eq(project.id)
      expect(MemoryRelation.exists?(from_entity: entity, to_entity: project,
                                    relation_type: "part_of")).to be true
    end

    it "moving into a project that holds the name raises OperationFailed and rolls back" do
      project = MemoryEntity.create!(name: "PA", entity_type: "Project")
      MemoryEntity.create!(name: "SharedGlobal", entity_type: "Class", project_id: project.id)
      global = MemoryEntity.create!(name: "SharedGlobal", entity_type: "Class")

      expect {
        GraphWriteService.call(
          operations: [ { type: "create_relation", from_entity_id: global.id,
                          to_entity_id: project.id, relation_type: "part_of" } ],
          project_id: nil
        )
      }.to raise_error(McpGraphMemErrors::OperationFailed)
      expect(global.reload.project_id).to be_nil
      expect(MemoryRelation.exists?(from_entity: global, to_entity: project,
                                    relation_type: "part_of")).to be false
    end

    it "find_by_name resolves a single foreign-scope candidate (documented design)" do
      # A single same-named entity anywhere in the graph is unambiguous —
      # writes DO wire to it even under an active context. Documented
      # choice (Graphy flagged); the alternative (raise) needs a real
      # cross-project write UX first.
      proj_a = MemoryEntity.create!(name: "ProjA", entity_type: "Project")
      proj_b = MemoryEntity.create!(name: "ProjB", entity_type: "Project")
      foreign = MemoryEntity.create!(name: "EdgeTarget", entity_type: "Class", project_id: proj_a.id)

      expect(ImportEntityResolver.find_by_name("EdgeTarget", project_id: proj_b.id)).to eq(foreign)
    end

    it "serializers expose project_id" do
      project = MemoryEntity.create!(name: "PA", entity_type: "Project")
      member = MemoryEntity.create!(name: "Lone", entity_type: "Class", project_id: project.id)
      expect(GraphTraversalSerializer.entity_json(member)[:project_id]).to eq(project.id)
      result = HybridSearchStrategy::SearchResult.new(entity: member, score: 1.0, matched_fields: [])
      expect(result.to_h[:project_id]).to eq(project.id)
    end
  end
end
